package control

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestProtectPath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "credential")
	if err := os.WriteFile(file, []byte("test only"), 0644); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		name string
		mode os.FileMode
	}{{dir, 0700}, {file, 0600}} {
		response := Handle(Request{Action: "protect_path", Directory: item.name})
		if !response.OK {
			t.Fatalf("protection failed: %s", response.Error)
		}
		info, err := os.Stat(item.name)
		if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != item.mode) {
			t.Fatalf("incorrect private path mode: %v", err)
		}
	}
	for _, name := range []string{"", "relative", filepath.Join(dir, "missing")} {
		response := Handle(Request{Action: "protect_path", Directory: name})
		if response.OK || response.Error == "" || strings.Contains(response.Error, dir) {
			t.Fatal("invalid path accepted or path disclosed")
		}
	}
}

func TestProtectPathRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("test only"), 0644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Skip("symlink creation unavailable on this host")
	}
	if err := ProtectPath(link); err == nil {
		t.Fatal("symlink accepted as private file")
	}
}
