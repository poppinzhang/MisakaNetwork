package control

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// sshCommandResult is what a command started like a Win32-OpenSSH session
// produced.
type sshCommandResult struct {
	output      string // after outputMarker
	diagnostics string
	exitCode    uint32
	stalled     bool
	feedErr     error
}

func (r sshCommandResult) String() string {
	return fmt.Sprintf("stalled=%v exit=%d output=%q stderr=%q input=%v", r.stalled, r.exitCode, r.output, r.diagnostics, r.feedErr)
}

// markerOutput collects standard output and closes ready once outputMarker
// shows that the script has started.
type markerOutput struct {
	mu    sync.Mutex
	data  bytes.Buffer
	ready chan struct{}
	once  sync.Once
}

func (o *markerOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.data.Write(p)
	if bytes.Contains(o.data.Bytes(), []byte(outputMarker)) {
		o.once.Do(func() { close(o.ready) })
	}
	return len(p), nil
}

func (o *markerOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	text := o.data.String()
	if i := strings.Index(text, outputMarker); i >= 0 {
		return strings.TrimSpace(text[i+len(outputMarker):])
	}
	return "(no output marker) " + text
}

// startInheriting starts commandLine as Win32-OpenSSH starts a session command
// (spawn_child_internal in contrib/win32/win32compat/w32fd.c): the standard
// handles are the only ones on the inheritance allow-list. It returns the
// process handle.
func startInheriting(commandLine string, stdin, stdout, stderr windows.Handle) (windows.Handle, error) {
	command, err := windows.UTF16PtrFromString(commandLine)
	if err != nil {
		return 0, err
	}
	attributes, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		return 0, err
	}
	defer attributes.Delete()
	handles := []windows.Handle{stdin, stdout, stderr}
	if err := attributes.Update(windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, unsafe.Pointer(&handles[0]), uintptr(len(handles))*unsafe.Sizeof(handles[0])); err != nil {
		return 0, err
	}
	startup := &windows.StartupInfoEx{
		StartupInfo: windows.StartupInfo{
			Cb:        uint32(unsafe.Sizeof(windows.StartupInfoEx{})),
			Flags:     windows.STARTF_USESTDHANDLES,
			StdInput:  stdin,
			StdOutput: stdout,
			StdErr:    stderr,
		},
		ProcThreadAttributeList: attributes.List(),
	}
	var process windows.ProcessInformation
	if err := windows.CreateProcess(nil, command, nil, nil, true, windows.CREATE_NO_WINDOW|windows.EXTENDED_STARTUPINFO_PRESENT, nil, nil, &startup.StartupInfo, &process); err != nil {
		return 0, err
	}
	windows.CloseHandle(process.Thread)
	return process.Process, nil
}

// writeInChunks writes data in chunks, each after a pause.
func writeInChunks(pipe windows.Handle, data []byte, chunk int, pause time.Duration) error {
	for sent := 0; sent < len(data); {
		time.Sleep(pause)
		end := min(sent+chunk, len(data))
		for sent < end {
			var written uint32
			if err := windows.WriteFile(pipe, data[sent:end], &written, nil); err != nil {
				return err
			}
			sent += int(written)
		}
	}
	return nil
}

