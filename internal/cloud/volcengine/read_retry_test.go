package volcengine

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
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
	{"ecs", "DescribeInstances"},
	{"ecs", "DescribeAvailableResource"},
	{"vpc", "DescribeVpcs"},
	{"vpc", "DescribeSubnets"},
	{"vpc", "DescribeSecurityGroups"},
	{"vpc", "DescribeSecurityGroupAttributes"},
	{"vpc", "DescribeEipAddresses"},
}

func retryResponse(service, action string, status int, apiCode string) *http.Response {
	metadata := map[string]any{
		"Action": action, "Service": service, "Region": "cn-beijing",
		"Version": "2020-04-01", "RequestId": "retry-fixture",
	}
	result := map[string]any{}
	if apiCode != "" {
		metadata["Error"] = map[string]string{"Code": apiCode, "Message": "upstream-secret"}
	}
	body, _ := json.Marshal(map[string]any{"ResponseMetadata": metadata, "Result": result})
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(body)))}
}

func wrappedRetryError(err error) error {
	return &url.Error{
		Op:  "Get",
		URL: "https://proxy-user:proxy-secret@proxy-secret.invalid/?SecretKey=query-secret",
		Err: &net.OpError{Op: "read", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("203.0.113.77"), Port: 443}, Err: err},
	}
}

func requirePrivateRetryError(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("expected a failed request")
	}
	for _, fragment := range []string{"secret", "https://", "203.0.113.77", "SecretKey", "invalid"} {
		if strings.Contains(err.Error(), fragment) {
			t.Fatalf("request error exposed transport details: %q", fragment)
		}
	}
}

func TestDescribeTransportRetrySucceedsOnThirdAttempt(t *testing.T) {
	for _, operation := range readRetryActions {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Query().Get("Action") != operation.action {
					t.Fatal("retry changed action")
				}
				if calls < 3 {
					return nil, wrappedRetryError(io.EOF)
				}
				return retryResponse(operation.service, operation.action, http.StatusOK, ""), nil
			})
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-beijing", nil, &result)
			if err != nil || calls != 3 || result["RequestId"] != "retry-fixture" {
				t.Fatalf("read did not recover on third attempt: calls=%d result=%v err=%v", calls, result, err)
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
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-beijing", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 3 {
				t.Fatalf("exhausted read attempts = %d, want 3", calls)
			}
		})
	}
}

func TestDescribeRetryRebuildsECSPOSTBodyForEveryAttempt(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	payload := url.Values{"ImageIds.1": {"image-fixture"}, "ImageName": {"Ubuntu fixture+测试"}}
	wantBody := "ImageIds.1=image-fixture&ImageName=Ubuntu+fixture%2B%E6%B5%8B%E8%AF%95"
	seen := map[*http.Request]bool{}
	calls := 0
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if seen[r] {
			t.Error("retry reused a consumed request")
		}
		seen[r] = true
		if r.Method != http.MethodPost || r.URL.Query().Has("ImageIds.1") || r.GetBody != nil || r.Body == nil {
			t.Fatal("ECS retry changed request method or replay policy")
		}
		defer r.Body.Close()
		body, err := io.ReadAll(r.Body)
		if err != nil || string(body) != wantBody {
			t.Fatalf("attempt %d lost POST payload: body=%q err=%v", calls, body, err)
		}
		if calls < 3 {
			return nil, wrappedRetryError(syscall.ECONNRESET)
		}
		return retryResponse("ecs", "DescribeImages", http.StatusOK, ""), nil
	})
	var result map[string]any
	if err := c.call(context.Background(), "ecs", "DescribeImages", "cn-beijing", payload, &result); err != nil || calls != 3 {
		t.Fatalf("POST read retry failed: calls=%d err=%v", calls, err)
	}
}

type interruptedRetryBody struct{ closes *atomic.Int32 }

func (*interruptedRetryBody) Read(buffer []byte) (int, error) {
	return copy(buffer, `{"ResponseMetadata":"upstream-secret"`), io.ErrUnexpectedEOF
}
func (body *interruptedRetryBody) Close() error {
	body.closes.Add(1)
	return nil
}

func TestDescribeRetryHandlesInterruptedResponseBodies(t *testing.T) {
	for _, operation := range []struct{ service, action string }{{"ecs", "DescribeImages"}, {"vpc", "DescribeVpcs"}} {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			var closes atomic.Int32
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				if calls < 3 {
					return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &interruptedRetryBody{closes: &closes}}, nil
				}
				return retryResponse(operation.service, operation.action, http.StatusOK, ""), nil
			})
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-beijing", nil, &result)
			if err != nil || calls != 3 || closes.Load() != 2 {
				t.Fatalf("response interruption recovery: calls=%d closed=%d err=%v", calls, closes.Load(), err)
			}
		})
	}
}

func TestMutationInterruptedResponseBodyIsNeverReplayed(t *testing.T) {
	for _, operation := range []struct{ service, action string }{{"ecs", "RunInstances"}, {"vpc", "CreateVpc"}} {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			var closes atomic.Int32
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &interruptedRetryBody{closes: &closes}}, nil
			})
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-beijing", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 || closes.Load() != 1 {
				t.Fatalf("mutation response interruption: calls=%d closed=%d", calls, closes.Load())
			}
		})
	}
}

type retryTimeoutError struct{}

func (retryTimeoutError) Error() string   { return "timeout-secret" }
func (retryTimeoutError) Timeout() bool   { return true }
func (retryTimeoutError) Temporary() bool { return false }

