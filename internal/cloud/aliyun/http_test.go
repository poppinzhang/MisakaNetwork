package aliyun

import (
	"context"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestMutationLostResponseIsNeverReplayed(t *testing.T) {
	var creates atomic.Int32
	var queryAddress, createAddress atomic.Value
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.ProtoMajor != 1 {
			t.Errorf("request protocol %s %s", r.Method, r.Proto)
		}
		switch r.Header.Get("x-acs-action") {
		case "DescribeVpcs":
			queryAddress.Store(r.RemoteAddr)
			_, _ = io.WriteString(w, `{"RequestId":"request-1"}`)
		case "CreateVpc":
			creates.Add(1)
			createAddress.Store(r.RemoteAddr)
			conn, _, e := w.(http.Hijacker).Hijack()
			if e != nil {
				t.Error(e)
				return
			}
			_ = conn.Close()
		default:
			t.Error("unexpected action")
		}
	}))
	defer server.Close()
	c := newClient("fixture-id", "fixture-secret")
	defer c.http.CloseIdleConnections()
	transport := c.http.Transport.(*http.Transport)
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", server.Listener.Addr().String())
	}
	transport.TLSClientConfig.RootCAs = x509.NewCertPool()
	transport.TLSClientConfig.RootCAs.AddCert(server.Certificate())
	transport.TLSClientConfig.ServerName = server.Certificate().DNSNames[0]
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var out map[string]any
	if e := c.call(ctx, "vpc", "DescribeVpcs", "cn-hangzhou", nil, &out); e != nil {
		t.Fatal(e)
	}
	e := c.call(ctx, "vpc", "CreateVpc", "cn-hangzhou", params("VpcName", "fixture"), &out)
	if e == nil || creates.Load() != 1 {
		t.Fatalf("lost response replayed %d %v", creates.Load(), e)
	}
	if queryAddress.Load() == nil || createAddress.Load() == nil || queryAddress.Load() == createAddress.Load() {
		t.Fatal("reused connection")
	}
}
