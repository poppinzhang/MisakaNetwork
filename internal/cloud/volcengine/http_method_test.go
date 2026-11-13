package volcengine

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestVPCRequestsUseGETAndPreserveCanonicalQuery(t *testing.T) {
	// Include spaces, Unicode and reserved characters: form encoding's '+' is
	// not interchangeable with RFC3986 '%20' in the signed canonical query.
	const encodedPayload = "CidrBlock=10.8.0.0%2F16&ClientToken=fixture-token&Tags.1.Key=misaka-managed&Tags.1.Value=lastorder-v1"
	for action := range allowedActions["vpc"] {
		t.Run(action, func(t *testing.T) {
			payload := url.Values{
				"VpcName":      {"Misaka fixture+网络/1"},
				"CidrBlock":    {"10.8.0.0/16"},
				"ClientToken":  {"fixture-token"},
				"Tags.1.Key":   {"misaka-managed"},
				"Tags.1.Value": {"lastorder-v1"},
			}
			original := make(url.Values, len(payload))
			for k, values := range payload {
				original[k] = append([]string(nil), values...)
			}
			c := newClient("fixture-id", "fixture-secret")
			c.now = func() time.Time { return time.Date(2026, 11, 13, 1, 2, 3, 0, time.UTC) }
			calls := 0
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != http.MethodGet || r.URL.Scheme != "https" || r.URL.Host != "vpc.cn-beijing.volcengineapi.com" || r.URL.Path != "/" {
					t.Fatalf("unexpected VPC request: %s %s", r.Method, r.URL)
				}
				// Write the expected order directly instead of using production
				// canonicalization helpers (Version sorts before VpcName).
				wantQuery := "Action=" + action + "&" + encodedPayload + "&Version=2020-04-01&VpcName=Misaka%20fixture%2B%E7%BD%91%E7%BB%9C%2F1"
				if r.URL.RawQuery != wantQuery {
					t.Errorf("query = %q, want %q", r.URL.RawQuery, wantQuery)
				}
				if r.Body != nil && r.Body != http.NoBody {
					body, err := io.ReadAll(r.Body)
					if err != nil || len(body) != 0 {
						t.Errorf("GET carries body %q: %v", body, err)
					}
				}
				if r.ContentLength != 0 || r.GetBody != nil || r.Header.Get("Content-Type") != "" {
					t.Error("VPC GET must carry no body, replay function or content type")
				}
				if !strings.Contains(r.Header.Get("Authorization"), "SignedHeaders=host;x-date, Signature=") || r.Header.Get("X-Date") != "20261113T010203Z" {
					t.Error("GET signing headers missing or incorrect")
				}
				for k, values := range original {
					if !reflect.DeepEqual(r.URL.Query()[k], values) {
						t.Errorf("lost query parameter %s", k)
					}
				}
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(vpcHTTPResponse(action)))}, nil
			})
			var out map[string]any
			if err := c.call(context.Background(), "vpc", action, "cn-beijing", payload, &out); err != nil {
				t.Fatal(err)
			}
			if calls != 1 || !reflect.DeepEqual(payload, original) {
				t.Fatalf("calls = %d; input payload changed: %v", calls, payload)
			}
		})
	}
}

func vpcHTTPResponse(action string) string {
	data, _ := json.Marshal(map[string]any{
		"ResponseMetadata": map[string]string{
			"Action": action, "Version": "2020-04-01", "Service": "vpc",
			"Region": "cn-beijing", "RequestId": "fixture-request",
		},
		"Result": map[string]any{"VpcId": "vpc-fixture", "Vpcs": []any{}},
	})
	return string(data)
}

func TestVPCMutationLostResponseIsNotReplayedOnNewConnection(t *testing.T) {
	var creates atomic.Int32
	var warmupAddress, createAddress atomic.Value
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Query().Get("Action") {
		case "DescribeVpcs":
			warmupAddress.Store(r.RemoteAddr)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, vpcHTTPResponse("DescribeVpcs"))
		case "CreateVpc":
			creates.Add(1)
			createAddress.Store(r.RemoteAddr)
			// The mutation has reached the server, but its response is lost.
			// A GET on a reused connection would otherwise be replayable by Go.
			connection, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Errorf("hijack: %v", err)
				return
			}
			_ = connection.Close()
		default:
			t.Errorf("unexpected action %q", r.URL.Query().Get("Action"))
		}
	}))
	defer server.Close()
	c := newClient("fixture-id", "fixture-secret")
	defer c.http.CloseIdleConnections()
	transport := c.http.Transport.(*http.Transport)
	if !transport.DisableKeepAlives {
		t.Fatal("GET mutations must not reuse connections")
	}
	if transport.Protocols == nil || !transport.Protocols.HTTP1() || transport.Protocols.HTTP2() || transport.Protocols.UnencryptedHTTP2() {
		t.Fatal("GET mutation transport must restrict connections to HTTP/1")
	}
	if transport.TLSClientConfig == nil || transport.TLSClientConfig.InsecureSkipVerify || transport.TLSClientConfig.MinVersion < tls.VersionTLS12 {
		t.Fatal("TLS certificate verification or minimum version weakened")
	}
	if c.http.CheckRedirect == nil || c.http.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Fatal("redirects must remain disabled")
	}
	// Redirect only the socket to the local server. The HTTPS URL and normal
	// certificate validation remain active; trust only this test's certificate.
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
	if err := c.call(ctx, "vpc", "DescribeVpcs", "cn-beijing", nil, &out); err != nil {
		t.Fatalf("warmup query: %v", err)
	}
	err := c.call(ctx, "vpc", "CreateVpc", "cn-beijing", url.Values{"ClientToken": {"fixture-token"}, "CidrBlock": {"10.8.0.0/16"}}, &out)
	if err == nil || creates.Load() != 1 {
		t.Fatalf("lost mutation response must remain unknown without replay: err=%v creates=%d", err, creates.Load())
	}
	if warmupAddress.Load() == nil || createAddress.Load() == nil || warmupAddress.Load() == createAddress.Load() {
		t.Fatal("query and mutation reused a connection")
	}
}