// runWithSSHStandardInput runs script, wrapped as runPowerShell sends it, in
// Windows PowerShell whose standard input is arranged as Win32-OpenSSH arranges
// it for a command without a terminal (do_exec_windows and fileio_pipe in
// contrib/win32/win32compat): the client end of a byte-mode named pipe with
// 4 KiB buffers, opened with FILE_FLAG_OVERLAPPED. Input starts once the script
// prints outputMarker and arrives in chunks separated by pauses, so the reader
// keeps finding the pipe empty. A command that has not finished within limit
// is terminated and reported as stalled.
//
// sshd starts the command through cmd.exe /c, which hands this handle on
// unchanged; the test starts PowerShell directly so that terminating a stall
// also releases the pipe. sshd writes its end with overlapped I/O, which the
// reading end cannot observe, so the test writes synchronously. The reading
// handle goes to CreateProcess directly: os.NewFile would attach an overlapped
// handle to the Go runtime's completion port and change how the child's reads
// on that pipe complete.
func runWithSSHStandardInput(t *testing.T, script string, input []byte, limit time.Duration) sshCommandResult {
	t.Helper()
	wrapped := windowsRemoteScript(script)
	if !strings.Contains(wrapped, "catch { exit 1 }") {
		t.Fatal("PowerShell wrapper changed; update the diagnostic catch")
	}
	// Report the exception on standard error, which the production runner
	// discards, instead of only exiting 1.
	wrapped = strings.Replace(wrapped, "catch { exit 1 }", "catch { [Console]::Error.Write($_.Exception.ToString()); exit 1 }", 1)
	nonce := make([]byte, 8)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	name, err := windows.UTF16PtrFromString(`\\.\pipe\misaka-ssh-stdin-` + hex.EncodeToString(nonce))
	if err != nil {
		t.Fatal(err)
	}
	server, err := windows.CreateNamedPipe(name, windows.PIPE_ACCESS_OUTBOUND, windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT, 1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	inheritable := &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), InheritHandle: 1}
	stdin, err := windows.CreateFile(name, windows.GENERIC_READ, 0, inheritable, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OVERLAPPED, 0)
	if err != nil {
		windows.CloseHandle(server)
		t.Fatal(err)
	}
	var stdoutRead, stdoutWrite, stderrRead, stderrWrite windows.Handle
	if err = windows.CreatePipe(&stdoutRead, &stdoutWrite, inheritable, 0); err == nil {
		if err = windows.CreatePipe(&stderrRead, &stderrWrite, inheritable, 0); err != nil {
			windows.CloseHandle(stdoutRead)
			windows.CloseHandle(stdoutWrite)
		}
	}
	if err != nil {
		windows.CloseHandle(stdin)
		windows.CloseHandle(server)
		t.Fatal(err)
	}
	stdout := os.NewFile(uintptr(stdoutRead), "powershell-stdout")
	stderr := os.NewFile(uintptr(stderrRead), "powershell-stderr")
	defer stdout.Close()
	defer stderr.Close()
	process, err := startInheriting(powershellCommand(wrapped), stdin, stdoutWrite, stderrWrite)
	// The child holds its own copies; ours would keep the pipes open.
	windows.CloseHandle(stdin)
	windows.CloseHandle(stdoutWrite)
	windows.CloseHandle(stderrWrite)
	if err != nil {
		windows.CloseHandle(server)
		t.Fatal(err)
	}
	defer windows.CloseHandle(process)
	output := &markerOutput{ready: make(chan struct{})}
	var diagnostics bytes.Buffer
	outputDone, diagnosticsDone := make(chan struct{}), make(chan struct{})
	go func() { io.Copy(output, stdout); close(outputDone) }()
	go func() { io.Copy(&diagnostics, stderr); close(diagnosticsDone) }()
	fed := make(chan error, 1)
	go func() {
		var err error
		select {
		case <-output.ready:
			// Let the script reach its first read of the still empty pipe.
			time.Sleep(200 * time.Millisecond)
			err = writeInChunks(server, input, 16<<10, 50*time.Millisecond)
		case <-outputDone:
			err = errors.New("script ended before its input was sent")
		}
		windows.CloseHandle(server) // end of input, as when the client sends EOF
		fed <- err
	}()
	event, err := windows.WaitForSingleObject(process, uint32(limit/time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	stalled := event == uint32(windows.WAIT_TIMEOUT)
	if stalled {
		// Terminating the reader also fails a write still waiting for it.
		windows.TerminateProcess(process, 1)
		windows.WaitForSingleObject(process, windows.INFINITE)
	}
	feedErr := <-fed
	<-outputDone
	<-diagnosticsDone
	var code uint32
	if err := windows.GetExitCodeProcess(process, &code); err != nil {
		t.Fatal(err)
	}
	return sshCommandResult{output: output.String(), diagnostics: diagnostics.String(), exitCode: code, stalled: stalled, feedErr: feedErr}
}

// The cause of Windows deployments failing at 上传并解压安装包: reading SSH
// standard input through [Console]::OpenStandardInput() stalled whenever the
// overlapped pipe from Win32-OpenSSH ran empty. Open-StandardInput must read
// every byte however the input is paced.
func TestWindowsStandardInputHelperReadsSSHPipe(t *testing.T) {
	input := make([]byte, 192<<10)
	if _, err := rand.Read(input); err != nil {
		t.Fatal(err)
	}
	script := windowsStandardInputHelper + `$stdin=Open-StandardInput;$hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 65536;$total=0
while (($read=$stdin.Read($buffer,0,$buffer.Length)) -gt 0) {[void]$hash.TransformBlock($buffer,0,$read,$null,0);$total+=$read}
[void]$hash.TransformFinalBlock($buffer,0,0)
[Console]::Write([string]$total+' '+[BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant())`
	result := runWithSSHStandardInput(t, script, input, time.Minute)
	if want := fmt.Sprintf("%d %x", len(input), sha256.Sum256(input)); result.stalled || result.exitCode != 0 || result.output != want || result.feedErr != nil {
		t.Fatalf("SSH standard input not read completely (want %q): %s", want, result)
	}
}

func TestWindowsUploadScriptExtractsOverSSHPipe(t *testing.T) {
	random := make([]byte, 160<<10)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{
		"sisters.exe":                           random,
		"runtime/misaka-runtime.exe":            bytes.Repeat([]byte("MisakaNetwork runtime\n"), 8192),
		"runtime/_internal/用户 O'Brien/data.bin": random[:8192],
	}
	stream, converted := windowsBundleZIP(bytes.NewReader(tarGzipFiles(t, files)))
	archive, err := io.ReadAll(stream)
	stream.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err := <-converted; err != nil {
		t.Fatal(err)
	}
	release := t.TempDir()
	result := runWithSSHStandardInput(t, windowsUploadScript(release), archive, time.Minute)
	if result.stalled || result.exitCode != 0 || result.feedErr != nil {
		t.Fatalf("upload over SSH standard input failed: %s", result)
	}
	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(release, filepath.FromSlash(name)))
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("%s not extracted intact: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(release, "payload.zip")); !os.IsNotExist(err) {
		t.Fatalf("temporary archive left behind: %v", err)
	}
}

