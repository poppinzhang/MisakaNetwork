package control

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

func readProgress(t *testing.T, path string) DeploymentProgress {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var result DeploymentProgress
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestProgressSnapshotsArePrivateMonotonicAndExclusive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "progress.json")
	r, err := newProgressReporter(path)
	if err != nil {
		t.Fatal(err)
	}
	r.report(20, "上传并解压安装包")
	if got := readProgress(t, path); got.Percent != 20 || got.Stage != "上传并解压安装包" {
		t.Fatal("wrong snapshot")
	}
	r.report(60, "上传并解压安装包")
	r.report(40, "上传并解压安装包")
	r.report(101, "部署完成")
	if got := readProgress(t, path); got.Percent != 60 {
		t.Fatal("progress regressed or exceeded completion")
	}
	if _, err := newProgressReporter(path); err == nil {
		t.Fatal("existing file accepted")
	}
	info, err := os.Stat(path)
	if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
		t.Fatal("snapshot is not private")
	}
	files, _ := os.ReadDir(filepath.Dir(path))
	if len(files) != 1 {
		t.Fatal("temporary snapshots leaked")
	}
}

func TestUploadProgressUsesTransferredBytesAndNeverCompletesDeployment(t *testing.T) {
	var percentages []int
	r := &uploadProgressReader{
		reader: bytes.NewReader(make([]byte, 100)), total: 100,
		report: func(percent int, stage string) {
			if stage != "上传并解压安装包" {
				t.Fatal("unexpected stage")
			}
			percentages = append(percentages, percent)
		},
	}
	buffer := make([]byte, 20)
	for {
		_, err := r.Read(buffer)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(percentages) != 5 || percentages[0] != 31 || percentages[4] != 75 {
		t.Fatalf("unexpected upload progress: %v", percentages)
	}
}

func TestFailedDeploymentNeverWritesCompletionOrCredentials(t *testing.T) {
	path := filepath.Join(t.TempDir(), "progress.json")
	response := Handle(Request{Action: "deploy", Host: "node.example", Username: "operator", PKIDirectory: t.TempDir(), PrivateKeyPath: "synthetic-missing-secret", ProgressPath: path})
	if response.OK {
		t.Fatal("invalid deployment succeeded")
	}
	got := readProgress(t, path)
	if got.Percent != 2 || got.Stage != "准备部署" {
		t.Fatal("failed deployment published unrelated data")
	}
}

func TestConcurrentPKIInitialization(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "pki")
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if _, err := InitPKI(directory); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if _, err := InitPKI(directory); err != nil {
		t.Fatal(err)
	}
}

func TestPKIProcessHelper(t *testing.T) {
	path := os.Getenv("MISAKA_TEST_PKI_DIRECTORY")
	if path == "" {
		return
	}
	if _, err := InitPKI(path); err != nil {
		t.Fatal(err)
	}
}

func TestIndependentProcessesSharePKI(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "pki")
	var commands []*exec.Cmd
	for range 4 {
		command := exec.Command(os.Args[0], "-test.run=^TestPKIProcessHelper$")
		command.Env = append(os.Environ(), "MISAKA_TEST_PKI_DIRECTORY="+directory)
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		commands = append(commands, command)
	}
	for _, command := range commands {
		if err := command.Wait(); err != nil {
			t.Error("concurrent PKI process failed")
		}
	}
	// The lock file remains, but exiting helper processes release their locks.
	if _, err := InitPKI(directory); err != nil {
		t.Fatal(err)
	}
}
