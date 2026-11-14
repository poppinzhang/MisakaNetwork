package control

// This file deliberately has no GOOS build constraint: every LastOrder host,
// including Android, can deploy to a Windows OpenSSH server.
import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"

	"golang.org/x/crypto/ssh"
)

const windowsServiceName = "MisakaSisters"

type powershellRunner func(string, io.Reader) (string, error)

func powershellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }

func utf16LE(value string) []byte {
	words := utf16.Encode([]rune(value))
	data := make([]byte, len(words)*2)
	for i, word := range words {
		binary.LittleEndian.PutUint16(data[i*2:], word)
	}
	return data
}

func powershellCommand(script string) string {
	// Compress scripts before encoding so the default OpenSSH cmd.exe shell's
	// command-line limit is not exceeded. The bootstrap contains only ASCII and
	// fixed syntax; paths and non-ASCII text live inside the encoded script.
	var compressed bytes.Buffer
	gz := gzip.NewWriter(&compressed)
	_, _ = gz.Write([]byte(script))
	_ = gz.Close()
	bootstrap := "$b=[Convert]::FromBase64String('" + base64.StdEncoding.EncodeToString(compressed.Bytes()) + "');$m=New-Object IO.MemoryStream(,$b);$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);$r=New-Object IO.StreamReader($g,[Text.Encoding]::UTF8);& ([ScriptBlock]::Create($r.ReadToEnd()))"
	return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + base64.StdEncoding.EncodeToString(utf16LE(bootstrap))
}

func runPowerShell(c *ssh.Client, script string, input io.Reader) (string, error) {
	session, err := c.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()
	session.Stdin = input
	var out limitedBuffer
	session.Stdout = &out
	session.Stderr = io.Discard
	script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);[Console]::Write('" + outputMarker + "');try {\n" + script + "\n} catch { exit 1 }; exit 0"
	command := powershellCommand(script)
	if len(command) >= 8191 {
		return "", errors.New("Windows 部署命令超过系统长度限制")
	}
	err = session.Run(command)
	output := out.String()
	i := strings.Index(output, outputMarker)
	if i < 0 {
		return "", errors.New("Windows PowerShell 未返回有效响应")
	}
	return strings.TrimSpace(output[i+len(outputMarker):]), err
}

const windowsPlatformScript = `$v=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion';$major=$v.CurrentMajorVersionNumber;if ($null -eq $major) {$major=([Version]$v.CurrentVersion).Major};$arch=$env:PROCESSOR_ARCHITEW6432;if (!$arch) {$arch=$env:PROCESSOR_ARCHITECTURE};@{major=[int]$major;arch=$arch}|ConvertTo-Json -Compress`

func remoteWindowsPlatform(c *ssh.Client) (string, string, error) {
	output, err := runPowerShell(c, windowsPlatformScript, nil)
	if err != nil {
		return "", "", errors.New("无法识别远程系统；支持 Linux、macOS 与 Windows 10 及以上 x64（需启用 OpenSSH 和 PowerShell）")
	}
	return parseWindowsPlatform(output)
}

func parseWindowsPlatform(output string) (string, string, error) {
	var result struct {
		Major int    `json:"major"`
		Arch  string `json:"arch"`
	}
	if json.Unmarshal([]byte(output), &result) != nil || result.Major < 10 {
		return "", "", errors.New("远程 Windows 需要 Windows 10 或更新版本")
	}
	if !strings.EqualFold(result.Arch, "AMD64") {
		return "", "", errors.New("Windows Sisters 目前仅支持原生 x64 系统")
	}
	return "windows", "amd64", nil
}

// Windows assigns service SIDs from SHA-1 of the UTF-16LE uppercase service
// name. Compute it without requiring the not-yet-created service to resolve.
func windowsServiceSID() string {
	sum := sha1.Sum(utf16LE(strings.ToUpper(windowsServiceName)))
	sid := "S-1-5-80"
	for i := 0; i < len(sum); i += 4 {
		sid += "-" + strconv.FormatUint(uint64(binary.LittleEndian.Uint32(sum[i:i+4])), 10)
	}
	return sid
}

