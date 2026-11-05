package control

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"golang.org/x/crypto/ssh"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

func TestRuntimeProbeRequiresActualSuccessfulProtocol(t *testing.T) {
	valid := `{"type":"result","ok":true,"data":{"version":"` + Version + `","ready":true,"protocol":1,"bili_version":"2.15.17"}}`
	if !validRuntimeProbe(valid) {
		t.Fatal("valid probe rejected")
	}
	for _, bad := range []string{`{"ready":true}`, strings.Replace(valid, `"ok":true`, `"ok":false`, 1), strings.Replace(valid, `"protocol":1`, `"protocol":2`, 1), strings.Replace(valid, "2.15.17", "old", 1), strings.Replace(valid, Version, "0.1.0", 1), valid + valid, `{"type":"progress","message":"ready: true"}`} {
		if validRuntimeProbe(bad) {
			t.Fatalf("invalid probe accepted: %s", bad)
		}
	}
}

func TestBundleRejectsLinkTraversalAndCorruption(t *testing.T) {
	makeArchive := func(headers []*tar.Header, tail []byte) []byte {
		var raw bytes.Buffer
		tw := tar.NewWriter(&raw)
		manifest, _ := json.Marshal(Manifest{Version: Version, BiliVersion: BiliVersion, Platform: "linux", Arch: "arm64"})
		for name, data := range map[string][]byte{"manifest.json": manifest, "sisters": []byte("binary"), "runtime/misaka-runtime": []byte("runtime")} {
			tw.WriteHeader(&tar.Header{Name: name, Size: int64(len(data)), Mode: 0755})
			tw.Write(data)
		}
		for _, h := range headers {
			if err := tw.WriteHeader(h); err != nil {
				t.Fatal(err)
			}
		}
		tw.Close()
		raw.Write(tail)
		var out bytes.Buffer
		gz := gzip.NewWriter(&out)
		gz.Write(raw.Bytes())
		gz.Close()
		return out.Bytes()
	}
	for _, headers := range [][]*tar.Header{
		{{Name: "deep", Typeflag: tar.TypeSymlink, Linkname: "."}, {Name: "deep/../escape"}},
		{{Name: "rootlink", Typeflag: tar.TypeSymlink, Linkname: "."}, {Name: "escape", Typeflag: tar.TypeSymlink, Linkname: "rootlink/../outside"}},
		{{Name: "dir", Typeflag: tar.TypeSymlink, Linkname: "runtime"}, {Name: "dir/child"}},
		{{Name: "cycle", Typeflag: tar.TypeSymlink, Linkname: "cycle"}},
		{{Name: "server.key", Typeflag: tar.TypeSymlink, Linkname: "sisters"}},
		{{Name: "."}},
	} {
		if err := checkBundleReader(bytes.NewReader(makeArchive(headers, nil)), "linux", "arm64"); err == nil {
			t.Fatalf("unsafe archive accepted: %v", headers)
		}
	}
	valid := makeArchive([]*tar.Header{{Name: "runtime/library", Typeflag: tar.TypeSymlink, Linkname: "misaka-runtime"}}, nil)
	if err := checkBundleReader(bytes.NewReader(valid), "linux", "arm64"); err != nil {
		t.Fatalf("safe library symlink: %v", err)
	}
	for _, bad := range [][]byte{valid[:len(valid)-5], makeArchive(nil, []byte("unvalidated archive data")), makeArchive(nil, make([]byte, 1024*1024+1))} {
		if err := checkBundleReader(bytes.NewReader(bad), "linux", "arm64"); err == nil {
			t.Fatal("corrupt archive accepted")
		}
	}
}

