package agent

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsJobClosesWhenSistersHostIsKilled(t *testing.T) {
	dir := t.TempDir()
	parentMarker, childMarker := filepath.Join(dir, "parent"), filepath.Join(dir, "child")
	r := fixtureRunner(t, runtimeFixture{Host: true, Child: true, Wait: true, Marker: parentMarker, ChildMarker: childMarker})
	host := exec.Command(r.path)
	if err := host.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = host.Process.Kill(); _ = host.Wait() })
	pids := []uint32{waitRuntimeMarker(t, parentMarker), waitRuntimeMarker(t, childMarker)}
	for _, pid := range pids {
		handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
		if err != nil {
			t.Fatal(err)
		}
		defer windows.CloseHandle(handle)
		// Hold a handle while the host is killed, so PID reuse cannot affect
		// the assertion that this exact process has exited.
		defer func() {
			state, err := windows.WaitForSingleObject(handle, 5000)
			if err != nil || state != windows.WAIT_OBJECT_0 {
				t.Errorf("job member survived host exit: %v / %v", state, err)
			}
		}()
	}
	if err := host.Process.Kill(); err != nil {
		t.Fatal(err)
	}
}

func TestWindowsRuntimeRegularFileDoesNotNeedUnixExecuteBits(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime.exe")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !runtimeExecutable(info) {
		t.Fatal("regular Windows executable rejected for Unix permissions")
	}
	info, err = os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if runtimeExecutable(info) {
		t.Fatal("directory accepted as executable")
	}
}