// Never follow a junction/reparse point while acting as the SSH administrator.
// The controlled tree grants write access only to administrators and SYSTEM;
// the service can read releases and write only its dedicated temporary folder.
func windowsDirectoryHelpers() string {
	return `$serviceSid=New-Object Security.Principal.SecurityIdentifier(` + powershellQuote(windowsServiceSID()) + `)
function Assert-NoReparse([string]$p) {
  $cursor=[IO.Path]::GetFullPath($p)
  while ($cursor) {
    try {
      if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'reparse'}
    } catch [IO.FileNotFoundException] {} catch [IO.DirectoryNotFoundException] {}
    $parent=[IO.Path]::GetDirectoryName($cursor)
    if ($parent -eq $cursor) {break};$cursor=$parent
  }
}
function Private-Directory([string]$p,[bool]$write=$false) {
  Assert-NoReparse $p
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true,$false)
  foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $id=New-Object Security.Principal.SecurityIdentifier($sid)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
  }
  $rights='ReadAndExecute';if ($write) {$rights='Modify'}
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($serviceSid,$rights,'ContainerInherit,ObjectInherit','None','Allow')))
  if ([IO.Directory]::Exists($p)) {
    $item=New-Object IO.DirectoryInfo($p)
    $owner=$item.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value
    $me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($owner -notin @('S-1-5-18','S-1-5-32-544',$me)) {throw 'foreign owner'}
    $item.SetAccessControl($acl)
  } else {
    [IO.Directory]::CreateDirectory($p,$acl)|Out-Null
  }
}
`
}

func windowsPrepareScript(relative, releaseID string) string {
	if relative == ".local/share/misaka" {
		relative = "Sisters"
	}
	return windowsDirectoryHelpers() + `
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'administrator required'}
$base=[IO.Path]::Combine([Environment]::GetFolderPath('CommonApplicationData'),'MisakaNetwork')
Private-Directory $base
$root=$base
foreach ($part in (` + powershellQuote(relative) + ` -split '/')) {$root=[IO.Path]::Combine($root,$part);Private-Directory $root}
$releases=[IO.Path]::Combine($root,'releases');Private-Directory $releases
$release=[IO.Path]::Combine($releases,` + powershellQuote(releaseID) + `)
if ([IO.Directory]::Exists($release) -or [IO.File]::Exists($release)) {throw 'release exists'}
Private-Directory $release
$temp=[IO.Path]::Combine($root,'tmp');Private-Directory $temp $true
@{root=$root;release=$release;temp=$temp}|ConvertTo-Json -Compress`
}

type windowsPaths struct {
	Root    string `json:"root"`
	Release string `json:"release"`
	Temp    string `json:"temp"`
}

var windowsAbsolutePath = regexp.MustCompile(`^[A-Za-z]:\\`)