func TestSystemdAndPlistEscaping(t *testing.T) {
	home := `/example/a"b\c$HOME%h&<>`
	_, body, _, _ := serviceDefinition("linux", home+"/misaka", home)
	if !strings.Contains(string(body), `a\"b\\c$$HOME%%h&<>`) {
		t.Fatalf("systemd paths not escaped: %s", body)
	}
	_, body, _, _ = serviceDefinition("macos", home+"/misaka", home)
	if !strings.Contains(string(body), `&quot;`) || !strings.Contains(string(body), `&amp;&lt;&gt;`) {
		t.Fatal("plist XML not escaped")
	}
	if plutil, err := exec.LookPath("plutil"); err == nil {
		file := filepath.Join(t.TempDir(), "agent.plist")
		os.WriteFile(file, body, 0600)
		if out, err := exec.Command(plutil, "-lint", file).CombinedOutput(); err != nil {
			t.Fatalf("invalid plist: %s", out)
		}
	}
}

func TestMacAgentStaysInUserDomain(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	home := t.TempDir()
	root := filepath.Join(home, "misaka")
	release := filepath.Join(root, "releases", "new")
	os.MkdirAll(release, 0700)
	shim := filepath.Join(home, "bin")
	os.MkdirAll(shim, 0700)
	logPath := filepath.Join(home, "commands")
	os.WriteFile(filepath.Join(shim, "launchctl"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> "+shellQuote(logPath)+"\nexit 0\n"), 0700)
	t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
	servicePath, _, _, _ := serviceDefinition("macos", root, home)
	os.MkdirAll(filepath.Dir(servicePath), 0700)
	var descriptor []byte
	err := activate(localSSH(t), "macos", root, release, home, func() error {
		descriptor, _ = os.ReadFile(servicePath)
		return errors.New("failed")
	})
	if err == nil {
		t.Fatal("activation ignored failed health")
	}
	if !strings.Contains(string(descriptor), "<key>LimitLoadToSessionType</key><string>Background</string>") {
		t.Fatalf("agent may also load into the GUI domain: %s", descriptor)
	}
	uid := strconv.Itoa(os.Getuid())
	calls, _ := os.ReadFile(logPath)
	for _, want := range []string{
		"bootout user/" + uid + "/io.misakanetwork.sisters",
		"bootout gui/" + uid + "/io.misakanetwork.sisters",
		"bootstrap user/" + uid + " " + servicePath,
		"kickstart user/" + uid + "/io.misakanetwork.sisters",
	} {
		if !strings.Contains(string(calls), want) {
			t.Fatalf("missing %q in launchctl calls:\n%s", want, calls)
		}
	}
	if strings.Contains(string(calls), "bootstrap gui/") {
		t.Fatal("agent bootstrapped into the GUI domain")
	}
}

// A local SSH fixture executes only commands generated by the test and forwards
// loopback connections. It exercises the actual SSH streams and shell quoting.
func localSSH(t *testing.T) *ssh.Client {
	t.Helper()
	return localSSHWithShell(t, "sh")
}

// localSSHWithShell hands each command to shell, as sshd hands it to the
// remote user's login shell.
func localSSHWithShell(t *testing.T, shell string) *ssh.Client {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(signer)
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lis.Close() })
	go func() {
		raw, err := lis.Accept()
		if err != nil {
			return
		}
		conn, channels, requests, err := ssh.NewServerConn(raw, config)
		if err != nil {
			raw.Close()
			return
		}
		defer conn.Close()
		go ssh.DiscardRequests(requests)
		for incoming := range channels {
			go func(incoming ssh.NewChannel) {
				if incoming.ChannelType() == "direct-tcpip" {
					var request struct {
						Host       string
						Port       uint32
						Origin     string
						OriginPort uint32
					}
					if ssh.Unmarshal(incoming.ExtraData(), &request) != nil || request.Host != "127.0.0.1" {
						incoming.Reject(ssh.Prohibited, "invalid target")
						return
					}
					target, err := net.Dial("tcp", net.JoinHostPort(request.Host, strconv.Itoa(int(request.Port))))
					if err != nil {
						incoming.Reject(ssh.ConnectionFailed, "unavailable")
						return
					}
					defer target.Close()
					channel, requests, err := incoming.Accept()
					if err != nil {
						return
					}
					defer channel.Close()
					go ssh.DiscardRequests(requests)
					go func() { io.Copy(channel, target); channel.CloseWrite() }()
					io.Copy(target, channel)
					return
				}
				if incoming.ChannelType() != "session" {
					incoming.Reject(ssh.UnknownChannelType, "unsupported")
					return
				}
				channel, requests, err := incoming.Accept()
				if err != nil {
					return
				}
				defer channel.Close()
				for request := range requests {
					if request.Type != "exec" {
						request.Reply(false, nil)
						continue
					}
					var command struct{ Value string }
					ssh.Unmarshal(request.Payload, &command)
					request.Reply(true, nil)
					cmd := exec.Command(shell, "-c", command.Value)
					cmd.Stdin = channel
					cmd.Stdout = channel
					cmd.Stderr = io.Discard
					code := uint32(0)
					if cmd.Run() != nil {
						code = 1
					}
					channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Code uint32 }{code}))
					return
				}
			}(incoming)
		}
	}()
	client, err := ssh.Dial("tcp", lis.Addr().String(), &ssh.ClientConfig{User: "test", HostKeyCallback: hostCallback(ssh.FingerprintSHA256(signer.PublicKey())), Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

func TestActivationChecksHealthAndRollsBack(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	for _, existing := range []bool{false, true} {
		t.Run(strconv.FormatBool(existing), func(t *testing.T) {
			home := t.TempDir()
			root := filepath.Join(home, "app with 'quote")
			release := filepath.Join(root, "releases", "new")
			os.MkdirAll(release, 0700)
			shim := filepath.Join(home, "bin")
			os.MkdirAll(shim, 0700)
			logPath := filepath.Join(home, "commands")
			os.WriteFile(filepath.Join(shim, "systemctl"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> "+shellQuote(logPath)+"\nexit 0\n"), 0700)
			t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
			servicePath, _, _, _ := serviceDefinition("linux", root, home)
			os.MkdirAll(filepath.Dir(servicePath), 0700)
			current := filepath.Join(root, "current")
			old := filepath.Join(root, "releases", "old")
			if existing {
				os.MkdirAll(old, 0700)
				os.Symlink(old, current)
				os.WriteFile(servicePath, []byte("previous descriptor"), 0600)
			}
			client := localSSH(t)
			called := false
			err := activate(client, "linux", root, release, home, func() error {
				called = true
				target, _ := os.Readlink(current)
				if target != release {
					t.Error("health checked wrong release")
				}
				return errors.New("failed")
			})
			if err == nil || !called {
				t.Fatal("activation did not require health")
			}
			outcome := "已停止并移除新服务"
			if existing {
				outcome = "已停止新服务并恢复旧版本"
			}
			if !strings.Contains(err.Error(), outcome) {
				t.Fatalf("rollback outcome not reported: %v", err)
			}
			if existing {
				target, _ := os.Readlink(current)
				body, _ := os.ReadFile(servicePath)
				if target != old || string(body) != "previous descriptor" {
					t.Fatal("previous deployment not restored")
				}
			} else {
				if _, err := os.Lstat(current); !os.IsNotExist(err) {
					t.Fatal("failed first deployment left current")
				}
				if _, err := os.Stat(servicePath); !os.IsNotExist(err) {
					t.Fatal("failed first deployment left service")
				}
			}
			log, _ := os.ReadFile(logPath)
			if !strings.Contains(string(log), "stop misaka-sisters.service") {
				t.Fatal("failed new service was not stopped")
			}
		})
	}
}

func TestRemoteCommandsIgnoreLoginShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	dir := t.TempDir()
	// A login shell whose startup file prints to stdout before the command runs.
	chatty := filepath.Join(dir, "chatty")
	os.WriteFile(chatty, []byte("#!/bin/sh\necho 'welcome from rc'\nexec /bin/sh -c \"$2\"\n"), 0700)
	shells := []string{chatty}
	for _, name := range []string{"csh", "tcsh", "fish"} {
		if found, err := exec.LookPath(name); err == nil {
			shells = append(shells, found)
		}
	}
	want := "ab " + strconv.Itoa(os.Getuid())
	for _, shell := range shells {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			client := localSSHWithShell(t, shell)
			if home, err := run(client, "printf '%s' \"$HOME\"", nil); err != nil || home != os.Getenv("HOME") {
				t.Fatalf("home = %q, %v", home, err)
			}
			// POSIX-only syntax that fish and csh would reject on their own.
			out, err := run(client, `uid=$(id -u); for d in a b; do printf '%s' "$d"; done; if [ ! -e /nonexistent ]; then printf ' %s' "$uid"; fi 2>/dev/null`, nil)
			if err != nil || out != want {
				t.Fatalf("got %q, %v; want %q", out, err, want)
			}
			if _, err := run(client, "exit 3", nil); err == nil {
				t.Fatal("exit status lost")
			}
		})
	}
	if _, err := exec.LookPath("csh"); err == nil {
		// The whole activation and rollback also works under csh.
		home := t.TempDir()
		root := filepath.Join(home, "misaka")
		release := filepath.Join(root, "releases", "new")
		os.MkdirAll(release, 0700)
		shim := filepath.Join(home, "bin")
		os.MkdirAll(shim, 0700)
		os.WriteFile(filepath.Join(shim, "systemctl"), []byte("#!/bin/sh\nexit 0\n"), 0700)
		t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
		servicePath, _, _, _ := serviceDefinition("linux", root, home)
		os.MkdirAll(filepath.Dir(servicePath), 0700)
		err := activate(localSSHWithShell(t, "csh"), "linux", root, release, home, func() error { return errors.New("failed") })
		if err == nil || !strings.Contains(err.Error(), "已停止并移除新服务") {
			t.Fatalf("csh activation: %v", err)
		}
	}
}

func TestFailedRollbackIsReported(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	home := t.TempDir()
	root := filepath.Join(home, "misaka")
	release := filepath.Join(root, "releases", "new")
	os.MkdirAll(release, 0700)
	shim := filepath.Join(home, "bin")
	os.MkdirAll(shim, 0700)
	// Every systemctl call fails, so both the restart and the cleanup fail.
	os.WriteFile(filepath.Join(shim, "systemctl"), []byte("#!/bin/sh\nexit 1\n"), 0700)
	t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
	servicePath, _, _, _ := serviceDefinition("linux", root, home)
	os.MkdirAll(filepath.Dir(servicePath), 0700)
	err := activate(localSSH(t), "linux", root, release, home, func() error { return nil })
	if err == nil || !strings.Contains(err.Error(), "回滚未完成") || strings.Contains(err.Error(), "已停止新服务") || strings.Contains(err.Error(), "已停止并移除") {
		t.Fatalf("failed rollback reported as recovered: %v", err)
	}
}

func TestStallConnFailsOnlyWithoutProgress(t *testing.T) {
	local, remote := net.Pipe()
	defer remote.Close()
	conn := &stallConn{Conn: local, idle: 200 * time.Millisecond}
	defer conn.Close()
	conn.watch()
	go func() {
		// A slow transfer: each byte arrives well within idle, but the whole
		// transfer outlasts it several times over.
		for i := 0; i < 8; i++ {
			time.Sleep(60 * time.Millisecond)
			if _, err := remote.Write([]byte{byte(i)}); err != nil {
				return
			}
		}
	}()
	buffer := make([]byte, 1)
	for i := 0; i < 8; i++ {
		if _, err := conn.Read(buffer); err != nil {
			t.Fatalf("progressing transfer failed at byte %d: %v", i, err)
		}
	}
	var timeout net.Error
	if _, err := conn.Read(buffer); !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("stalled transfer did not time out: %v", err)
	}
}

