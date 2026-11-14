package control

import (
	"archive/tar"
	"compress/gzip"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// Opt-in checks against a real Windows OpenSSH server: the native tests
// reproduce its standard input pipe, but only a real sshd, antivirus scanning
// and SCM show the whole deployment. Configure them with environment variables;
// nothing about the host belongs in the repository.
//
//	MISAKA_TEST_WINDOWS_SSH=user@host[:port]  administrator account whose host
//	                                          key ~/.ssh/known_hosts already pins
//	MISAKA_TEST_WINDOWS_SSH_KEY=path          unencrypted private key (default
//	                                          ~/.ssh/id_ed25519, then id_rsa)
//	MISAKA_TEST_WINDOWS_BUNDLE=path           windows-amd64.tar.gz of this version
//	MISAKA_TEST_WINDOWS_SSH_DEPLOY=1          also deploy, which installs and then
//	                                          removes the MisakaSisters service
type liveWindowsTarget struct {
	user, host  string
	port        int
	key         string
	fingerprint string
}

func liveWindows(t *testing.T) liveWindowsTarget {
	t.Helper()
	spec := os.Getenv("MISAKA_TEST_WINDOWS_SSH")
	if spec == "" {
		t.Skip("set MISAKA_TEST_WINDOWS_SSH=user@host[:port] to test against a real Windows OpenSSH server")
	}
	user, address, ok := strings.Cut(spec, "@")
	if !ok || user == "" || address == "" {
		t.Fatal("MISAKA_TEST_WINDOWS_SSH must be user@host[:port]")
	}
	target := liveWindowsTarget{user: user, host: address, port: 22}
	if host, port, err := net.SplitHostPort(address); err == nil {
		target.host = host
		if target.port, err = strconv.Atoi(port); err != nil {
			t.Fatal("invalid SSH port")
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	target.key = os.Getenv("MISAKA_TEST_WINDOWS_SSH_KEY")
	for _, name := range []string{"id_ed25519", "id_rsa"} {
		if target.key == "" {
			if _, err := os.Stat(filepath.Join(home, ".ssh", name)); err == nil {
				target.key = filepath.Join(home, ".ssh", name)
			}
		}
	}
	if target.key == "" {
		t.Fatal("no private key; set MISAKA_TEST_WINDOWS_SSH_KEY")
	}
	// Accept only the host key the user already trusts, then pin it the way
	// a deployment does after its first connection.
	known, err := knownhosts.New(filepath.Join(home, ".ssh", "known_hosts"))
	if err != nil {
		t.Fatalf("cannot read known_hosts: %v", err)
	}
	auth, err := deploymentAuth(Request{PrivateKeyPath: target.key})
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ClientConfig{User: target.user, Auth: auth, Timeout: 15 * time.Second, HostKeyCallback: func(name string, remote net.Addr, key ssh.PublicKey) error {
		if err := known(name, remote, key); err != nil {
			return err
		}
		target.fingerprint = ssh.FingerprintSHA256(key)
		return nil
	}}
	client, err := ssh.Dial("tcp", net.JoinHostPort(target.host, strconv.Itoa(target.port)), config)
	if err != nil {
		t.Fatalf("SSH connection with a known host key failed: %v", err)
	}
	client.Close()
	return target
}

// connect connects as Deploy does, with stall detection, so a connection left
// idle past stallTimeout closes.
func (target liveWindowsTarget) connect() (*ssh.Client, error) {
	auth, err := deploymentAuth(Request{PrivateKeyPath: target.key})
	if err != nil {
		return nil, err
	}
	address := net.JoinHostPort(target.host, strconv.Itoa(target.port))
	raw, err := (&net.Dialer{Timeout: 15 * time.Second}).Dial("tcp", address)
	if err != nil {
		return nil, err
	}
	conn := &stallConn{Conn: raw, idle: stallTimeout}
	raw.SetDeadline(time.Now().Add(handshakeTimeout))
	sc, channels, requests, err := ssh.NewClientConn(conn, address, &ssh.ClientConfig{User: target.user, Auth: auth, HostKeyCallback: hostCallback(target.fingerprint), Timeout: 15 * time.Second})
	if err != nil {
		conn.Close()
		return nil, err
	}
	conn.watch()
	return ssh.NewClient(sc, channels, requests), nil
}

func (target liveWindowsTarget) dial(t *testing.T) *ssh.Client {
	t.Helper()
	client, err := target.connect()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

// pacedReader yields data in chunks separated by pauses, as a slow uplink does.
type pacedReader struct {
	data  []byte
	chunk int
	pause time.Duration
	sent  int
}

func (r *pacedReader) Read(p []byte) (int, error) {
	if r.sent >= len(r.data) {
		return 0, io.EOF
	}
	if r.sent > 0 {
		time.Sleep(r.pause)
	}
	n := copy(p, r.data[r.sent:min(r.sent+r.chunk, len(r.data))])
	r.sent += n
	return n, nil
}

// liveRun runs script as runPowerShell does, but reports the exception on
// standard error and gives up after limit. Giving up closes the connection: a
// session whose command stopped reading keeps its writer waiting for window
// space, so closing the session alone does not end it.
func liveRun(t *testing.T, c *ssh.Client, script string, input io.Reader, limit time.Duration) (output, diagnostics string, stalled bool, err error) {
	t.Helper()
	session, err := c.NewSession()
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.Stdin = input
	var out, errOut limitedBuffer
	session.Stdout, session.Stderr = &out, &errOut
	wrapped := windowsRemoteScript(script)
	if !strings.Contains(wrapped, "catch { exit 1 }") {
		t.Fatal("PowerShell wrapper changed; update the diagnostic catch")
	}
	wrapped = strings.Replace(wrapped, "catch { exit 1 }", "catch { [Console]::Error.Write($_.Exception.ToString()); exit 1 }", 1)
	if err := session.Start(powershellCommand(wrapped)); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- session.Wait() }()
	select {
	case err = <-done:
	case <-time.After(limit):
		stalled = true
		c.Close()
		err = <-done
	}
	text := out.String()
	if i := strings.Index(text, outputMarker); i >= 0 {
		text = text[i+len(outputMarker):]
	}
	return strings.TrimSpace(text), errOut.String(), stalled, err
}

var liveTemporaryDirectory = regexp.MustCompile(`^[A-Za-z]:\\[^"<>|?*]+\\misaka-live-[0-9a-f]{32}$`)

// liveTemporary creates a directory under the remote user's temporary folder
// and removes it after the test.
func liveTemporary(t *testing.T, c *ssh.Client) string {
	t.Helper()
	path, err := runPowerShell(c, `$d=[IO.Path]::Combine([IO.Path]::GetTempPath(),'misaka-live-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($d);[Console]::Write([IO.Path]::GetFullPath($d))`, nil)
	if err != nil || !liveTemporaryDirectory.MatchString(path) {
		t.Fatalf("cannot create remote temporary directory: %q %v", path, err)
	}
	t.Cleanup(func() {
		if _, err := runPowerShell(c, `Remove-Item -LiteralPath `+powershellQuote(path)+` -Recurse -Force`, nil); err != nil {
			t.Errorf("remote temporary directory not removed: %v", err)
		}
	})
	return path
}

// The 0.4.0 failure on a real server: the console stream stops reading once
// the pipe runs empty and never resumes. The stalled PowerShell outlives the
// SSH session, because sshd leaves its job to cmd.exe, so the test ends it.
func TestLiveWindowsConsoleStreamStalls(t *testing.T) {
	target := liveWindows(t)
	client := target.dial(t)
	directory := liveTemporary(t, client)
	stalling := target.dial(t) // closed when the command is given up
	script := `[IO.File]::WriteAllText(` + powershellQuote(directory+`\pid`) + `,[string]$PID);$stdin=[Console]::OpenStandardInput();$buffer=New-Object byte[] 65536;$total=0
while (($read=$stdin.Read($buffer,0,$buffer.Length)) -gt 0) {$total+=$read}
[Console]::Write($total)`
	input := &pacedReader{data: make([]byte, 256<<10), chunk: 16 << 10, pause: 100 * time.Millisecond}
	output, diagnostics, stalled, err := liveRun(t, stalling, script, input, 30*time.Second)
	// End the stalled process before the temporary directory is removed.
	stop := `$file=` + powershellQuote(directory+`\pid`) + `;if (Test-Path -LiteralPath $file) {$id=[int](Get-Content -LiteralPath $file);$p=Get-CimInstance Win32_Process -Filter "ProcessId=$id";if ($p -and $p.Name -eq 'powershell.exe' -and $p.CommandLine -like '*-EncodedCommand*') {Stop-Process -Id $id -Force;'stopped'} else {'gone'}}`
	ended, stopErr := runPowerShell(client, stop, nil)
	t.Logf("console stream: stalled=%v output=%q error=%v; stalled process %s (%v)", stalled, output, err, ended, stopErr)
	if !stalled {
		t.Skipf("console stream did not stall on this server: output=%q stderr=%q", output, diagnostics)
	}
}

func TestLiveWindowsStandardInputHelper(t *testing.T) {
	target := liveWindows(t)
	client := target.dial(t)
	data := make([]byte, 1<<20)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	script := windowsStandardInputHelper + `$stdin=Open-StandardInput;$hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 65536;$total=0
while (($read=$stdin.Read($buffer,0,$buffer.Length)) -gt 0) {[void]$hash.TransformBlock($buffer,0,$read,$null,0);$total+=$read}
[void]$hash.TransformFinalBlock($buffer,0,0)
[Console]::Write([string]$total+' '+[BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant())`
	started := time.Now()
	output, diagnostics, stalled, err := liveRun(t, client, script, &pacedReader{data: data, chunk: 16 << 10, pause: 20 * time.Millisecond}, 2*time.Minute)
	want := fmt.Sprintf("%d %x", len(data), sha256.Sum256(data))
	if stalled || err != nil || output != want {
		t.Fatalf("paced standard input not read completely: stalled=%v error=%v output=%q want=%q stderr=%q", stalled, err, output, want, diagnostics)
	}
	t.Logf("read %d paced bytes through Open-StandardInput in %v", len(data), time.Since(started).Round(time.Millisecond))
}

func liveWindowsBundle(t *testing.T) string {
	t.Helper()
	path := os.Getenv("MISAKA_TEST_WINDOWS_BUNDLE")
	if path == "" {
		t.Skip("set MISAKA_TEST_WINDOWS_BUNDLE to the windows-amd64.tar.gz of this version")
	}
	if err := CheckBundle(path, "windows", "amd64"); err != nil {
		t.Fatalf("bundle rejected: %v", err)
	}
	return path
}

// bundleDigests lists the SHA-256 of every regular file in a tar.gz bundle.
func bundleDigests(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	digests := map[string]string{}
	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return digests
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg || header.Typeflag == tar.TypeRegA {
			hash := sha256.New()
			if _, err := io.Copy(hash, reader); err != nil {
				t.Fatal(err)
			}
			digests[strings.TrimPrefix(header.Name, "./")] = hex.EncodeToString(hash.Sum(nil))
		}
	}
}

// The upload and secret scripts exactly as deployWindows runs them, with the
// release bundle, into a temporary directory instead of the service tree.
func TestLiveWindowsUploadAndSecretScripts(t *testing.T) {
	target := liveWindows(t)
	path := liveWindowsBundle(t)
	client := target.dial(t)
	release := liveTemporary(t, client)
	bundle, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer bundle.Close()
	stopKeepalive := keepAlive(client, stagingKeepalive)
	defer stopKeepalive()
	started := time.Now()
	stream, converted := windowsBundleZIP(bundle)
	_, runErr := runPowerShell(client, windowsUploadScript(release), stream)
	stream.Close()
	if convertErr := <-converted; runErr != nil || convertErr != nil {
		t.Fatalf("%s (run: %v, conversion: %v)", windowsUploadError(runErr, convertErr), runErr, convertErr)
	}
	t.Logf("uploaded and extracted the release bundle in %v", time.Since(started).Round(time.Millisecond))
	listing, err := runPowerShell(client, `$root=`+powershellQuote(release)+`;Get-ChildItem -LiteralPath $root -Recurse -File|ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')+' '+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}`, nil)
	if err != nil {
		t.Fatal(err)
	}
	remote := map[string]string{}
	for _, line := range strings.Split(listing, "\n") {
		// Names may contain spaces; digests never do.
		line = strings.TrimSpace(line)
		if i := strings.LastIndex(line, " "); i > 0 {
			remote[line[:i]] = line[i+1:]
		}
	}
	local := bundleDigests(t, path)
	var mismatched []string
	for name, digest := range local {
		if remote[name] != digest {
			mismatched = append(mismatched, name)
		}
	}
	sort.Strings(mismatched)
	if len(mismatched) > 0 || len(remote) != len(local) {
		t.Fatalf("extracted tree differs: %d remote / %d local files, mismatched %v", len(remote), len(local), mismatched)
	}
	secrets := map[string][]byte{"server.pem": []byte("certificate"), "server.key": make([]byte, 4096), "ca.pem": []byte("authority"), "config.json": []byte(`{"listen":"127.0.0.1:1"}`)}
	if _, err := rand.Read(secrets["server.key"]); err != nil {
		t.Fatal(err)
	}
	payload, _ := json.Marshal(secrets)
	if _, err := runPowerShell(client, windowsSecretScript(release), &pacedReader{data: payload, chunk: 1024, pause: 50 * time.Millisecond}); err != nil {
		t.Fatalf("secret configuration not written: %v", err)
	}
	for name, want := range secrets {
		digest, err := runPowerShell(client, `(Get-FileHash -LiteralPath `+powershellQuote(release+`\`+name)+` -Algorithm SHA256).Hash.ToLowerInvariant()`, nil)
		if sum := sha256.Sum256(want); err != nil || digest != hex.EncodeToString(sum[:]) {
			t.Fatalf("%s written incorrectly: %v", name, err)
		}
	}
	t.Logf("verified %d extracted files and %d secret files", len(remote), len(secrets))
}

// A complete deployment through Deploy, the entry point LastOrder uses, into a
// private tree of its own. The service is removed afterwards; an existing
// MisakaSisters service makes the test refuse to run.
func TestLiveWindowsDeploy(t *testing.T) {
	target := liveWindows(t)
	path := liveWindowsBundle(t)
	if os.Getenv("MISAKA_TEST_WINDOWS_SSH_DEPLOY") != "1" {
		t.Skip("set MISAKA_TEST_WINDOWS_SSH_DEPLOY=1 to install and remove the MisakaSisters service")
	}
	client := target.dial(t)
	state, err := runPowerShell(client, windowsServiceHelpers+`if ($null -ne (Find-Service)) {'service'} elseif (@(Get-NetTCPConnection -LocalPort 20001 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {'port'} else {'free'}`, nil)
	if err != nil || state != "free" {
		t.Skipf("host is not free for a test deployment (%q, %v)", state, err)
	}
	nonce := make([]byte, 4)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	directory := "misaka-live-" + hex.EncodeToString(nonce)
	root, err := runPowerShell(client, `[Console]::Write([IO.Path]::Combine([Environment]::GetFolderPath('CommonApplicationData'),'MisakaNetwork',`+powershellQuote(directory)+`))`, nil)
	if err != nil || !strings.HasSuffix(root, `\MisakaNetwork\`+directory) {
		t.Fatalf("cannot resolve the test deployment root: %q %v", root, err)
	}
	client.Close() // a deployment can outlast its stall timeout
	t.Cleanup(func() {
		cleanup := windowsServiceHelpers + `$root=` + powershellQuote(root) + `
$s=Find-Service
if ($null -ne $s) {
  if (!$s.PathName.StartsWith('"'+$root+'\releases\')) {throw 'refusing to remove a service outside the test root'}
  Stop-Sisters
  Check-Result (Invoke-CimMethod -InputObject $s -MethodName Delete)
  $deadline=[DateTime]::UtcNow.AddSeconds(10);while ($null -ne (Find-Service)) {if ([DateTime]::UtcNow -ge $deadline) {throw 'service deletion pending'};Start-Sleep -Milliseconds 200}
}
if (Test-Path -LiteralPath $root) {Remove-Item -LiteralPath $root -Recurse -Force}
'removed'`
		output, err := "", error(nil)
		cleanupClient, err := target.connect()
		if err == nil {
			output, err = runPowerShell(cleanupClient, cleanup, nil)
			cleanupClient.Close()
		}
		t.Logf("test deployment cleanup: %q %v", output, err)
		if err != nil || output != "removed" {
			t.Errorf("test deployment not fully removed; check the MisakaSisters service and %s", directory)
		}
	})
	work := t.TempDir()
	progressPath := filepath.Join(work, "progress.json")
	started := time.Now()
	last := ""
	logStage := func() {
		data, _ := os.ReadFile(progressPath)
		var progress DeploymentProgress
		if json.Unmarshal(data, &progress) == nil && progress.Stage != last {
			last = progress.Stage
			t.Logf("%6.1fs %3d%% %s", time.Since(started).Seconds(), progress.Percent, progress.Stage)
		}
	}
	stop, polled := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(polled)
		for {
			logStage()
			select {
			case <-time.After(200 * time.Millisecond):
			case <-stop:
				return
			}
		}
	}()
	result, err := Deploy(Request{Host: target.host, Port: target.port, Username: target.user, PrivateKeyPath: target.key, HostKeyFingerprint: target.fingerprint, BundlePath: path, RemoteDirectory: directory, PKIDirectory: filepath.Join(work, "pki"), GRPCPort: 20001, ProgressPath: progressPath})
	close(stop)
	<-polled
	logStage()
	if err != nil {
		t.Fatalf("deployment failed after %v: %v", time.Since(started).Round(time.Second), err)
	}
	if result.Platform != "windows" || result.Arch != "amd64" {
		t.Fatalf("unexpected platform: %+v", result)
	}
	t.Logf("deployed in %v; direct connection from this machine: %v", time.Since(started).Round(time.Second), result.Reachable)
	status, err := runPowerShell(target.dial(t), windowsServiceHelpers+`$s=Find-Service;@{state=$s.State;account=$s.StartName;mode=$s.StartMode}|ConvertTo-Json -Compress`, nil)
	if err != nil || !strings.Contains(status, `"state":"Running"`) || !strings.Contains(status, `NT SERVICE\\MisakaSisters`) {
		t.Fatalf("service not running under its virtual account: %q %v", status, err)
	}
	t.Logf("service: %s", status)
}
