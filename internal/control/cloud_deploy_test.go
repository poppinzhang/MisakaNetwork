package control

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func cloudAuthSSHFixture(t *testing.T, publicKey string) (string, ssh.PublicKey, *atomic.Int32, <-chan error) {
	t.Helper()
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(publicKey))
	if err != nil {
		t.Fatal(err)
	}
	hostKey, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.ParsePrivateKey([]byte(hostKey.PrivateKey))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	attempts := new(atomic.Int32)
	server := &ssh.ServerConfig{PublicKeyCallback: func(metadata ssh.ConnMetadata, actual ssh.PublicKey) (*ssh.Permissions, error) {
		attempts.Add(1)
		if metadata.User() != "ubuntu" || !bytes.Equal(actual.Marshal(), key.Marshal()) {
			return nil, errors.New("server-private-test-value")
		}
		return nil, nil
	}}
	server.AddHostKey(signer)
	finished := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			finished <- acceptErr
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		connection, _, _, handshakeErr := ssh.NewServerConn(conn, server)
		if connection != nil {
			defer connection.Close()
		}
		finished <- handshakeErr
	}()
	return listener.Addr().String(), signer.PublicKey(), attempts, finished
}

func TestCloudDeploymentPrivateKeyAuthenticatesWithoutFile(t *testing.T) {
	identity, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal(err)
	}
	wrongIdentity, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, username, privateKey string
		accepted                   bool
	}{
		{"root rejected", "root", identity.PrivateKey, false},
		{"Ubuntu accepted", "ubuntu", identity.PrivateKey, true},
		{"different key rejected", "ubuntu", wrongIdentity.PrivateKey, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			address, hostKey, _, finished := cloudAuthSSHFixture(t, identity.PublicKey)
			auth, err := deploymentAuth(Request{PrivateKey: tc.privateKey})
			if err != nil {
				t.Fatal(err)
			}
			client, err := ssh.Dial("tcp", address, &ssh.ClientConfig{
				User: tc.username, Auth: auth, HostKeyCallback: hostCallback(ssh.FingerprintSHA256(hostKey)), Timeout: 5 * time.Second,
			})
			if !tc.accepted {
				if err == nil {
					client.Close()
					t.Fatal("unexpected account or key was accepted")
				}
				if !strings.Contains(deploymentHandshakeError(err).Error(), "SSH 认证被拒绝") {
					t.Fatal("authentication rejection was not classified")
				}
				if <-finished == nil {
					t.Fatal("server accepted an unexpected account")
				}
				return
			}
			if err != nil {
				t.Fatal("in-memory key authentication failed for ubuntu")
			}
			client.Close()
			if err := <-finished; err != nil {
				t.Fatal("server did not accept the stored cloud identity")
			}
		})
	}
}

func TestCloudDeploymentRequiresMatchingHostPinBeforeAuthentication(t *testing.T) {
	identity, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal(err)
	}
	for _, pin := range []string{"", "SHA256:wrong-test-fingerprint"} {
		t.Run(pin, func(t *testing.T) {
			address, hostKey, attempts, finished := cloudAuthSSHFixture(t, identity.PublicKey)
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				t.Fatal(err)
			}
			portNumber, _ := strconv.Atoi(port)
			result := Handle(Request{Action: "deploy", Host: host, Port: portNumber, Username: "ubuntu", PrivateKey: identity.PrivateKey, HostKeyFingerprint: pin, PKIDirectory: t.TempDir(), EnableLingerWithSudo: true})
			if result.OK || result.Error == "" {
				t.Fatal("unconfirmed or incorrect host key was accepted")
			}
			if pin == "" && result.Fingerprint != ssh.FingerprintSHA256(hostKey) {
				t.Fatal("missing fingerprint confirmation")
			}
			if pin != "" && (result.Error != errHostKeyMismatch.Error() || result.Fingerprint != "") {
				t.Fatal("mismatched host key did not fail closed")
			}
			<-finished
			if attempts.Load() != 0 {
				t.Fatal("credentials were offered before host verification")
			}
		})
	}
}

func TestDeploymentHandshakeDiagnosticsDoNotLeakRemoteDetails(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{fmt.Errorf("ssh: handshake failed: %w", &net.OpError{Op: "read", Net: "tcp", Err: os.ErrDeadlineExceeded}), "SSH 握手超时"},
		{fmt.Errorf("ssh: handshake failed: %w", io.EOF), "SSH 握手未完成"},
		{errors.New("ssh: no common algorithm: private-test-value"), "SSH 握手未完成"},
		{errors.New("ssh: disconnect: private-test-value: ssh: unable to authenticate, attempted methods [publickey], no supported methods remain"), "SSH 握手未完成"},
		{fmt.Errorf("ssh: handshake failed: %w", errors.New("ssh: unable to authenticate, attempted methods [none publickey], no supported methods remain")), "SSH 认证被拒绝"},
	} {
		message := deploymentHandshakeError(tc.err).Error()
		if !strings.Contains(message, tc.want) || strings.Contains(message, "private-test-value") {
			t.Fatalf("unexpected sanitized error: %s", message)
		}
	}
}

