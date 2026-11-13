package aliyun

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

var readRetryActions = []struct{ service, action string }{
	{"ecs", "DescribeImages"},
	{"ecs", "DescribeKeyPairs"},
	{"ecs", "DescribeSecurityGroups"},
	{"ecs", "DescribeSecurityGroupAttribute"},
	{"ecs", "DescribeInstances"},
	{"ecs", "DescribeDisks"},
	{"ecs", "DescribeAvailableResource"},
	{"vpc", "DescribeVpcs"},
	{"vpc", "DescribeVSwitches"},
}

func retryResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func wrappedRetryError(err error) error {
	return &url.Error{
		Op: "Post", URL: "https://proxy-user:proxy-secret@proxy-secret.invalid/?PublicKeyBody=query-secret",
		Err: &net.OpError{Op: "read", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("203.0.113.77"), Port: 443}, Err: err},
	}
}

func requirePrivateRetryError(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("expected a failed request")
	}
	for _, fragment := range []string{"secret", "https://", "203.0.113.77", "PublicKeyBody", "invalid"} {
		if strings.Contains(err.Error(), fragment) {
			t.Fatalf("request error exposed transport details: %q", fragment)
		}
	}
}

func TestDescribeTransportRetryRebuildsSignedRequestAndSucceeds(t *testing.T) {
	for _, operation := range readRetryActions {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls, nonces := 0, 0
			c.nonce = func() (string, error) { nonces++; return fmt.Sprintf("nonce-%d", nonces), nil }
			c.now = func() time.Time { return time.Unix(1700000000+int64(nonces), 0) }
			seen := map[*http.Request]bool{}
			signatures := map[string]bool{}
			payload := params("Name", "fixture + 测试")
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != http.MethodPost || r.GetBody != nil || r.Body != nil || r.Header.Get("x-acs-action") != operation.action || r.URL.Host != operation.service+".cn-hangzhou.aliyuncs.com" {
					t.Fatal("retry changed request action, endpoint or replay policy")
				}
				if r.URL.Query().Get("Name") != payload.Get("Name") || r.URL.Query().Get("RegionId") != "cn-hangzhou" || payload.Has("RegionId") || strings.Contains(r.URL.RawQuery, "+") {
					t.Fatal("retry changed or mutated query parameters")
				}
				if seen[r] || signatures[r.Header.Get("Authorization")] || r.Header.Get("x-acs-signature-nonce") != fmt.Sprintf("nonce-%d", calls) || r.Header.Get("x-acs-date") != c.now().UTC().Format("2006-01-02T15:04:05Z") {
					t.Fatal("retry reused a request, nonce, timestamp or signature")
				}
				seen[r] = true
				signatures[r.Header.Get("Authorization")] = true
				if calls < 3 {
					return nil, wrappedRetryError(io.EOF)
				}
				return retryResponse(http.StatusOK, `{"RequestId":"retry-fixture"}`), nil
			})
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-hangzhou", payload, &result)
			if err != nil || calls != 3 || nonces != 3 || result["RequestId"] != "retry-fixture" {
				t.Fatalf("read did not recover: calls=%d nonces=%d err=%v", calls, nonces, err)
			}
		})
	}
}

func TestDescribeTransportRetryStopsAfterThreeAttempts(t *testing.T) {
	for _, operation := range readRetryActions {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				return nil, wrappedRetryError(syscall.ECONNRESET)
			})
			var result any
			err := c.call(context.Background(), operation.service, operation.action, "cn-hangzhou", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 3 {
				t.Fatalf("exhausted read attempts = %d, want 3", calls)
			}
		})
	}
}

type retryTimeoutError struct{}

func (retryTimeoutError) Error() string   { return "timeout-secret" }
func (retryTimeoutError) Timeout() bool   { return true }
func (retryTimeoutError) Temporary() bool { return false }

