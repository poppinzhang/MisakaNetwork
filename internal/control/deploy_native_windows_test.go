package control

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func nativePowerShell(script string, input io.Reader) (string, error) {
	script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);try {\n" + script + "\n} catch { Write-Output $_.Exception.Message; exit 1 };exit 0"
	command := powershellCommand(script)
	encoded := strings.TrimPrefix(command, "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded)
	cmd.Stdin = input
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("PowerShell fixture: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

func TestWindowsDeploymentScriptsParseNatively(t *testing.T) {
	paths := windowsPaths{Root: `C:\ProgramData\用户 O'Brien\Sisters`, Release: `C:\ProgramData\用户 O'Brien\Sisters\releases\0.4.0-test`, Temp: `C:\ProgramData\用户 O'Brien\Sisters\tmp`}
	scripts := []string{windowsPrepareScript("Sisters", "0.4.0-test"), windowsUploadScript(paths.Release), windowsSecretScript(paths.Release), windowsPlatformScript}
	_ = activateWindows(func(script string, _ io.Reader) (string, error) {
		scripts = append(scripts, script)
		return "null", nil
	}, paths, func() error { return errors.New("force rollback") })
	for i, script := range scripts {
		parser := `$reader=New-Object IO.StreamReader([Console]::OpenStandardInput(),[Text.Encoding]::UTF8);$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput($reader.ReadToEnd(),[ref]$tokens,[ref]$errors)|Out-Null;if ($errors.Count -gt 0) {throw ($errors|Out-String)}`
		if _, err := nativePowerShell(parser, strings.NewReader(script)); err != nil {
			t.Fatalf("script %d: %v", i, err)
		}
	}
}

// This opt-in fixture runs only in the dedicated administrator Windows CI job.
// It never takes over an existing service. Every file and service it creates
// is tied to a fresh random private root and removed only after ownership checks.
func TestWindowsNativeDeploymentServiceLifecycle(t *testing.T) {
	if os.Getenv("MISAKA_TEST_WINDOWS_SERVICE") != "1" {
		t.Skip("set MISAKA_TEST_WINDOWS_SERVICE=1 on an isolated administrator Windows host")
	}
	output, err := nativePowerShell(windowsServiceHelpers+`if ($null -ne (Find-Service)) {throw 'existing MisakaSisters service; refusing test'};'ready'`, nil)
	if err != nil || output != "ready" {
		t.Fatalf("unsafe SCM fixture environment: %v", err)
	}
	nonce := make([]byte, 8)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	name := "native-test-" + hex.EncodeToString(nonce) + "-用户 O'Brien"
	firstID := Version + "-first"
	output, err = nativePowerShell(windowsPrepareScript(name, firstID), nil)
	if err != nil {
		t.Fatal(err)
	}
	first, err := parseWindowsPaths(output, firstID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		output, err := nativePowerShell(windowsServiceHelpers+`$s=Find-Service;if ($null -eq $s) {'null'} else {@{path=$s.PathName;account=$s.StartName;mode=$s.StartMode}|ConvertTo-Json -Compress}`, nil)
		if err != nil {
			t.Errorf("cannot check fixture ownership: %v", err)
			return
		}
		command, err := parseWindowsServiceSnapshot(output, first)
		if err != nil {
			t.Errorf("refusing cleanup of changed service: %v", err)
			return
		}
		if command != "" {
			_, err = nativePowerShell(windowsServiceHelpers+`$s=Find-Service;if ($s.PathName -cne `+powershellQuote(command)+` -or $s.StartName -ine 'NT SERVICE\MisakaSisters') {throw 'changed service'};Stop-Sisters;Check-Result (Invoke-CimMethod -InputObject $s -MethodName Delete);$deadline=[DateTime]::UtcNow.AddSeconds(10);while ($null -ne (Find-Service)) {if ([DateTime]::UtcNow -ge $deadline) {throw 'service deletion pending'};Start-Sleep -Milliseconds 200}`, nil)
			if err != nil {
				t.Errorf("cannot remove fixture service: %v", err)
				return
			}
		}
		if err := os.RemoveAll(first.Root); err != nil {
			t.Errorf("cannot remove fixture files: %v", err)
		}
	})
	// A junction controlled by another process must never redirect privileged
	// configuration writes into an unrelated directory.
	outside := t.TempDir()
	marker := filepath.Join(outside, "untouched")
	if err := os.WriteFile(marker, []byte("marker"), 0600); err != nil {
		t.Fatal(err)
	}
	junction := filepath.Join(first.Root, "junction")
	if _, err := nativePowerShell(`New-Item -ItemType Junction -Path `+powershellQuote(junction)+` -Target `+powershellQuote(outside)+`|Out-Null`, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := nativePowerShell(windowsDirectoryHelpers()+`Private-Directory `+powershellQuote(junction), nil); err == nil {
		t.Fatal("privileged directory preparation followed a junction")
	}
	if err := os.Remove(junction); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "marker" {
		t.Fatal("junction target changed")
	}
	danglingTarget := filepath.Join(outside, "removed-target")
	if err := os.Mkdir(danglingTarget, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := nativePowerShell(`New-Item -ItemType Junction -Path `+powershellQuote(junction)+` -Target `+powershellQuote(danglingTarget)+`|Out-Null`, nil); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(danglingTarget); err != nil {
		t.Fatal(err)
	}
	if _, err := nativePowerShell(windowsDirectoryHelpers()+`Private-Directory `+powershellQuote(junction), nil); err == nil {
		t.Fatal("privileged directory preparation followed a dangling junction")
	}
	if _, err := os.Stat(danglingTarget); !os.IsNotExist(err) {
		t.Fatal("dangling junction target was created")
	}
	if err := os.Remove(junction); err != nil {
		t.Fatal(err)
	}
	buildDir := t.TempDir()
	sisters := filepath.Join(buildDir, "sisters.exe")
	cmd := exec.Command("go", "build", "-o", sisters, "../../Sisters/cmd/sisters")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build service: %v: %s", err, output)
	}
	fakeSource := `package main
import("encoding/json";"os";"path/filepath";"golang.org/x/sys/windows")
func main(){
 var request map[string]any;if json.NewDecoder(os.Stdin).Decode(&request)!=nil {os.Exit(1)}
 ready:=true
 user,err:=windows.GetCurrentProcessToken().GetTokenUser();if err!=nil||user.User.Sid.String()!=` + strconv.Quote(windowsServiceSID()) + ` {ready=false}
 executable,err:=os.Executable();if err!=nil {os.Exit(1)}
 key:=filepath.Join(filepath.Dir(executable),"..","server.key")
 readable,err:=os.Open(key);if err!=nil {ready=false}else{readable.Close()}
 writable,err:=os.OpenFile(key,os.O_WRONLY,0);if err==nil {ready=false;writable.Close()}
 temp,err:=os.CreateTemp(os.TempDir(),"service-temp-check-");if err!=nil {ready=false}else{name:=temp.Name();temp.Close();os.Remove(name)}
 json.NewEncoder(os.Stdout).Encode(map[string]any{"type":"result","ok":true,"data":map[string]any{"ready":ready,"protocol":1,"version":` + strconv.Quote(Version) + `,"bili_version":` + strconv.Quote(BiliVersion) + `}})
}`
	sourceFile := filepath.Join(buildDir, "runtime.go")
	if err := os.WriteFile(sourceFile, []byte(fakeSource), 0600); err != nil {
		t.Fatal(err)
	}
	fakeRuntime := filepath.Join(buildDir, "misaka-runtime.exe")
	cmd = exec.Command("go", "build", "-o", fakeRuntime, sourceFile)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build fake runtime: %v: %s", err, output)
	}
	identity, err := InitPKI(filepath.Join(buildDir, "pki"))
	if err != nil {
		t.Fatal(err)
	}
	cert, key, ca, err := ServerIdentity(filepath.Join(buildDir, "pki"), "localhost")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := listener.Addr().String()
	listener.Close()
	cfg, _ := json.Marshal(map[string]any{"listen": endpoint, "cert": "server.pem", "key": "server.key", "ca": "ca.pem", "runtime": "runtime/misaka-runtime.exe"})
	secrets, _ := json.Marshal(map[string][]byte{"server.pem": cert, "server.key": key, "ca.pem": ca, "config.json": cfg})
	manifest, _ := json.Marshal(Manifest{Version: Version, BiliVersion: BiliVersion, Platform: "windows", Arch: "amd64"})
	sistersBytes, err := os.ReadFile(sisters)
	if err != nil {
		t.Fatal(err)
	}
	runtimeBytes, err := os.ReadFile(fakeRuntime)
	if err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gz)
	for filename, data := range map[string][]byte{"manifest.json": manifest, "sisters.exe": sistersBytes, "runtime/misaka-runtime.exe": runtimeBytes} {
		if err := tw.WriteHeader(&tar.Header{Name: filename, Size: int64(len(data)), Mode: 0755}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := checkBundleReader(bytes.NewReader(archive.Bytes()), "windows", "amd64"); err != nil {
		t.Fatal(err)
	}
	stage := func(paths windowsPaths) {
		t.Helper()
		stream, done := windowsBundleZIP(bytes.NewReader(archive.Bytes()))
		_, uploadErr := nativePowerShell(windowsUploadScript(paths.Release), stream)
		stream.Close()
		convertErr := <-done
		if uploadErr != nil || convertErr != nil {
			t.Fatalf("native upload: %v / %v", uploadErr, convertErr)
		}
		if _, err := nativePowerShell(windowsSecretScript(paths.Release), bytes.NewReader(secrets)); err != nil {
			t.Fatal(err)
		}
	}
	stage(first)
	health := func() error {
		return awaitHealthy(context.Background(), identity, cert, "localhost", 10*time.Second, func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", endpoint)
		})
	}
	if err := activateWindows(nativePowerShell, first, health); err != nil {
		t.Fatalf("native SCM service must pass mTLS, service SID, read-only key and writable temp checks: %v", err)
	}
	secondID := Version + "-second"
	output, err = nativePowerShell(windowsPrepareScript(name, secondID), nil)
	if err != nil {
		t.Fatal(err)
	}
	second, err := parseWindowsPaths(output, secondID)
	if err != nil {
		t.Fatal(err)
	}
	stage(second)
	if err := activateWindows(nativePowerShell, second, func() error { return errors.New("injected health failure") }); err == nil || !strings.Contains(err.Error(), "恢复旧版本") {
		t.Fatalf("redeploy rollback: %v", err)
	}
	if err := health(); err != nil {
		t.Fatalf("old service not healthy after rollback: %v", err)
	}
	output, err = nativePowerShell(windowsServiceHelpers+`$s=Find-Service;$s.PathName`, nil)
	if err != nil || output != windowsServiceCommand(first) {
		t.Fatalf("old SCM path not restored: %v", err)
	}
	if _, err := nativePowerShell(windowsServiceHelpers+`$s=Find-Service;if ($s.PathName -cne `+powershellQuote(windowsServiceCommand(first))+`) {throw 'changed service'};Stop-Sisters;Check-Result (Invoke-CimMethod -InputObject $s -MethodName Delete)`, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := nativePowerShell(windowsServiceHelpers+`$deadline=[DateTime]::UtcNow.AddSeconds(10);while ($null -ne (Find-Service)) {if ([DateTime]::UtcNow -ge $deadline) {throw 'service deletion pending'};Start-Sleep -Milliseconds 200}`, nil); err != nil {
		t.Fatal(err)
	}
	if err := activateWindows(nativePowerShell, second, func() error { return errors.New("first deployment health failure") }); err == nil || !strings.Contains(err.Error(), "移除新服务") {
		t.Fatalf("first deployment cleanup: %v", err)
	}
	if output, err := nativePowerShell(windowsServiceHelpers+`if ($null -ne (Find-Service)) {throw 'service remains'};'removed'`, nil); err != nil || output != "removed" {
		t.Fatalf("failed first service retained: %v", err)
	}
}