func TestWindowsSecretScriptWritesOverSSHPipe(t *testing.T) {
	files := map[string][]byte{"server.pem": make([]byte, 48<<10), "server.key": make([]byte, 48<<10), "ca.pem": make([]byte, 48<<10), "config.json": []byte(`{"listen":"0.0.0.0:20001"}`)}
	for _, name := range []string{"server.pem", "server.key", "ca.pem"} {
		if _, err := rand.Read(files[name]); err != nil {
			t.Fatal(err)
		}
	}
	input, err := json.Marshal(files)
	if err != nil {
		t.Fatal(err)
	}
	release := t.TempDir()
	result := runWithSSHStandardInput(t, windowsSecretScript(release), input, time.Minute)
	if result.stalled || result.exitCode != 0 || result.feedErr != nil {
		t.Fatalf("secret configuration over SSH standard input failed: %s", result)
	}
	for name, want := range files {
		if got, err := os.ReadFile(filepath.Join(release, name)); err != nil || !bytes.Equal(got, want) {
			t.Fatalf("%s not written intact: %v", name, err)
		}
	}
}

// Records the platform behavior Open-StandardInput exists to avoid: the .NET
// Framework console stream waits in WaitForAvailableConsoleInput before every
// read and does not wake for data arriving later on this pipe. Skips rather
// than fails if a future Windows update stops the stall.
func TestWindowsConsoleStreamStallsOnSSHPipe(t *testing.T) {
	input := make([]byte, 64<<10)
	script := `$stdin=[Console]::OpenStandardInput();$buffer=New-Object byte[] 65536;$total=0
while (($read=$stdin.Read($buffer,0,$buffer.Length)) -gt 0) {$total+=$read}
[Console]::Write($total)`
	result := runWithSSHStandardInput(t, script, input, 15*time.Second)
	if !result.stalled {
		t.Skipf("console stream did not stall on this system: %s", result)
	}
	t.Logf("console stream stalled on SSH standard input, as expected: %s", result)
}