func TestDescribeRetriesOnlyTypedTransientTransportFailures(t *testing.T) {
	for name, cause := range map[string]error{
		"net timeout":      retryTimeoutError{},
		"request deadline": context.DeadlineExceeded,
		"socket timeout":   syscall.ETIMEDOUT,
		"DNS timeout":      &net.DNSError{Err: "dns-secret", Name: "dns-secret.invalid", IsTimeout: true},
		"EOF":              io.EOF,
		"unexpected EOF":   io.ErrUnexpectedEOF,
		"connection reset": syscall.ECONNRESET,
		"connection abort": syscall.ECONNABORTED,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return nil, wrappedRetryError(cause)
				}
				return retryResponse("vpc", "DescribeVpcs", http.StatusOK, ""), nil
			})
			var result map[string]any
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := c.call(ctx, "vpc", "DescribeVpcs", "cn-beijing", nil, &result); err != nil || calls != 2 || ctx.Err() != nil {
				t.Fatalf("transient read did not recover with live parent context: calls=%d err=%v", calls, err)
			}
		})
	}
}

func TestDescribeDoesNotRetryPermanentOrUntypedTransportFailures(t *testing.T) {
	certificate := &x509.Certificate{DNSNames: []string{"certificate-secret.invalid"}}
	for name, cause := range map[string]error{
		"permanent DNS":          &net.DNSError{Err: "dns-secret", Name: "dns-secret.invalid", IsNotFound: true},
		"certificate chain":      x509.UnknownAuthorityError{Cert: certificate},
		"certificate hostname":   x509.HostnameError{Certificate: certificate, Host: "hostname-secret.invalid"},
		"TLS verification":       &tls.CertificateVerificationError{Err: errors.New("tls-secret")},
		"permission denied":      syscall.EACCES,
		"operation denied":       syscall.EPERM,
		"connection refused":     syscall.ECONNREFUSED,
		"network unreachable":    syscall.ENETUNREACH,
		"context canceled":       context.Canceled,
		"untyped transient text": errors.New("EOF connection reset timeout secret"),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				return nil, wrappedRetryError(cause)
			})
			var result map[string]any
			err := c.call(context.Background(), "vpc", "DescribeVpcs", "cn-beijing", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 {
				t.Fatalf("permanent failure made %d attempts", calls)
			}
		})
	}
}

func TestMutationTransportFailuresNeverRetryRegardlessOfHTTPMethod(t *testing.T) {
	for _, operation := range []struct{ service, action string }{
		{"ecs", "ImportKeyPair"},
		{"ecs", "RunInstances"},
		{"ecs", "DeleteInstances"},
		{"vpc", "CreateVpc"},
		{"vpc", "CreateSubnet"},
		{"vpc", "CreateSecurityGroup"},
		{"vpc", "AuthorizeSecurityGroupIngress"},
		{"vpc", "AuthorizeSecurityGroupEgress"},
	} {
		t.Run(operation.action, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				wantMethod := http.MethodPost
				if operation.service == "vpc" {
					wantMethod = http.MethodGet
				}
				if r.Method != wantMethod {
					t.Fatalf("method = %s, want %s", r.Method, wantMethod)
				}
				return nil, wrappedRetryError(io.EOF)
			})
			var result map[string]any
			err := c.call(context.Background(), operation.service, operation.action, "cn-beijing", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 {
				t.Fatalf("mutation was sent %d times after losing response", calls)
			}
		})
	}
}

func TestDescribeDoesNotRetryAPIRejectionsOrMalformedResponses(t *testing.T) {
	for name, response := range map[string]func() *http.Response{
		"API internal error": func() *http.Response {
			return retryResponse("vpc", "DescribeVpcs", http.StatusInternalServerError, "InternalError")
		},
		"API throttling": func() *http.Response {
			return retryResponse("vpc", "DescribeVpcs", http.StatusTooManyRequests, "Throttling")
		},
		"API permission": func() *http.Response {
			return retryResponse("vpc", "DescribeVpcs", http.StatusForbidden, "AccessDenied")
		},
		"HTTP gateway error": func() *http.Response {
			return &http.Response{StatusCode: http.StatusBadGateway, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("proxy-secret"))}
		},
		"malformed JSON": func() *http.Response {
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"ResponseMetadata":"upstream-secret"`))}
		},
		"mismatched action": func() *http.Response {
			return retryResponse("vpc", "CreateVpc", http.StatusOK, "")
		},
		"oversized response": func() *http.Response {
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(strings.Repeat("x", (2<<20)+1)))}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := newClient("fixture-id", "fixture-secret")
			calls := 0
			c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				calls++
				return response(), nil
			})
			var result map[string]any
			err := c.call(context.Background(), "vpc", "DescribeVpcs", "cn-beijing", nil, &result)
			requirePrivateRetryError(t, err)
			if calls != 1 {
				t.Fatalf("non-transport failure made %d attempts", calls)
			}
		})
	}
}

func TestDescribeRetryParentDeadlineStopsFurtherAttempts(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	calls := 0
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	var result map[string]any
	err := c.call(ctx, "vpc", "DescribeVpcs", "cn-beijing", nil, &result)
	requirePrivateRetryError(t, err)
	if ctx.Err() != context.DeadlineExceeded || calls != 1 {
		t.Fatalf("expired parent context was retried: calls=%d context=%v", calls, ctx.Err())
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
	go func() {
		var result map[string]any
		done <- c.call(ctx, "vpc", "DescribeVpcs", "cn-beijing", nil, &result)
	}()
	<-started
	// Cancel while the first 100 ms backoff is still pending.
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
