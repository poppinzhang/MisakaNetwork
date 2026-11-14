package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestHandleInitializesPrivatePKI(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "support", "pki")
	data, _ := json.Marshal(control.Request{Action: "init_pki", Directory: directory})
	var response control.Response
	if err := json.Unmarshal(Handle(data, root), &response); err != nil || !response.OK {
		t.Fatalf("initialization failed: %v", err)
	}
	for _, name := range []string{"ca.pem", "ca.key", "client.pem", "client.key"} {
		info, err := os.Stat(filepath.Join(directory, name))
		// Windows uses a protected DACL; its native ACL regression lives in
		// internal/control/permissions_windows_test.go, not POSIX mode bits.
		if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
			t.Fatalf("invalid private key permissions: %v", err)
		}
	}
}

func TestHandleRejectsInvalidEnvelope(t *testing.T) {
	for _, input := range []string{"", "null", "[]", "{} {}", `{"action":"init_pki","extra":"secret"}`, strings.Repeat(" ", MaxRequestBytes+1)} {
		var response control.Response
		if err := json.Unmarshal(Handle([]byte(input), t.TempDir()), &response); err != nil || response.OK || strings.Contains(response.Error, "secret") {
			t.Fatalf("unexpected response for invalid request: %v", err)
		}
	}
}

func TestHandleRejectsEscapingPaths(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	link := filepath.Join(root, "link")
	candidates := []string{outside, "relative", root}
	if err := os.Symlink(outside, link); err == nil {
		candidates = append(candidates, filepath.Join(link, "new"))
	} else if runtime.GOOS != "windows" {
		t.Fatal(err)
	} else {
		t.Log("symlink subcase unavailable without Windows symlink privilege")
	}
	for _, candidate := range candidates {
		data, _ := json.Marshal(control.Request{Action: "init_pki", Directory: candidate})
		var response control.Response
		json.Unmarshal(Handle(data, root), &response)
		if response.OK || response.Error != "文件必须位于应用私有目录" {
			t.Fatalf("path was not rejected")
		}
	}
}

func TestProgressPathMustRemainPrivate(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	data, _ := json.Marshal(control.Request{Action: "deploy", ProgressPath: filepath.Join(outside, "progress.json")})
	var response control.Response
	json.Unmarshal(Handle(data, root), &response)
	if response.OK || response.Error != "文件必须位于应用私有目录" {
		t.Fatal("progress path escaped application storage")
	}
	if _, err := os.Stat(filepath.Join(outside, "progress.json")); !os.IsNotExist(err) {
		t.Fatal("outside file created")
	}
}
