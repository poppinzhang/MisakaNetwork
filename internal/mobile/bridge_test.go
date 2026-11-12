package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
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
		if err != nil || info.Mode().Perm() != 0600 {
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
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	for _, candidate := range []string{outside, filepath.Join(link, "new"), "relative", root} {
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
