package control

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/tencent"
	"golang.org/x/crypto/ssh"
)

const (
	handshakeTimeout = 30 * time.Second
	// Transfers are judged by progress rather than total time, so slow links
	// can finish while a dead one fails promptly.
	stallTimeout = 2 * time.Minute
	// Upload and self-checks change nothing that is active, so stopping them
	// at this budget always leaves the current version in place.
	stagingBudget = 15 * time.Minute
)

var errStagingExpired = errors.New("上传与自检超过 15 分钟仍未完成，已中止；当前版本未变更。请在网络更稳定时重试")

// stallConn fails the SSH transport once no bytes move for idle in either
// direction; until watch is called the handshake deadline applies unchanged.
type stallConn struct {
	net.Conn
	idle    time.Duration
	watched atomic.Bool
}

func (c *stallConn) watch() {
	c.watched.Store(true)
	c.Conn.SetDeadline(time.Now().Add(c.idle))
}
func (c *stallConn) Read(p []byte) (int, error) {
	n, e := c.Conn.Read(p)
	if n > 0 && c.watched.Load() {
		c.Conn.SetDeadline(time.Now().Add(c.idle))
	}
	return n, e
}
func (c *stallConn) Write(p []byte) (int, error) {
	n, e := c.Conn.Write(p)
	if n > 0 && c.watched.Load() {
		c.Conn.SetDeadline(time.Now().Add(c.idle))
	}
	return n, e
}