func TestCloudDeploymentPrivateKeyRejectsAmbiguityAndSanitizesErrors(t *testing.T) {
	for _, request := range []Request{
		{PrivateKey: "private-test-value", Password: "password-test-value"},
		{PrivateKey: "private-test-value", PrivateKeyPath: "nonexistent-test-file"},
		{PrivateKey: "private-test-value", PrivateKeyPassphrase: "passphrase-test-value"},
		{PrivateKey: "private-test-value"},
		{PrivateKey: strings.Repeat("private-test-value", 65536)},
	} {
		request.Action = "deploy"
		request.Host = "192.0.2.1"
		request.Username = "root"
		request.PKIDirectory = t.TempDir()
		result := Handle(request)
		encoded, err := json.Marshal(result)
		if err != nil || result.OK || result.Error == "" {
			t.Fatal("invalid or ambiguous credential was accepted")
		}
		for _, marker := range []string{"private-test-value", "password-test-value", "nonexistent-test-file", "passphrase-test-value"} {
			if bytes.Contains(encoded, []byte(marker)) {
				t.Fatal("credential details leaked in deployment error")
			}
		}
	}
}

func TestCloudLingerSudoRequiresUbuntuAndExclusiveInMemoryKey(t *testing.T) {
	for _, tc := range []struct {
		name    string
		request Request
		wantErr bool
	}{
		{"cloud Ubuntu", Request{Username: "ubuntu", PrivateKey: "test-key", EnableLingerWithSudo: true}, false},
		{"root forbidden", Request{Username: "root", PrivateKey: "test-key", EnableLingerWithSudo: true}, true},
		{"other account forbidden", Request{Username: "ticket", PrivateKey: "test-key", EnableLingerWithSudo: true}, true},
		{"password forbidden", Request{Username: "ubuntu", Password: "test-password", EnableLingerWithSudo: true}, true},
		{"file key forbidden", Request{Username: "ubuntu", PrivateKeyPath: "test-path", EnableLingerWithSudo: true}, true},
		{"mixed password forbidden", Request{Username: "ubuntu", PrivateKey: "test-key", Password: "test-password", EnableLingerWithSudo: true}, true},
		{"mixed path forbidden", Request{Username: "ubuntu", PrivateKey: "test-key", PrivateKeyPath: "test-path", EnableLingerWithSudo: true}, true},
		{"passphrase forbidden", Request{Username: "ubuntu", PrivateKey: "test-key", PrivateKeyPassphrase: "test-passphrase", EnableLingerWithSudo: true}, true},
		{"generic password unchanged", Request{Username: "ticket", Password: "test-password"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := tc.request
			request.Host = "192.0.2.1"
			request.PKIDirectory = t.TempDir()
			if err := validate(&request); (err != nil) != tc.wantErr {
				t.Fatalf("unexpected validation: %v", err)
			}
		})
	}
}

func TestCloudUbuntuLingerSudoIsExplicitBoundedAndVerified(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("remote POSIX service fixture requires a POSIX shell")
	}
	for _, tc := range []struct {
		name, initial, username                      string
		optIn, selfEnable, allowSudo, sudoSetsLinger bool
		wantSudo, wantErr                            bool
	}{
		{"already enabled", "yes", "ubuntu", true, false, true, true, false, false},
		{"self service", "no", "ubuntu", true, true, true, true, false, false},
		{"explicit cloud sudo", "no", "ubuntu", true, false, true, true, true, false},
		{"generic Ubuntu unchanged", "no", "ubuntu", false, false, true, true, false, true},
		{"sudo permission denied", "no", "ubuntu", true, false, false, false, true, true},
		{"sudo success requires recheck", "no", "ubuntu", true, false, true, false, true, true},
		{"different account forbidden", "no", "ticket", true, false, true, true, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			state := filepath.Join(dir, "linger")
			logPath := filepath.Join(dir, "sudo-commands")
			if err := os.WriteFile(state, []byte(tc.initial+"\n"), 0600); err != nil {
				t.Fatal(err)
			}
			shim := filepath.Join(dir, "bin")
			if err := os.MkdirAll(shim, 0700); err != nil {
				t.Fatal(err)
			}
			enable := "exit 1"
			if tc.selfEnable {
				enable = "echo yes > " + shellQuote(state)
			} else if tc.sudoSetsLinger {
				enable = `[ "$MISAKA_TEST_LINGER_SUDO" = 1 ] && echo yes > ` + shellQuote(state)
			}
			loginctl := "#!/bin/sh\ncase \"$1\" in\nshow-user) cat " + shellQuote(state) + " ;;\nenable-linger) " + enable + " ;;\n*) exit 1 ;;\nesac\n"
			if err := os.WriteFile(filepath.Join(shim, "loginctl"), []byte(loginctl), 0700); err != nil {
				t.Fatal(err)
			}
			sudoAction := "exit 1"
			if tc.allowSudo {
				sudoAction = `shift; MISAKA_TEST_LINGER_SUDO=1 "$@"`
				if !tc.sudoSetsLinger {
					sudoAction = "exit 0"
				}
			}
			sudo := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + shellQuote(logPath) + "\n" +
				`[ "$#" = 4 ] && [ "$1" = -n ] && [ "$2" = loginctl ] && [ "$3" = enable-linger ] && [ "$4" = ubuntu ] || exit 1` + "\n" + sudoAction + "\n"
			if err := os.WriteFile(filepath.Join(shim, "sudo"), []byte(sudo), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", shim+":"+os.Getenv("PATH"))
			err := ensureLinger(localSSH(t), tc.username, tc.optIn)
			if (err != nil) != tc.wantErr {
				t.Fatalf("unexpected linger result: %v", err)
			}
			if err != nil && !strings.Contains(err.Error(), "sudo loginctl enable-linger "+tc.username) {
				t.Fatal("missing administrator instructions")
			}
			commands, _ := os.ReadFile(logPath)
			if tc.wantSudo {
				if string(commands) != "-n loginctl enable-linger ubuntu\n" {
					t.Fatalf("unexpected sudo command: %s", commands)
				}
			} else if len(commands) != 0 {
				t.Fatal("sudo was attempted without need or permission")
			}
		})
	}
}