func TestDescribeRetriesOnlyTypedTransientTransportFailures(t *testing.T) {
	certificate := &x509.Certificate{DNSNames: []string{"certificate-secret.invalid"}}
	for _, tc := range []struct {
		name  string
		cause error
		calls int
	}{
		{"net timeout", retryTimeoutError{}, 2},
		{"socket timeout", syscall.ETIMEDOUT, 2},
		{"DNS timeout", &net.DNSError{Err: "dns-secret", Name: "dns-secret.invalid", IsTimeout: true}, 2},
		{"EOF", io.EOF, 2},
		{"unexpected EOF", io.ErrUnexpectedEOF, 2},
		{"connection reset", syscall.ECONNRESET, 2},
		{"connection abort", syscall.ECONNABORTED, 2},
		{"deadline", context.DeadlineExceeded, 1},
		{"canceled", context.Canceled, 1},
		{"DNS not found", &net.DNSError{Err: "dns-secret", Name: "dns-secret.invalid", IsNotFound: true}, 1},
		{"certificate chain", x509.UnknownAuthorityError{Cert: certificate}, 1},
		{"certificate hostname", x509.HostnameError{Certificate: certificate, Host: "hostname-secret.invalid"}, 1},
		{"TLS verification", &tls.CertificateVerificationError{Err: retryTimeoutError{}}, 1},
		{"permission denied", syscall.EACCES, 1},
		{"operation denied", syscall.EPERM, 1},
		{"connection refused", syscall.ECONNREFUSED, 1},
		{"network unreachable", syscall.ENETUNREACH, 1},
		{"untyped transient text", errors.New("EOF connection reset timeout secret"), 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return nil, wrappedRetryError(tc.cause)
				}
				return retryResponse(http.StatusOK, `{"RequestId":"retry-fixture"}`), nil
			})
			var result any
			err := c.call(context.Background(), "vpc", "DescribeVpcs", "cn-hangzhou", nil, &result)
			if calls != tc.calls || (err == nil) != (tc.calls == 2) {
				t.Fatalf("attempts=%d want=%d err=%v", calls, tc.calls, err)
			}
			if err != nil {
				requirePrivateRetryError(t, err)
			}
		})
	}
}

func TestMutationTransportFailuresNeverRetry(t *testing.T) {
	for _, operation := range []struct{ service, action string }{
		{"ecs", "ImportKeyPair"}, {"ecs", "CreateSecurityGroup"}, {"ecs", "AuthorizeSecurityGroup"}, {"ecs", "AuthorizeSecurityGroupEgress"},
		{"ecs", "RunInstances"}, {"ecs", "DeleteInstance"}, {"vpc", "CreateVpc"}, {"vpc", "CreateVSwitch"},
	} {
		t.Run(operation.action, func(t *testing.T) {
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != http.MethodPost || r.GetBody != nil {
					t.Fatal("mutation request changed replay policy")
				}
				return nil, wrappedRetryError(io.EOF)
			})
			var result any
			err := c.call(context.Background(), operation.service, operation.action, "cn-hangzhou", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 {
				t.Fatalf("mutation was sent %d times after losing response", calls)
			}
		})
	}
}

type interruptedRetryBody struct{ closes *atomic.Int32 }

func (*interruptedRetryBody) Read(b []byte) (int, error) {
	return copy(b, `{"Message":"upstream-secret"`), io.ErrUnexpectedEOF
}
func (b *interruptedRetryBody) Close() error { b.closes.Add(1); return nil }

func TestReadAndMutationInterruptedResponseBodiesAreNotRetried(t *testing.T) {
	for _, operation := range []struct{ service, action string }{{"ecs", "DescribeImages"}, {"vpc", "DescribeVpcs"}, {"ecs", "RunInstances"}, {"vpc", "CreateVpc"}} {
		t.Run(operation.action, func(t *testing.T) {
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			var closes atomic.Int32
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &interruptedRetryBody{closes: &closes}}, nil
			})
			var result any
			err := c.call(context.Background(), operation.service, operation.action, "cn-hangzhou", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 || closes.Load() != 1 {
				t.Fatalf("interrupted response retried or not closed: calls=%d closed=%d", calls, closes.Load())
			}
		})
	}
}