func TestLingerIsVerifiedBeforeLinuxDeployment(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	for _, tc := range []struct {
		name                         string
		initial                      string // empty: logind cannot report the user
		allowEnable, wantErr, enable bool
	}{
		{"already enabled", "yes", false, false, false},
		{"self service", "no", true, false, true},
		{"needs administrator", "no", false, true, true},
		{"unknown user", "", false, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			state := filepath.Join(dir, "linger")
			logPath := filepath.Join(dir, "commands")
			if tc.initial != "" {
				os.WriteFile(state, []byte(tc.initial+"\n"), 0600)
			}
			enable := "exit 1"
			if tc.allowEnable {
				enable = "echo yes > " + shellQuote(state)
			}
			shim := filepath.Join(dir, "bin")
			os.MkdirAll(shim, 0700)
			os.WriteFile(filepath.Join(shim, "loginctl"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> "+shellQuote(logPath)+"\ncase \"$1\" in\nshow-user) cat "+shellQuote(state)+" ;;\nenable-linger) "+enable+" ;;\n*) exit 1 ;;\nesac\n"), 0700)
			t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
			err := ensureLinger(localSSH(t), "ticket")
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v", err)
			}
			if err != nil && !strings.Contains(err.Error(), "sudo loginctl enable-linger ticket") {
				t.Fatalf("missing administrator guidance: %v", err)
			}
			commands, _ := os.ReadFile(logPath)
			if strings.Contains(string(commands), "enable-linger") != tc.enable {
				t.Fatalf("unexpected enable-linger attempt: %s", commands)
			}
		})
	}
}