func parseWindowsPaths(output, releaseID string) (windowsPaths, error) {
	var paths windowsPaths
	if json.Unmarshal([]byte(output), &paths) != nil || !windowsAbsolutePath.MatchString(paths.Root) || strings.ContainsFunc(paths.Root, unicode.IsControl) || strings.ContainsAny(paths.Root, `"<>|?*`) || strings.Contains(paths.Root[3:], ":") || strings.Contains(paths.Root, "/") || strings.HasSuffix(paths.Root, `\`) {
		return paths, errors.New("Windows 部署目录响应无效")
	}
	if paths.Release != paths.Root+`\releases\`+releaseID || paths.Temp != paths.Root+`\tmp` {
		return paths, errors.New("Windows 部署目录不在受控路径中")
	}
	for _, component := range strings.Split(paths.Root[3:], `\`) {
		if !safeWindowsArchivePath(component) || component == "." || component == ".." {
			return paths, errors.New("Windows 部署目录包含不安全路径")
		}
	}
	return paths, nil
}

// Convert the already-validated tar.gz to an ordinary ZIP stream. Windows 10
// includes .NET ZipFile even on releases predating the bundled tar.exe.
func windowsBundleZIP(source io.Reader) (io.ReadCloser, <-chan error) {
	reader, writer := io.Pipe()
	done := make(chan error, 1)
	go func() {
		err := writeWindowsBundleZIP(writer, source)
		_ = writer.CloseWithError(err)
		done <- err
		close(done)
	}()
	return reader, done
}

func writeWindowsBundleZIP(destination io.Writer, source io.Reader) error {
	gz, err := gzip.NewReader(source)
	if err != nil {
		return err
	}
	defer gz.Close()
	tarReader := tar.NewReader(gz)
	zipWriter := zip.NewWriter(destination)
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			return zipWriter.Close()
		}
		if err != nil {
			return err
		}
		if header.Typeflag == tar.TypeDir {
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return errors.New("Windows 部署包不支持链接")
		}
		entry, err := zipWriter.CreateHeader(&zip.FileHeader{Name: strings.TrimPrefix(header.Name, "./"), Method: zip.Store})
		if err != nil {
			return err
		}
		if _, err = io.Copy(entry, tarReader); err != nil {
			return err
		}
	}
}

func windowsUploadScript(release string) string {
	return windowsDirectoryHelpers() + `
$release=` + powershellQuote(release) + `;Assert-NoReparse $release
$archive=[IO.Path]::Combine($release,'payload.zip')
$file=New-Object IO.FileStream($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {[Console]::OpenStandardInput().CopyTo($file)} finally {$file.Dispose()}
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {[IO.Compression.ZipFile]::ExtractToDirectory($archive,$release)} finally {[IO.File]::Delete($archive)}
`
}

func windowsSecretScript(release string) string {
	return windowsDirectoryHelpers() + `
$release=` + powershellQuote(release) + `;Assert-NoReparse $release
$reader=New-Object IO.StreamReader([Console]::OpenStandardInput(),[Text.Encoding]::UTF8)
$files=$reader.ReadToEnd()|ConvertFrom-Json
foreach ($name in @('server.pem','server.key','ca.pem','config.json')) {
  $target=[IO.Path]::Combine($release,$name);Assert-NoReparse $target
  $data=[Convert]::FromBase64String($files.$name)
  $file=New-Object IO.FileStream($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {$file.Write($data,0,$data.Length)} finally {$file.Dispose();[Array]::Clear($data,0,$data.Length)}
}`
}

func deployWindows(c *ssh.Client, request Request, identity Identity, cert, key, ca []byte, bundle *os.File, progress *progressReporter, stopStaging func() bool, staged func(string) error) (Deployment, error) {
	var result Deployment
	if request.EnableLingerWithSudo {
		return result, errors.New("云 Linux 部署选项不能用于 Windows")
	}
	if !safeWindowsArchivePath(request.RemoteDirectory) {
		return result, errors.New("Windows 部署目录包含不支持的名称")
	}
	nonce := make([]byte, 8)
	if _, err := rand.Read(nonce); err != nil {
		return result, err
	}
	releaseID := Version + "-" + hex.EncodeToString(nonce)
	run := func(script string, input io.Reader) (string, error) { return runPowerShell(c, script, input) }
	output, err := run(windowsPrepareScript(request.RemoteDirectory, releaseID), nil)
	if err != nil {
		return result, staged("无法准备 Windows 私有部署目录；请使用具有管理员权限的 OpenSSH 会话和支持 ACL 的本地磁盘，检查目录归属与重解析点；当前版本未变更")
	}
	paths, err := parseWindowsPaths(output, releaseID)
	if err != nil {
		return result, err
	}
	info, err := bundle.Stat()
	if err != nil || info.Size() <= 0 {
		return result, errors.New("无法读取部署包大小")
	}
	progress.report(20, "上传并解压安装包")
	upload := &uploadProgressReader{reader: bundle, total: info.Size(), report: progress.report}
	stream, converted := windowsBundleZIP(upload)
	_, err = run(windowsUploadScript(paths.Release), stream)
	_ = stream.Close()
	convertErr := <-converted
	if err != nil || convertErr != nil {
		return result, staged("上传或解压 Windows 部署包失败；当前版本未变更")
	}
	progress.report(78, "写入安全配置")
	cfg, _ := json.Marshal(map[string]any{"listen": fmt.Sprintf("0.0.0.0:%d", request.GRPCPort), "cert": "server.pem", "key": "server.key", "ca": "ca.pem", "runtime": "runtime/misaka-runtime.exe", "max_concurrency": 2, "queue_capacity": 64})
	secrets, _ := json.Marshal(map[string][]byte{"server.pem": cert, "server.key": key, "ca.pem": ca, "config.json": cfg})
	_, err = run(windowsSecretScript(paths.Release), bytes.NewReader(secrets))
	clear(secrets)
	if err != nil {
		return result, staged("写入 Windows 私有配置失败；当前版本未变更")
	}
	progress.report(82, "检查 Sisters")
	output, err = run("& "+powershellQuote(paths.Release+`\sisters.exe`)+" --version; if ($LASTEXITCODE -ne 0) {throw 'probe'}", nil)
	if err != nil || output != "Sisters "+Version {
		return result, staged("远程 Windows Sisters 自检失败；当前版本未变更")
	}
	progress.report(86, "检查抢票运行时")
	output, err = run(`'{"op":"ping","params":{}}' | & `+powershellQuote(paths.Release+`\runtime\misaka-runtime.exe`)+`;if ($LASTEXITCODE -ne 0) {throw 'runtime probe'}`, nil)
	if err != nil || !validRuntimeProbe(output) {
		return result, staged("远程 Windows biliTickerBuy 运行时自检失败；当前版本未变更")
	}
	if !stopStaging() {
		return result, errStagingExpired
	}
	progress.report(90, "启动 Sisters")
	err = activateWindows(run, paths, func() error {
		progress.report(94, "验证安全连接")
		return verifyDeployment(context.Background(), c, identity, cert, request.ServerName, request.GRPCPort)
	})
	if err != nil {
		return result, err
	}
	progress.report(97, "检查直连状态")
	endpoint := net.JoinHostPort(request.Host, strconv.Itoa(request.GRPCPort))
	result = Deployment{Identity: identity, Endpoint: endpoint, ServerName: request.ServerName, Platform: "windows", Arch: "amd64", Reachable: reachable(context.Background(), identity, cert, request.ServerName, endpoint)}
	progress.report(100, "部署完成")
	return result, nil
}

func windowsServiceCommand(paths windowsPaths) string {
	return `"` + paths.Release + `\sisters.exe" service --config "` + paths.Release + `\config.json" --temp-dir "` + paths.Temp + `"`
}

const windowsServiceHelpers = `
function Find-Service {Get-CimInstance -ClassName Win32_Service -Filter "Name='MisakaSisters'"}
function Check-Result($r) {if ($r.ReturnValue -ne 0) {throw 'SCM rejected operation'}}
function Stop-Sisters {
  $service=Get-Service -Name 'MisakaSisters' -ErrorAction SilentlyContinue
  if ($null -ne $service) {
    try {
      if ($service.Status -ne 'Stopped') {
        $service.Stop()
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
      }
    } finally {$service.Dispose()}
  }
}
function Start-Sisters {
  $service=Get-Service -Name 'MisakaSisters'
  try {
    $service.Start()
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
  } finally {$service.Dispose()}
}
`

type windowsServiceSnapshot struct {
	Path    string `json:"path"`
	Account string `json:"account"`
	Mode    string `json:"mode"`
}

func parseWindowsServiceSnapshot(output string, paths windowsPaths) (string, error) {
	if output == "null" {
		return "", nil
	}
	var snapshot windowsServiceSnapshot
	if json.Unmarshal([]byte(output), &snapshot) != nil || !strings.EqualFold(snapshot.Account, `NT SERVICE\`+windowsServiceName) || snapshot.Mode != "Auto" {
		return "", errors.New("Windows 已有同名服务不属于可更新的 Sisters 虚拟账户服务；当前版本未变更")
	}
	pattern := `^"` + regexp.QuoteMeta(paths.Root+`\releases\`) + `([0-9A-Za-z.-]+)\\sisters\.exe" service --config "` + regexp.QuoteMeta(paths.Root+`\releases\`) + `([0-9A-Za-z.-]+)\\config\.json" --temp-dir "` + regexp.QuoteMeta(paths.Temp) + `"$`
	match := regexp.MustCompile(pattern).FindStringSubmatch(snapshot.Path)
	if match == nil || match[1] != match[2] || !safeWindowsArchivePath(match[1]) {
		return "", errors.New("Windows 已有同名服务不在当前私有部署目录；当前版本未变更")
	}
	return snapshot.Path, nil
}

func activateWindows(run powershellRunner, paths windowsPaths, health func() error) error {
	output, err := run(windowsServiceHelpers+`$s=Find-Service;if ($null -eq $s) {'null'} else {@{path=$s.PathName;account=$s.StartName;mode=$s.StartMode}|ConvertTo-Json -Compress}`, nil)
	if err != nil {
		return errors.New("无法读取 Windows 服务配置；当前版本未变更")
	}
	previous, err := parseWindowsServiceSnapshot(output, paths)
	if err != nil {
		return err
	}
	command := windowsServiceCommand(paths)
	// Recheck the snapshot in the same script that changes SCM. This refuses a
	// foreign/concurrently replaced service instead of silently taking it over.
	guard := "$expected=" + powershellQuote(previous) + `;$s=Find-Service;if ($expected -eq '') {if ($null -ne $s) {throw 'service changed'}} elseif ($null -eq $s -or $s.PathName -cne $expected -or $s.StartName -ine 'NT SERVICE\MisakaSisters') {throw 'service changed'};`
	change := windowsServiceHelpers + guard + `Stop-Sisters
$command=` + powershellQuote(command) + `
if ($null -eq $s) {
  Check-Result (Invoke-CimMethod -ClassName Win32_Service -MethodName Create -Arguments @{Name='MisakaSisters';DisplayName='MisakaNetwork Sisters';PathName=$command;ServiceType=[uint32]16;ErrorControl=[uint32]1;StartMode='Automatic';DesktopInteract=$false;StartName='NT SERVICE\MisakaSisters'})
} else {Check-Result (Invoke-CimMethod -InputObject $s -MethodName Change -Arguments @{PathName=$command})}
& "$env:SystemRoot\System32\sc.exe" failure MisakaSisters reset= 86400 actions= restart/3000/restart/10000/restart/30000 | Out-Null
if ($LASTEXITCODE -ne 0) {throw 'cannot configure service recovery'}
Start-Sisters`
	_, err = run(change, nil)
	if err == nil {
		err = health()
	}
	if err == nil {
		return nil
	}
	rollback := windowsServiceHelpers + "$new=" + powershellQuote(command) + ";$old=" + powershellQuote(previous) + `
$s=Find-Service
if ($null -ne $s) {
  if ($s.StartName -ine 'NT SERVICE\MisakaSisters' -or ($s.PathName -cne $new -and $s.PathName -cne $old)) {throw 'service changed'}
  Stop-Sisters
  if ($old -eq '') {
    Check-Result (Invoke-CimMethod -InputObject $s -MethodName Delete)
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while ($null -ne (Find-Service)) {if ([DateTime]::UtcNow -ge $deadline) {throw 'service deletion pending'};Start-Sleep -Milliseconds 200}
  }
  else {Check-Result (Invoke-CimMethod -InputObject $s -MethodName Change -Arguments @{PathName=$old});Start-Sisters}
} elseif ($old -ne '') {throw 'old service missing'}
`
	if _, rollbackErr := run(rollback, nil); rollbackErr != nil {
		return errors.New("Windows 服务启动或 mTLS 健康检查失败，且回滚未完成：请检查远程服务后重新部署")
	}
	if previous == "" {
		return errors.New("Windows 服务启动或 mTLS 健康检查失败；已停止并移除新服务")
	}
	return errors.New("Windows 服务启动或 mTLS 健康检查失败；已停止新服务并恢复旧版本")
}