func TestDescribeDoesNotRetryAPIRejectionsOrMalformedResponses(t *testing.T) {
	for name, response := range map[string]func() *http.Response{
		"API internal error": func() *http.Response {
			return retryResponse(http.StatusInternalServerError, `{"RequestId":"retry-fixture","Code":"InternalError","Message":"upstream-secret"}`)
		},
		"API throttling": func() *http.Response {
			return retryResponse(http.StatusTooManyRequests, `{"RequestId":"retry-fixture","Code":"Throttling","Message":"upstream-secret"}`)
		},
		"API permission": func() *http.Response {
			return retryResponse(http.StatusForbidden, `{"RequestId":"retry-fixture","Code":"Forbidden","Message":"upstream-secret"}`)
		},
		"HTTP gateway error": func() *http.Response { return retryResponse(http.StatusBadGateway, "proxy-secret") },
		"malformed JSON":     func() *http.Response { return retryResponse(http.StatusOK, `{"Message":"upstream-secret"`) },
		"missing request ID": func() *http.Response { return retryResponse(http.StatusOK, `{"Message":"upstream-secret"}`) },
		"oversized response": func() *http.Response { return retryResponse(http.StatusOK, strings.Repeat("x", (2<<20)+1)) },
	} {
		t.Run(name, func(t *testing.T) {
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) { calls++; return response(), nil })
			var result any
			err := c.call(context.Background(), "vpc", "DescribeVpcs", "cn-hangzhou", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 {
				t.Fatalf("non-transport failure made %d attempts", calls)
			}
		})
	}
}

func TestDescribeRetryHonorsParentDeadlineAndInitialCancellation(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		c := newClient("fixture-id", "fixture-secret")
		calls := 0
		c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
			calls++
			<-r.Context().Done()
			return nil, r.Context().Err()
		})
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		if canceled {
			cancel()
		}
		var result any
		err := c.call(ctx, "vpc", "DescribeVpcs", "cn-hangzhou", nil, &result)
		cancel()
		requirePrivateRetryError(t, err)
		want := 1
		if canceled {
			want = 0
		}
		if calls != want {
			t.Fatalf("terminated context sent requests: %d want %d", calls, want)
		}
	}
}

func TestDescribeRetryCancellationInterruptsBackoff(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{}, 1)
	var calls atomic.Int32
	c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		select {
		case started <- struct{}{}:
		default:
		}
		return nil, wrappedRetryError(io.EOF)
	})
	done := make(chan error, 1)
	go func() { var result any; done <- c.call(ctx, "vpc", "DescribeVpcs", "cn-hangzhou", nil, &result) }()
	<-started
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		requirePrivateRetryError(t, err)
		if calls.Load() != 1 {
			t.Fatalf("canceled backoff sent another request: %d attempts", calls.Load())
		}
	case <-time.After(time.Second):
		t.Fatal("canceled retry backoff did not return")
	}
}

func TestReadRetryKeepsTimeoutTLSAndProtocolLimits(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	tr := c.http.Transport.(*http.Transport)
	if c.http.Timeout != 30*time.Second || tr.TLSHandshakeTimeout != 20*time.Second || !tr.DisableKeepAlives || tr.Protocols == nil || !tr.Protocols.HTTP1() || tr.Protocols.HTTP2() || tr.Protocols.UnencryptedHTTP2() || tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.MinVersion < tls.VersionTLS12 {
		t.Fatal("query retries weakened request limits, TLS verification or no-replay transport")
	}
	if c.http.CheckRedirect(&http.Request{}, nil) != http.ErrUseLastResponse {
		t.Fatal("redirect allowed")
	}
}
