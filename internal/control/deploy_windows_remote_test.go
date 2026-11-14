package control

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"unicode/utf16"
)

func windowsBundleFixture(t *testing.T, extras ...*tar.Header) []byte {
	t.Helper()
	var buffer bytes.Buffer
	gz := gzip.NewWriter(&buffer)
	tarWriter := tar.NewWriter(gz)
	manifest, _ := json.Marshal(Manifest{Version: Version, BiliVersion: BiliVersion, Platform: "windows", Arch: "amd64"})
	for name, data := range map[string][]byte{"manifest.json": manifest, "sisters.exe": []byte("sisters"), "runtime/misaka-runtime.exe": []byte("runtime")} {
		if err := tarWriter.WriteHeader(&tar.Header{Name: name, Size: int64(len(data)), Mode: 0755}); err != nil {
			t.Fatal(err)
		}
		if _, err := tarWriter.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	for _, extra := range extras {
		if err := tarWriter.WriteHeader(extra); err != nil {
			t.Fatal(err)
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func TestWindowsBundleRejectsFilesystemAliases(t *testing.T) {
	if err := checkBundleReader(bytes.NewReader(windowsBundleFixture(t)), "windows", "amd64"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"SISTERS.EXE", "server.KEY", "Config.JSON", "payload:stream", "C:/escape", "RUNTIME", "runtime/con.txt", "runtime/LPT1.dll", "runtime/COM¹.txt", "runtime/CON .txt", "runtime/COM1 .log", "runtime/NUL .x", "runtime/LPT1  .log", "runtime/file.", "runtime/file ", "runtime/file?", `runtime\escape`} {
		t.Run(name, func(t *testing.T) {
			data := windowsBundleFixture(t, &tar.Header{Name: name, Mode: 0600})
			if err := checkBundleReader(bytes.NewReader(data), "windows", "amd64"); err == nil {
				t.Fatal("accepted Windows alias or private path")
			}
		})
	}
	data := windowsBundleFixture(t, &tar.Header{Name: "link", Typeflag: tar.TypeSymlink, Linkname: "sisters.exe"})
	if err := checkBundleReader(bytes.NewReader(data), "windows", "amd64"); err == nil {
		t.Fatal("Windows symlink accepted")
	}
}

func TestWindowsArchiveConversionPreservesFiles(t *testing.T) {
	source := windowsBundleFixture(t)
	stream, done := windowsBundleZIP(bytes.NewReader(source))
	data, err := io.ReadAll(stream)
	stream.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(archive.File) != 3 {
		t.Fatalf("lost files: %d", len(archive.File))
	}
	for _, file := range archive.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		content, err := io.ReadAll(reader)
		reader.Close()
		if err != nil || len(content) == 0 {
			t.Fatalf("corrupt converted file: %s", file.Name)
		}
	}
	stream, done = windowsBundleZIP(bytes.NewReader(source))
	stream.Close()
	if err := <-done; err == nil {
		t.Fatal("interrupted conversion reported success")
	}
}

func TestWindowsPlatformMinimumAndArchitecture(t *testing.T) {
	for _, output := range []string{`{"major":10,"arch":"AMD64"}`, `{"major":11,"arch":"amd64"}`} {
		platform, arch, err := parseWindowsPlatform(output)
		if err != nil || platform != "windows" || arch != "amd64" {
			t.Fatalf("platform: %q %q %v", platform, arch, err)
		}
	}
	for _, output := range []string{`{"major":6,"arch":"AMD64"}`, `{"major":10,"arch":"ARM64"}`, `{"major":10,"arch":"x86"}`, `{}`, `not JSON`} {
		if _, _, err := parseWindowsPlatform(output); err == nil {
			t.Fatalf("unsupported system accepted: %s", output)
		}
	}
}

func TestWindowsPathsAndServiceSnapshotAreBounded(t *testing.T) {
	paths := windowsPaths{Root: `C:\ProgramData\用户 O'Brien\Sisters`, Release: `C:\ProgramData\用户 O'Brien\Sisters\releases\0.4.0-test`, Temp: `C:\ProgramData\用户 O'Brien\Sisters\tmp`}
	data, _ := json.Marshal(paths)
	if _, err := parseWindowsPaths(string(data), "0.4.0-test"); err != nil {
		t.Fatal(err)
	}
	if powershellQuote("用户 O'Brien") != "'用户 O''Brien'" {
		t.Fatal("PowerShell quote changed content")
	}
	snapshot := windowsServiceSnapshot{Path: windowsServiceCommand(paths), Account: `NT SERVICE\MisakaSisters`, Mode: "Auto"}
	data, _ = json.Marshal(snapshot)
	if command, err := parseWindowsServiceSnapshot(string(data), paths); err != nil || command != snapshot.Path {
		t.Fatalf("managed service rejected: %v", err)
	}
	for _, change := range []func(*windowsServiceSnapshot){
		func(s *windowsServiceSnapshot) { s.Account = "LocalSystem" },
		func(s *windowsServiceSnapshot) { s.Mode = "Manual" },
		func(s *windowsServiceSnapshot) { s.Path = strings.Replace(s.Path, "0.4.0-test", "..", 1) },
		func(s *windowsServiceSnapshot) { s.Path = strings.ReplaceAll(s.Path, "0.4.0-test", "..") },
		func(s *windowsServiceSnapshot) { s.Path = strings.ReplaceAll(s.Path, "0.4.0-test", ".") },
		func(s *windowsServiceSnapshot) { s.Path = strings.Replace(s.Path, `\config.json`, `\other.json`, 1) },
		func(s *windowsServiceSnapshot) { s.Path += " --unsafe" },
	} {
		changed := snapshot
		change(&changed)
		data, _ = json.Marshal(changed)
		if _, err := parseWindowsServiceSnapshot(string(data), paths); err == nil {
			t.Fatalf("foreign service accepted: %s", data)
		}
	}
}

func TestWindowsActivationRollbackAndHealth(t *testing.T) {
	paths := windowsPaths{Root: `C:\ProgramData\MisakaNetwork\Sisters`, Release: `C:\ProgramData\MisakaNetwork\Sisters\releases\0.4.0-new`, Temp: `C:\ProgramData\MisakaNetwork\Sisters\tmp`}
	for _, existing := range []bool{false, true} {
		for _, failedRollback := range []bool{false, true} {
			calls := []string{}
			runner := func(script string, _ io.Reader) (string, error) {
				calls = append(calls, script)
				if len(calls) == 1 {
					if !existing {
						return "null", nil
					}
					previous := paths
					previous.Release = strings.Replace(paths.Release, "new", "old", 1)
					data, _ := json.Marshal(windowsServiceSnapshot{Path: windowsServiceCommand(previous), Account: `NT SERVICE\MisakaSisters`, Mode: "Auto"})
					return string(data), nil
				}
				if len(calls) == 3 && failedRollback {
					return "", errors.New("rollback failed")
				}
				return "", nil
			}
			healthCalled := false
			err := activateWindows(runner, paths, func() error { healthCalled = true; return errors.New("health rejected") })
			if err == nil || !healthCalled || len(calls) != 3 {
				t.Fatalf("activation: calls=%d health=%v error=%v", len(calls), healthCalled, err)
			}
			if failedRollback != strings.Contains(err.Error(), "回滚未完成") {
				t.Fatalf("rollback result misreported: %v", err)
			}
			if !strings.Contains(calls[1], "NT SERVICE\\MisakaSisters") || strings.Contains(calls[1], "LocalSystem") || strings.Contains(calls[1], "StartPassword") {
				t.Fatal("service has unsafe account or credentials")
			}
			if !strings.Contains(calls[2], "service changed") || !strings.Contains(calls[2], "Stop-Sisters") {
				t.Fatal("rollback lacks ownership guard or stop")
			}
		}
	}
}

func TestPowerShellEncodingPreservesUnicodeAndFitsDefaultShell(t *testing.T) {
	scripts := []string{windowsPrepareScript("Sisters", Version+"-0123456789abcdef"), windowsUploadScript(`C:\ProgramData\用户 O'Brien\Sisters`), windowsSecretScript(`C:\ProgramData\用户 O'Brien\Sisters`), windowsPlatformScript}
	for _, script := range scripts {
		command := powershellCommand(script)
		if len(command) >= 8000 {
			t.Fatalf("PowerShell command too long: %d", len(command))
		}
		encoded := strings.TrimPrefix(command, "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ")
		bytes, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			t.Fatal(err)
		}
		words := make([]uint16, len(bytes)/2)
		for i := range words {
			words[i] = binary.LittleEndian.Uint16(bytes[i*2:])
		}
		bootstrap := string(utf16.Decode(words))
		payload := strings.SplitN(strings.TrimPrefix(bootstrap, "$b=[Convert]::FromBase64String('"), "'", 2)[0]
		compressed, err := base64.StdEncoding.DecodeString(payload)
		if err != nil {
			t.Fatal(err)
		}
		gz, err := gzip.NewReader(strings.NewReader(string(compressed)))
		if err != nil {
			t.Fatal(err)
		}
		actual, err := io.ReadAll(gz)
		gz.Close()
		if err != nil || string(actual) != script {
			t.Fatal("PowerShell script changed through encoding")
		}
	}
}
