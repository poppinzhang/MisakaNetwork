package aliyun

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"io/fs"
	"net"
	"runtime"
	"syscall"
)

// Keep the original cause private for the exact read-only retry policy. Error
// remains safe at the helper boundary; the raw URL-bearing cause is not exposed.
type transportFailure struct{ cause error }

func (e *transportFailure) Error() string { return transportError(e.cause).Error() }

func transientTransportError(err error) bool {
	var hostname x509.HostnameError
	var authority x509.UnknownAuthorityError
	var invalid x509.CertificateInvalidError
	var roots x509.SystemRootsError
	var verification *tls.CertificateVerificationError
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.As(err, &hostname) || errors.As(err, &authority) || errors.As(err, &invalid) || errors.As(err, &roots) || errors.As(err, &verification) {
		return false
	}
	var network net.Error
	return (errors.As(err, &network) && network.Timeout()) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNABORTED) ||
		windowsTransportErrno(err, 10053, 10054, 10060)
}

// transportError is a display-only classification. In particular, a failed
// transport never proves that a mutating request was rejected or not received.
// Do not include err.Error(): URL, DNS, socket and TLS errors can contain query
// parameters, proxy credentials, addresses and provider-controlled text.
func transportError(err error) error {
	const uncertain = "，操作结果可能未知，请重新查询或到控制台核对"
	message := "阿里云网络请求未完成"
	var hostname x509.HostnameError
	var authority x509.UnknownAuthorityError
	var invalid x509.CertificateInvalidError
	var roots x509.SystemRootsError
	var verification *tls.CertificateVerificationError
	var network net.Error
	var dns *net.DNSError
	switch {
	case errors.Is(err, context.Canceled):
		message = "阿里云网络请求已取消"
	case errors.As(err, &hostname):
		message = "阿里云 TLS 服务器域名验证失败"
	case errors.As(err, &authority), errors.As(err, &invalid), errors.As(err, &roots), errors.As(err, &verification):
		message = "阿里云 TLS 服务器证书验证失败"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &network) && network.Timeout(), windowsTransportErrno(err, 10060): // WSAETIMEDOUT
		message = "阿里云网络请求超时"
	case errors.As(err, &dns):
		message = "阿里云服务域名解析失败"
	case errors.Is(err, fs.ErrPermission), errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM), windowsTransportErrno(err, 10013): // WSAEACCES
		message = "阿里云网络访问被系统权限阻止"
	case errors.Is(err, syscall.ECONNREFUSED), windowsTransportErrno(err, 10061): // WSAECONNREFUSED
		message = "阿里云网络连接被拒绝"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH), windowsTransportErrno(err, 10051, 10065): // WSAENETUNREACH, WSAEHOSTUNREACH
		message = "阿里云网络或目标主机不可达"
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.ECONNABORTED), errors.Is(err, syscall.EPIPE), errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed), windowsTransportErrno(err, 10053, 10054): // WSAECONNABORTED, WSAECONNRESET
		message = "阿里云网络连接中断"
	}
	return errors.New(message + uncertain)
}

// Go's Windows socket errors use Winsock values, while syscall.ECONNREFUSED
// and several related portable names have different invented Windows values.
// These values match the locked x/sys/windows definitions. Only compare them
// on Windows; the same integers must not acquire meaning on other platforms.
func windowsTransportErrno(err error, codes ...syscall.Errno) bool {
	if runtime.GOOS != "windows" {
		return false
	}
	for _, code := range codes {
		if errors.Is(err, code) {
			return true
		}
	}
	return false
}