type healthyService struct{ pb.UnimplementedSistersServer }

func (healthyService) GetStatus(context.Context, *pb.Empty) (*pb.AgentStatus, error) {
	return &pb.AgentStatus{Version: Version, BiliVersion: BiliVersion, RuntimeReady: true}, nil
}

// startHealthyAgent serves a healthy mTLS Sisters on loopback with a freshly
// issued certificate, returning the controller identity, its PKI directory,
// the service certificate and the port.
func startHealthyAgent(t *testing.T) (Identity, string, []byte, int) {
	t.Helper()
	dir := t.TempDir()
	identity, err := InitPKI(dir)
	if err != nil {
		t.Fatal(err)
	}
	cert, key, ca, err := ServerIdentity(dir, "agent.example")
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(cert, key)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lis.Close() })
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool})))
	t.Cleanup(server.Stop)
	pb.RegisterSistersServer(server, healthyService{})
	go server.Serve(lis)
	return identity, dir, cert, lis.Addr().(*net.TCPAddr).Port
}

func TestDirectReachabilityChecksTheNewService(t *testing.T) {
	identity, dir, cert, port := startHealthyAgent(t)
	endpoint := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if !reachable(context.Background(), identity, cert, "agent.example", endpoint) {
		t.Fatal("reachable agent reported unreachable")
	}
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	blocked := closed.Addr().String()
	closed.Close()
	other, _, _, _ := ServerIdentity(dir, "agent.example")
	for _, tc := range []struct {
		name, endpoint string
		cert           []byte
	}{{"blocked port", blocked, cert}, {"other service", endpoint, other}} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		if reachable(ctx, identity, tc.cert, "agent.example", tc.endpoint) {
			t.Errorf("%s reported reachable", tc.name)
		}
		cancel()
	}
}

func TestDeploymentHealthUsesMTLSAndNewServerCertificate(t *testing.T) {
	identity, dir, cert, port := startHealthyAgent(t)
	client := localSSH(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := verifyDeployment(ctx, client, identity, cert, "agent.example", port); err != nil {
		t.Fatal(err)
	}
	different, _, _, _ := ServerIdentity(dir, "agent.example")
	ctx2, cancel2 := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel2()
	if err := verifyDeployment(ctx2, client, identity, different, "agent.example", port); err == nil {
		t.Fatal("old service certificate passed new deployment health")
	}
}

func TestPKIRejectsSymlinkAndErrorsHidePaths(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "private-key")
	os.WriteFile(target, []byte("private"), 0600)
	if err := os.Symlink(target, filepath.Join(dir, "ca.key")); err != nil {
		t.Skip("symlink creation unavailable on this host")
	}
	if _, err := InitPKI(dir); err == nil {
		t.Fatal("symlink PKI accepted")
	}
	resp := Handle(Request{Action: "init_pki", Directory: target})
	if resp.OK || strings.Contains(resp.Error, target) {
		t.Fatal("file error exposes path")
	}
}
