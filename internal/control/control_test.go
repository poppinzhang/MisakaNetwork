package control

import (
	"archive/tar"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestPKIIdentityAndReuse(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pki")
	id, e := InitPKI(dir)
	if e != nil {
		t.Fatal(e)
	}
	before, _ := os.ReadFile(id.ClientKey)
	again, e := InitPKI(dir)
	if e != nil || again != id {
		t.Fatalf("reuse: %v", e)
	}
	after, _ := os.ReadFile(id.ClientKey)
	if string(before) != string(after) {
		t.Fatal("identity rotated unexpectedly")
	}
	cert, key, ca, e := ServerIdentity(dir, "127.0.0.1")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = tls.X509KeyPair(cert, key); e != nil {
		t.Fatal(e)
	}
	block, _ := pem.Decode(cert)
	parsed, e := x509.ParseCertificate(block.Bytes)
	if e != nil {
		t.Fatal(e)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(ca)
	if _, e = parsed.Verify(x509.VerifyOptions{DNSName: "127.0.0.1", Roots: roots}); e != nil {
		t.Fatal(e)
	}
	if _, e = parsed.Verify(x509.VerifyOptions{DNSName: "invalid.example", Roots: roots}); e == nil {
		t.Fatal("accepted wrong host")
	}
	if _, e = parsed.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); e == nil {
		t.Fatal("server accepted as client")
	}
	for _, p := range []string{id.CACert, id.ClientCert, id.ClientKey, filepath.Join(dir, "ca.key")} {
		s, e := os.Stat(p)
		if e != nil || (runtime.GOOS != "windows" && s.Mode().Perm() != 0600) {
			t.Fatalf("permissions: %v", e)
		}
	}
}
func TestPKIRefusesPartialAndForeignIdentity(t *testing.T) {
	dir := t.TempDir()
	if e := os.WriteFile(filepath.Join(dir, "ca.pem"), []byte("partial"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := InitPKI(dir); e == nil {
		t.Fatal("partial CA overwritten")
	}
	one, _ := InitPKI(filepath.Join(t.TempDir(), "one"))
	two, _ := InitPKI(filepath.Join(t.TempDir(), "two"))
	for _, pair := range [][2]string{{two.ClientCert, one.ClientCert}, {two.ClientKey, one.ClientKey}} {
		b, _ := os.ReadFile(pair[0])
		os.WriteFile(pair[1], b, 0600)
	}
	if _, e := InitPKI(filepath.Dir(one.CACert)); e == nil {
		t.Fatal("foreign client identity accepted")
	}
}
func TestHostPinNeverTrustsUnknownOrChangedKey(t *testing.T) {
	pub, _, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	key, e := ssh.NewPublicKey(pub)
	if e != nil {
		t.Fatal(e)
	}
	var pin *pinError
	if e = hostCallback("")("", nil, key); !errors.As(e, &pin) || pin.fingerprint != ssh.FingerprintSHA256(key) {
		t.Fatal("unknown host must require verification")
	}
	if e = hostCallback(pin.fingerprint)("", nil, key); e != nil {
		t.Fatal(e)
	}
	if e = hostCallback("SHA256:changed")("", nil, key); e == nil {
		t.Fatal("changed host accepted")
	}
}
func bundle(t *testing.T, extra *tar.Header, version string) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "bundle.tar.gz")
	f, e := os.Create(file)
	if e != nil {
		t.Fatal(e)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	m, _ := json.Marshal(Manifest{Version: version, BiliVersion: BiliVersion, Platform: "linux", Arch: "arm64"})
	for name, data := range map[string][]byte{"manifest.json": m, "sisters": []byte("binary"), "runtime/misaka-runtime": []byte("runtime")} {
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(data))})
		tw.Write(data)
	}
	if extra != nil {
		tw.WriteHeader(extra)
	}
	tw.Close()
	gz.Close()
	f.Close()
	return file
}
func TestBundleValidation(t *testing.T) {
	if e := CheckBundle(bundle(t, nil, Version), "linux", "arm64"); e != nil {
		t.Fatal(e)
	}
	for _, h := range []*tar.Header{{Name: "../escape", Mode: 0600}, {Name: "/absolute", Mode: 0600}, {Name: "runtime/link", Typeflag: tar.TypeSymlink, Linkname: "../../escape"}, {Name: "device", Typeflag: tar.TypeChar}, {Name: "sisters", Mode: 0600}} {
		if e := CheckBundle(bundle(t, h, Version), "linux", "arm64"); e == nil {
			t.Fatalf("accepted unsafe tar header: %v", h)
		}
	}
	if e := CheckBundle(bundle(t, nil, "0.0.0"), "linux", "arm64"); e == nil {
		t.Fatal("wrong version accepted")
	}
	if e := CheckBundle(bundle(t, nil, Version), "macos", "arm64"); e == nil {
		t.Fatal("wrong platform accepted")
	}
}
func TestValidateDeploymentInputs(t *testing.T) {
	base := Request{Host: "agent.example", Username: "operator", PKIDirectory: "/tmp/pki"}
	if e := validate(&base); e != nil {
		t.Fatal(e)
	}
	if base.Port != 22 || base.GRPCPort != 20001 {
		t.Fatal("defaults")
	}
	custom := base
	custom.Port = 2222
	custom.GRPCPort = 24443
	if e := validate(&custom); e != nil {
		t.Fatal(e)
	}
	if custom.Port != 2222 || custom.GRPCPort != 24443 {
		t.Fatal("explicit ports overwritten")
	}
	for _, dir := range []string{"../escape", "/tmp/escape", "a/../../b", "a;touch bad", "a\nb", ".", "a//b", "a/../b"} {
		r := base
		r.RemoteDirectory = dir
		if e := validate(&r); e == nil {
			t.Fatalf("unsafe path accepted: %q", dir)
		}
	}
	r := base
	r.GRPCPort = 65536
	if validate(&r) == nil {
		t.Fatal("bad port accepted")
	}
	r = base
	r.ServerName = "other.example"
	if validate(&r) == nil {
		t.Fatal("mismatched server name accepted")
	}
	if got := shellQuote("a'b"); got != "'a'\"'\"'b'" {
		t.Fatalf("unsafe quoting: %s", got)
	}
}
