package volcengine

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/url"
	"os"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

func TestTransportErrorsClassifyWrappedCausesWithoutSensitiveText(t *testing.T) {
	certificate := &x509.Certificate{DNSNames: []string{"certificate-secret.invalid"}}
	tests := []struct {
		name, message string
		err           error
	}{
		{"dns", "服务域名解析失败", &net.DNSError{Err: "dns-secret", Name: "dns-name-secret.invalid", Server: "192.0.2.42:53", IsNotFound: true}},
		{"dns timeout", "网络请求超时", &net.DNSError{Err: "dns-secret", Name: "dns-name-secret.invalid", IsTimeout: true}},
		{"deadline", "网络请求超时", context.DeadlineExceeded},
		{"socket timeout", "网络请求超时", syscall.ETIMEDOUT},
		{"unknown authority", " TLS 服务器证书验证失败", x509.UnknownAuthorityError{Cert: certificate}},
		{"certificate invalid", " TLS 服务器证书验证失败", x509.CertificateInvalidError{Cert: certificate, Reason: x509.Expired, Detail: "certificate-detail-secret"}},
		{"system roots", " TLS 服务器证书验证失败", x509.SystemRootsError{Err: errors.New("roots-secret")}},
		{"hostname", " TLS 服务器域名验证失败", x509.HostnameError{Certificate: certificate, Host: "hostname-secret.invalid"}},
		{"wrapped hostname", " TLS 服务器域名验证失败", &tls.CertificateVerificationError{UnverifiedCertificates: []*x509.Certificate{certificate}, Err: x509.HostnameError{Certificate: certificate, Host: "hostname-secret.invalid"}}},
		{"verification", " TLS 服务器证书验证失败", &tls.CertificateVerificationError{UnverifiedCertificates: []*x509.Certificate{certificate}, Err: errors.New("verification-secret")}},
		{"access denied", "网络访问被系统权限阻止", syscall.EACCES},
		{"operation denied", "网络访问被系统权限阻止", syscall.EPERM},
		{"permission", "网络访问被系统权限阻止", fs.ErrPermission},
		{"refused", "网络连接被拒绝", syscall.ECONNREFUSED},
		{"network unreachable", "网络或目标主机不可达", syscall.ENETUNREACH},
		{"host unreachable", "网络或目标主机不可达", syscall.EHOSTUNREACH},
		{"reset", "网络连接中断", syscall.ECONNRESET},
		{"aborted", "网络连接中断", syscall.ECONNABORTED},
		{"broken pipe", "网络连接中断", syscall.EPIPE},
		{"EOF", "网络连接中断", io.EOF},
		{"short body", "网络连接中断", io.ErrUnexpectedEOF},
		{"closed connection", "网络连接中断", net.ErrClosed},
		{"canceled", "网络请求已取消", context.Canceled},
		{"unknown", "网络请求未完成", errors.New("permission denied DNS TLS timeout EOF secret")},
		{"nil cause", "网络请求未完成", nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			// URL errors may contain the complete GET query and proxy credentials.
			// An OpError/SyscallError chain is how socket failures usually arrive.
			wrapped := &url.Error{
				Op:  "Get-secret",
				URL: "https://proxy-user:proxy-secret@proxy-secret.invalid/?SecretKey=query-secret&VpcName=private-secret",
				Err: &net.OpError{
					Op: "dial-secret", Net: "tcp",
					Source: &net.TCPAddr{IP: net.ParseIP("192.0.2.21"), Port: 12345},
					Addr:   &net.TCPAddr{IP: net.ParseIP("203.0.113.77"), Port: 443},
					Err:    &os.SyscallError{Syscall: "connect-secret", Err: test.err},
				},
			}
			for _, err := range []error{test.err, wrapped, fmt.Errorf("outer-secret: %w", wrapped)} {
				result := transportError(err)
				want := "火山引擎" + test.message + "，结果可能未知，请查询核对"
				if result == nil || result.Error() != want {
					t.Fatalf("classification = %v, want %q", result, want)
				}
				for _, forbidden := range []string{"secret", "https://", "SecretKey", "VpcName", "192.0.2.21", "203.0.113.77", "192.0.2.42", "invalid"} {
					if strings.Contains(result.Error(), forbidden) {
						t.Errorf("diagnostic leaked %q", forbidden)
					}
				}
			}
		})
	}
}

func TestTransportErrorDoesNotTurnMessageTextIntoTypedCause(t *testing.T) {
	for _, message := range []string{
		"context canceled", "context deadline exceeded", "lookup host: no such host",
		"x509: certificate signed by unknown authority", "permission denied", "connection reset by peer",
	} {
		if got := transportError(errors.New(message)).Error(); got != "火山引擎网络请求未完成，结果可能未知，请查询核对" {
			t.Fatalf("untyped error was classified from its message: %q", got)
		}
	}
}

func TestTransportErrorsRecognizeWindowsSocketCodesOnlyOnWindows(t *testing.T) {
	tests := []struct {
		code    syscall.Errno
		message string
	}{
		{10013, "网络访问被系统权限阻止"},
		{10051, "网络或目标主机不可达"},
		{10053, "网络连接中断"},
		{10054, "网络连接中断"},
		{10060, "网络请求超时"},
		{10061, "网络连接被拒绝"},
		{10065, "网络或目标主机不可达"},
	}
	for _, test := range tests {
		want := "火山引擎网络请求未完成，结果可能未知，请查询核对"
		if runtime.GOOS == "windows" {
			want = "火山引擎" + test.message + "，结果可能未知，请查询核对"
		}
		err := &url.Error{Op: "Get", URL: "https://proxy-secret.invalid/?key=query-secret", Err: &net.OpError{Op: "dial", Net: "tcp", Err: test.code}}
		if got := transportError(err).Error(); got != want {
			t.Errorf("Windows socket code %d = %q, want %q", test.code, got, want)
		}
	}
}