type Request struct {
	Action               string         `json:"action"`
	Cloud                *tencent.Input `json:"cloud,omitempty"`
	Directory            string         `json:"directory,omitempty"`
	Host                 string         `json:"host,omitempty"`
	Port                 int            `json:"port,omitempty"`
	Username             string         `json:"username,omitempty"`
	Password             string         `json:"password,omitempty"`
	PrivateKeyPath       string         `json:"private_key_path,omitempty"`
	PrivateKeyPassphrase string         `json:"private_key_passphrase,omitempty"`
	HostKeyFingerprint   string         `json:"host_key_fingerprint,omitempty"`
	BundlePath           string         `json:"bundle_path,omitempty"`
	BundlesDirectory     string         `json:"bundles_directory,omitempty"`
	RemoteDirectory      string         `json:"remote_directory,omitempty"`
	PKIDirectory         string         `json:"pki_directory,omitempty"`
	ServerName           string         `json:"server_name,omitempty"`
	GRPCPort             int            `json:"grpc_port,omitempty"`
	ProgressPath         string         `json:"progress_path,omitempty"`
}
type Response struct {
	OK          bool   `json:"ok"`
	Result      any    `json:"result,omitempty"`
	Error       string `json:"error,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
}
type Deployment struct {
	Identity
	Endpoint   string `json:"endpoint"`
	ServerName string `json:"server_name"`
	Platform   string `json:"platform"`
	Arch       string `json:"arch"`
	// Reachable reports whether this device reached Endpoint directly. The
	// service passed its checks either way; false usually means a firewall.
	Reachable bool `json:"reachable"`
}
type pinError struct{ fingerprint string }

func (e *pinError) Error() string { return "SSH 主机指纹尚未确认" }

func Handle(r Request) Response {
	switch r.Action {
	case "tencent_prepare", "tencent_create", "tencent_describe", "tencent_release", "tencent_recover":
		if r.Cloud == nil {
			return Response{Error: "缺少腾讯云操作参数"}
		}
		v, e := tencent.Execute(r.Action, *r.Cloud)
		if e != nil {
			return Response{Error: e.Error()}
		}
		return Response{OK: true, Result: v}
	case "generate_cloud_ssh_key":
		return cloudSSHKeyResponse(GenerateCloudSSHKey)
	case "protect_path":
		if e := ProtectPath(r.Directory); e != nil {
			return Response{Error: publicError(e)}
		}
		return Response{OK: true}
	case "init_pki":
		v, e := InitPKI(r.Directory)
		if e != nil {
			return Response{Error: publicError(e)}
		}
		return Response{OK: true, Result: v}
	case "deploy":
		v, e := Deploy(r)
		if e != nil {
			var pin *pinError
			if errors.As(e, &pin) {
				return Response{Error: "请核对并确认 SSH 主机指纹后重试", Fingerprint: pin.fingerprint}
			}
			return Response{Error: publicError(e)}
		}
		return Response{OK: true, Result: v}
	default:
		return Response{Error: "不支持的操作"}
	}
}

func publicError(err error) string {
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		return "本地文件访问失败，请检查文件和目录权限"
	}
	return err.Error()
}
func hostCallback(pin string) ssh.HostKeyCallback {
	return func(_ string, _ net.Addr, key ssh.PublicKey) error {
		actual := ssh.FingerprintSHA256(key)
		if pin == "" {
			return &pinError{actual}
		}
		if subtle.ConstantTimeCompare([]byte(pin), []byte(actual)) != 1 {
			return errors.New("SSH 主机指纹不匹配，已拒绝连接")
		}
		return nil
	}
}

var safeRelative = regexp.MustCompile(`^[a-zA-Z0-9._/-]+$`)

func validate(r *Request) error {
	if r.Port == 0 {
		r.Port = 22
	}
	if r.GRPCPort == 0 {
		r.GRPCPort = 20001
	}
	if r.RemoteDirectory == "" {
		r.RemoteDirectory = ".local/share/misaka"
	}
	if r.ServerName == "" {
		r.ServerName = r.Host
	}
	if r.Host == "" || len(r.Host) > 253 || strings.ContainsAny(r.Host, "/\\\r\n\t \x00") || r.Username == "" || strings.ContainsAny(r.Username, "\r\n\x00") {
		return errors.New("请输入有效的 SSH 主机和账号")
	}
	if r.Port < 1 || r.Port > 65535 || r.GRPCPort < 1 || r.GRPCPort > 65535 {
		return errors.New("端口必须在 1–65535 之间")
	}
	if !safeRelative.MatchString(r.RemoteDirectory) || path.IsAbs(r.RemoteDirectory) || path.Clean(r.RemoteDirectory) != r.RemoteDirectory || r.RemoteDirectory == "." || r.RemoteDirectory == ".." || strings.HasPrefix(r.RemoteDirectory, "../") {
		return errors.New("部署目录必须是远程用户目录内的安全相对路径")
	}
	if r.ServerName != r.Host {
		return errors.New("证书服务器名称必须与连接主机一致")
	}
	if r.PKIDirectory == "" {
		return errors.New("缺少证书目录")
	}
	return nil
}
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

// outputMarker separates a command's output from anything the remote user's
// startup files print before it.
const outputMarker = "__MISAKA_OUTPUT__"

// run executes a POSIX sh script whatever the remote login shell is. sshd hands
// the command to that shell (bash, fish, csh...), which only has to parse one
// single-quoted argument; quoting means the same in all of them because the
// scripts and paths here never contain a backslash pair.
func run(c *ssh.Client, command string, input io.Reader) (string, error) {
	s, e := c.NewSession()
	if e != nil {
		return "", e
	}
	defer s.Close()
	s.Stdin = input
	var out limitedBuffer
	s.Stdout = &out
	s.Stderr = io.Discard
	e = s.Run("/bin/sh -c " + shellQuote("printf '%s' "+outputMarker+"; "+command))
	text := out.String()
	if i := strings.Index(text, outputMarker); i >= 0 {
		text = text[i+len(outputMarker):]
	}
	return strings.TrimSpace(text), e
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if b.Len() < 65536 {
		remain := 65536 - b.Len()
		if len(p) > remain {
			p = p[:remain]
		}
		b.Buffer.Write(p)
	}
	return n, nil
}
func remotePlatform(c *ssh.Client) (string, string, error) {
	out, e := run(c, "uname -s; uname -m", nil)
	if e != nil {
		return "", "", errors.New("无法识别远程系统")
	}
	p := strings.Fields(out)
	if len(p) != 2 {
		return "", "", errors.New("远程系统信息无效")
	}
	var platform, arch string
	switch p[1] {
	case "x86_64", "amd64":
		arch = "amd64"
	case "aarch64", "arm64":
		arch = "arm64"
	default:
		return "", "", errors.New("只支持 x64 和 arm64")
	}
	switch p[0] {
	case "Darwin":
		platform = "macos"
		v, e := run(c, "sw_vers -productVersion", nil)
		n, _ := strconv.Atoi(strings.Split(v, ".")[0])
		if e != nil || n < 15 {
			return "", "", errors.New("远程 macOS 需要 15.0 或更新版本")
		}
	case "Linux":
		platform = "linux"
		v, e := run(c, "getconf GNU_LIBC_VERSION", nil)
		parts := strings.Fields(v)
		if e != nil || len(parts) != 2 {
			return "", "", errors.New("远程 Linux 必须使用 glibc 2.39 或更新版本")
		}
		nums := strings.Split(parts[1], ".")
		if len(nums) < 2 {
			return "", "", errors.New("无法验证 glibc 版本")
		}
		major, _ := strconv.Atoi(nums[0])
		minor, _ := strconv.Atoi(nums[1])
		if major < 2 || (major == 2 && minor < 39) {
			return "", "", errors.New("远程 Linux 需要 glibc 2.39 或更新版本")
		}
	default:
		return "", "", errors.New("只支持 Linux 和 macOS 的 Sisters 部署")
	}
	return platform, arch, nil
}

// Without linger, systemd stops user services shortly after the last session
// ends, so a Linux deployment would pass its checks and then die with SSH.
func ensureLinger(c *ssh.Client, username string) error {
	const query = `loginctl show-user "$(id -u)" --property=Linger --value`
	if out, e := run(c, query, nil); e == nil && out == "yes" {
		return nil
	}
	// polkit decides whether an account may enable its own linger; never escalate.
	run(c, "loginctl enable-linger >/dev/null 2>&1", nil)
	if out, e := run(c, query, nil); e == nil && out == "yes" {
		return nil
	}
	return fmt.Errorf("无法确认远程账号已开启 linger；未开启时 SSH 断开后 Sisters 会被系统停止。请让管理员执行 sudo loginctl enable-linger %s 后重新部署；当前版本未变更", username)
}
func archiveFiles(files map[string][]byte) ([]byte, error) {
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	for name, data := range files {
		if e := tw.WriteHeader(&tar.Header{Name: name, Mode: 0600, Size: int64(len(data))}); e != nil {
			return nil, e
		}
		if _, e := tw.Write(data); e != nil {
			return nil, e
		}
	}
	e := tw.Close()
	return b.Bytes(), e
}

func Deploy(r Request) (Deployment, error) {
	var result Deployment
	if e := validate(&r); e != nil {
		return result, e
	}
	progress, e := newProgressReporter(r.ProgressPath)
	if e != nil {
		return result, e
	}
	progress.report(2, "准备部署")
	auth := []ssh.AuthMethod{}
	if r.PrivateKeyPath != "" {
		b, e := os.ReadFile(r.PrivateKeyPath)
		if e != nil {
			return result, errors.New("无法读取 SSH 私钥")
		}
		var signer ssh.Signer
		if r.PrivateKeyPassphrase != "" {
			signer, e = ssh.ParsePrivateKeyWithPassphrase(b, []byte(r.PrivateKeyPassphrase))
		} else {
			signer, e = ssh.ParsePrivateKey(b)
		}
		if e != nil {
			return result, errors.New("SSH 私钥格式或口令无效")
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if r.Password != "" {
		auth = append(auth, ssh.Password(r.Password))
	}
	if len(auth) == 0 {
		return result, errors.New("请提供 SSH 密码或私钥")
	}
	progress.report(5, "连接 SSH")
	config := &ssh.ClientConfig{User: r.Username, Auth: auth, HostKeyCallback: hostCallback(r.HostKeyFingerprint), Timeout: 15 * time.Second}
	address := net.JoinHostPort(r.Host, strconv.Itoa(r.Port))
	raw, e := (&net.Dialer{Timeout: 15 * time.Second}).Dial("tcp", address)
	if e != nil {
		return result, errors.New("无法连接 SSH，请检查主机和端口")
	}
	conn := &stallConn{Conn: raw, idle: stallTimeout}
	defer conn.Close()
	raw.SetDeadline(time.Now().Add(handshakeTimeout))
	sc, ch, req, e := ssh.NewClientConn(conn, address, config)
	if e != nil {
		var pin *pinError
		if errors.As(e, &pin) {
			return result, pin
		}
		if r.HostKeyFingerprint != "" && strings.Contains(e.Error(), "指纹不匹配") {
			return result, errors.New("SSH 主机指纹不匹配，已拒绝连接")
		}
		return result, errors.New("SSH 认证失败，请检查凭据和主机指纹")
	}
	conn.watch()
	var expired atomic.Bool
	staging := time.AfterFunc(stagingBudget, func() {
		expired.Store(true)
		conn.Close()
	})
	defer staging.Stop()
	staged := func(message string) error {
		if expired.Load() {
			return errStagingExpired
		}
		return errors.New(message)
	}
	client := ssh.NewClient(sc, ch, req)
	defer client.Close()
	progress.report(10, "检查系统与安装包")
	platform, arch, e := remotePlatform(client)
	if e != nil {
		return result, e
	}
	bundle := r.BundlePath
	if bundle == "" {
		bundle = filepath.Join(r.BundlesDirectory, platform+"-"+arch+".tar.gz")
	}
	f, e := os.Open(bundle)
	if e != nil {
		return result, errors.New("缺少对应平台的离线部署包，请使用完整发行包")
	}
	defer f.Close()
	if e = checkBundleReader(f, platform, arch); e != nil {
		return result, e
	}
	if _, e = f.Seek(0, io.SeekStart); e != nil {
		return result, errors.New("无法重新读取部署包")
	}
	progress.report(15, "准备安全配置")
	identity, e := InitPKI(r.PKIDirectory)
	if e != nil {
		return result, e
	}
	cert, key, ca, e := ServerIdentity(r.PKIDirectory, r.ServerName)
	if e != nil {
		return result, e
	}
	if platform == "linux" {
		if e = ensureLinger(client, r.Username); e != nil {
			return result, e
		}
	}
	remoteHome, e := run(client, "printf '%s' \"$HOME\"", nil)
	// A backslash would be read differently by a fish login shell; see run.
	if e != nil || !path.IsAbs(remoteHome) || strings.ContainsFunc(remoteHome, unicode.IsControl) || strings.Contains(remoteHome, `\`) {
		return result, errors.New("无法确定远程用户目录，或目录含有不支持的字符")
	}
	root := path.Join(remoteHome, r.RemoteDirectory)
	nonce := make([]byte, 8)
	if _, e = rand.Read(nonce); e != nil {
		return result, e
	}
	release := path.Join(root, "releases", Version+"-"+hex.EncodeToString(nonce))
	q := shellQuote
	info, e := f.Stat()
	if e != nil || info.Size() <= 0 {
		return result, errors.New("无法读取部署包大小")
	}
	progress.report(20, "上传并解压安装包")
	upload := &uploadProgressReader{reader: f, total: info.Size(), report: progress.report}
	_, e = run(client, "umask 077; mkdir -p "+q(release)+" && tar -xzf - -C "+q(release), upload)
	if e != nil {
		return result, staged("上传或解压部署包失败；当前版本未变更")
	}
	progress.report(78, "写入安全配置")
	cfg, _ := json.Marshal(map[string]any{"listen": fmt.Sprintf("0.0.0.0:%d", r.GRPCPort), "cert": "server.pem", "key": "server.key", "ca": "ca.pem", "runtime": "runtime/misaka-runtime", "max_concurrency": 2, "queue_capacity": 64})
	secretArchive, e := archiveFiles(map[string][]byte{"server.pem": cert, "server.key": key, "ca.pem": ca, "config.json": cfg})
	if e != nil {
		return result, e
	}
	_, e = run(client, "umask 077; tar -xf - -C "+q(release)+" && chmod 700 "+q(path.Join(release, "sisters"))+" "+q(path.Join(release, "runtime/misaka-runtime")), bytes.NewReader(secretArchive))
	if e != nil {
		return result, staged("写入远程私有配置失败；当前版本未变更")
	}
	// Probe both executables before changing the active release.
	progress.report(82, "检查 Sisters")
	out, e := run(client, q(path.Join(release, "sisters"))+" --version", nil)
	if e != nil || !strings.Contains(out, Version) {
		return result, staged("远程 Sisters 自检失败；当前版本未变更")
	}
	progress.report(86, "检查抢票运行时")
	out, e = run(client, "printf '%s\\n' '{\"op\":\"ping\",\"params\":{}}' | "+q(path.Join(release, "runtime/misaka-runtime")), nil)
	if e != nil || !validRuntimeProbe(out) {
		return result, staged("远程 biliTickerBuy 运行时自检失败；当前版本未变更")
	}
	// Activation must be able to finish or roll back, so the staging budget no
	// longer applies; each step is still bounded by stall detection.
	if !staging.Stop() {
		return result, errStagingExpired
	}
	progress.report(90, "启动 Sisters")
	if e = activate(client, platform, root, release, remoteHome, func() error {
		progress.report(94, "验证安全连接")
		return verifyDeployment(context.Background(), client, identity, cert, r.ServerName, r.GRPCPort)
	}); e != nil {
		return result, e
	}
	progress.report(97, "检查直连状态")
	endpoint := net.JoinHostPort(r.Host, strconv.Itoa(r.GRPCPort))
	result = Deployment{Identity: identity, Endpoint: endpoint, ServerName: r.ServerName, Platform: platform, Arch: arch, Reachable: reachable(context.Background(), identity, cert, r.ServerName, endpoint)}
	progress.report(100, "部署完成")
	return result, nil
}
func serviceDefinition(platform, root, home string) (servicePath string, body []byte, restart, stop string) {
	q := shellQuote
	current := path.Join(root, "current")
	if platform == "linux" {
		servicePath = path.Join(home, ".config/systemd/user/misaka-sisters.service")
		systemdQuote := func(value string) string {
			return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, `%`, `%%`, `$`, `$$`).Replace(value) + `"`
		}
		body = []byte("[Unit]\nDescription=MisakaNetwork Sisters\nAfter=network-online.target\n[Service]\nType=simple\nExecStart=" + systemdQuote(current+"/sisters") + " serve --config " + systemdQuote(current+"/config.json") + "\nRestart=on-failure\nRestartSec=3\nUMask=0077\nKillMode=control-group\n[Install]\nWantedBy=default.target\n")
		restart = "systemctl --user daemon-reload && systemctl --user enable misaka-sisters.service >/dev/null && systemctl --user restart misaka-sisters.service && systemctl --user is-active --quiet misaka-sisters.service"
		stop = "systemctl --user stop misaka-sisters.service >/dev/null 2>&1 || true"
	} else {
		servicePath = path.Join(home, "Library/LaunchAgents/io.misakanetwork.sisters.plist")
		escape := func(s string) string {
			r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;")
			return r.Replace(s)
		}
		// Without a session type, launchd also loads this agent into gui/<uid> at
		// every desktop login and starts a second instance that redeploys cannot
		// manage. Background is the session type of the user/<uid> domain.
		body = []byte(`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>io.misakanetwork.sisters</string><key>ProgramArguments</key><array><string>` + escape(current+"/sisters") + `</string><string>serve</string><string>--config</string><string>` + escape(current+"/config.json") + `</string></array><key>LimitLoadToSessionType</key><string>Background</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>Umask</key><integer>63</integer></dict></plist>`)
		// Stopping also clears a GUI-domain copy left by earlier descriptors.
		stop = `uid=$(id -u); for domain in "user/$uid" "gui/$uid"; do launchctl bootout "$domain/io.misakanetwork.sisters" >/dev/null 2>&1 || true; done`
		restart = stop + "; launchctl bootstrap \"user/$uid\" " + q(servicePath) + " && launchctl kickstart \"user/$uid/io.misakanetwork.sisters\""
	}
	return
}

func activate(c *ssh.Client, platform, root, release, home string, health func() error) error {
	q := shellQuote
	current := path.Join(root, "current")
	servicePath, body, restart, stop := serviceDefinition(platform, root, home)
	backup := servicePath + ".backup-" + path.Base(release)
	previous, e := run(c, "if [ -e "+q(current)+" ] && [ ! -L "+q(current)+" ]; then exit 1; fi; readlink "+q(current)+" || true", nil)
	if e != nil {
		return errors.New("现有部署入口不是可更新的符号链接")
	}
	// Save the previous service descriptor before changing anything. Symlink
	// descriptors are rejected so writing a private unit cannot follow one.
	_, e = run(c, "umask 077; mkdir -p "+q(path.Dir(servicePath))+" && test ! -L "+q(servicePath)+" && if [ -e "+q(servicePath)+" ]; then cp "+q(servicePath)+" "+q(backup)+"; fi", nil)
	if e != nil {
		return errors.New("无法备份现有用户服务描述文件")
	}
	// Every step runs even after a failure, and the exit status reports whether
	// all of them succeeded, so a failed recovery is never presented as done.
	rollback := func() error {
		steps := []string{
			"(" + stop + ")",
			"if [ -f " + q(backup) + " ]; then mv -f " + q(backup) + " " + q(servicePath) + "; else rm -f " + q(servicePath) + "; fi",
		}
		if previous != "" {
			steps = append(steps, "ln -sfn "+q(previous)+" "+q(current), "("+restart+")")
		} else {
			steps = append(steps, "rm -f "+q(current))
			if platform == "linux" {
				steps = append(steps, "systemctl --user disable misaka-sisters.service >/dev/null 2>&1 || true", "systemctl --user daemon-reload")
			}
		}
		_, e := run(c, "failed=0; "+strings.Join(steps, " || failed=1; ")+" || failed=1; exit $failed", nil)
		return e
	}
	abort := func(reason, advice string) error {
		if rollback() != nil {
			return errors.New(reason + "，且回滚未完成：远程可能停在新版本或服务已停止，请检查远程主机后重新部署")
		}
		if previous == "" {
			return errors.New(reason + "；已停止并移除新服务。" + advice)
		}
		return errors.New(reason + "；已停止新服务并恢复旧版本。" + advice)
	}
	_, e = run(c, "umask 077; cat > "+q(servicePath), bytes.NewReader(body))
	if e != nil {
		return abort("无法安装用户服务描述文件", "请检查远程用户目录的写入权限")
	}
	command := "ln -sfn " + q(release) + " " + q(current) + " && (" + restart + ")"
	if _, e = run(c, command, nil); e == nil {
		e = health()
	}
	if e != nil {
		return abort("用户服务未通过 mTLS 健康检查", "请检查用户服务会话与运行环境")
	}
	run(c, "rm -f "+q(backup), nil)
	return nil
}
