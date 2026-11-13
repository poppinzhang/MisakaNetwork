package credentials

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

const aliyunIdentity = `{"RequestId":"fixture-request","AccountId":"123456789","Arn":"acs:ram::123456789:user/fixture","IdentityType":"RAMUser"}`
const volcengineIdentity = `{"ResponseMetadata":{"RequestId":"fixture-request","Action":"GetCallerIdentity","Version":"2018-01-01","Service":"sts","Region":"cn-beijing"},"Result":{"AccountId":123456789,"Trn":"trn:iam::123456789:user/fixture","IdentityType":"User","IdentityId":"987654321"}}`

func fixtureInput(provider string) Input {
	return Input{Provider: provider, AccessKeyID: "fixture-id", AccessKeySecret: "fixture-secret"}
}

func fixedNonce() (string, error) { return "fixture-nonce", nil }

func TestMalformedCredentialsFailBeforeNetwork(t *testing.T) {
	for _, provider := range []string{"tencent", "aliyun", "volcengine"} {
		for _, bad := range []string{"", "header\ninjection", "white space", "\x00", "非ASCII", strings.Repeat("x", 2049)} {
			for _, badID := range []bool{false, true} {
				in := fixtureInput(provider)
				if badID {
					in.AccessKeyID = bad
				} else {
					in.AccessKeySecret = bad
				}
				result, err := Verify(in)
				if err == nil || result.Verified || result.Provider != "" || strings.Contains(err.Error(), "fixture") {
					t.Fatal("invalid credentials accepted or disclosed")
				}
			}
		}
	}
	if result, err := Verify(fixtureInput("https://example.invalid")); err == nil || result.Verified || strings.Contains(err.Error(), "example.invalid") {
		t.Fatal("unsupported provider accepted or disclosed")
	}
}

func TestIdentityRequestsAreSignedAndReadOnly(t *testing.T) {
	for _, provider := range []string{"aliyun", "volcengine"} {
		t.Run(provider, func(t *testing.T) {
			calls := 0
			client := newHTTPClient()
			client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Scheme != "https" || r.URL.Path != "/" || r.Body != nil {
					t.Fatal("identity check is not an empty HTTPS request")
				}
				body := aliyunIdentity
				if provider == "aliyun" {
					if r.Method != http.MethodPost || r.URL.Host != "sts.aliyuncs.com" || r.URL.RawQuery != "" || r.Header.Get("x-acs-action") != "GetCallerIdentity" || r.Header.Get("x-acs-version") != "2015-04-01" || !strings.HasPrefix(r.Header.Get("Authorization"), "ACS3-HMAC-SHA256 Credential=fixture-id,") {
						t.Fatal("incorrect Aliyun identity endpoint or signature headers")
					}
				} else {
					body = volcengineIdentity
					if r.Method != http.MethodGet || r.URL.Host != "sts.volcengineapi.com" || r.URL.RawQuery != "Action=GetCallerIdentity&Version=2018-01-01" || !strings.HasPrefix(r.Header.Get("Authorization"), "HMAC-SHA256 Credential=fixture-id/") {
						t.Fatal("incorrect Volcengine identity endpoint or signature headers")
					}
				}
				if strings.Contains(r.URL.String(), "fixture") || strings.Contains(r.Header.Get("Authorization"), "fixture-secret") {
					t.Fatal("credential secret exposed in request")
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			})
			if err := verifyHTTP(context.Background(), client, fixtureInput(provider), time.Now(), fixedNonce); err != nil || calls != 1 {
				t.Fatalf("identity verification failed: %v", err)
			}
		})
	}
}

func TestAliyunSignatureMatchesOfficialVector(t *testing.T) {
	// The vendor's published fixed vector independently checks canonical header
	// ordering, query inclusion, empty payload hashing, and ACS3 key usage.
	// https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature
	r, _ := http.NewRequest(http.MethodPost, "https://ecs.cn-shanghai.aliyuncs.com/?ImageId=win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd&RegionId=cn-shanghai", nil)
	r.Header.Set("x-acs-action", "RunInstances")
	r.Header.Set("x-acs-version", "2014-05-26")
	r.Header.Set("x-acs-date", "2023-10-26T10:22:32Z")
	r.Header.Set("x-acs-signature-nonce", "3156853299f313e23d1673dc12e1703d")
	r.Header.Set("x-acs-content-sha256", digest(""))
	signAliyun(r, "YourAccessKeyId", "YourAccessKeySecret")
	if !strings.HasSuffix(r.Header.Get("Authorization"), "Signature=06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0") {
		t.Fatal("ACS3 signature does not match official vector")
	}
}

func TestVolcengineSignatureMatchesIndependentVector(t *testing.T) {
	// Independently calculated with Python hashlib/hmac, using the documented
	// GET identity query and the official date/region/service key derivation.
	r, err := volcengineRequest(context.Background(), fixtureInput("volcengine"), time.Date(2026, 11, 13, 1, 2, 3, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	want := "HMAC-SHA256 Credential=fixture-id/20261113/cn-beijing/sts/request, SignedHeaders=host;x-date, Signature=1517043f21fc425fee1f38c2cbbb5a1dd81d892aa0ee2170c37423424e0d7ebe"
	if r.Header.Get("Authorization") != want || r.Header.Get("X-Date") != "20261113T010203Z" {
		t.Fatal("Volcengine signature does not match independent vector")
	}
}

func TestVerificationRejectsHTTPAndIncompleteIdentityResponses(t *testing.T) {
	for _, provider := range []string{"aliyun", "volcengine"} {
		for _, tc := range []struct {
			body string
			code int
			err  error
		}{
			{body: "sensitive-response", code: 403},
			{body: "sensitive-response", code: 307},
			{body: "sensitive-response", code: 500},
			{body: "sensitive-response", code: 200},
			{body: `{}`, code: 200},
			{body: `null`, code: 200},
			{body: `{"RequestId":"fixture","Code":"InvalidAccessKeyId","Message":"fixture-secret"}`, code: 200},
			{body: `{"ResponseMetadata":{"Error":{"Code":"InvalidAccessKey","Message":"fixture-secret"}}}`, code: 200},
			{body: strings.Repeat("x", (64<<10)+1), code: 200},
			{err: errors.New("network: fixture-secret")},
			{body: strings.Replace(aliyunIdentity, `"AccountId":"123456789"`, `"AccountId":null`, 1), code: 200},
			{body: strings.Replace(volcengineIdentity, `"Service":"sts"`, `"Service":"ecs"`, 1), code: 200},
			{body: strings.Replace(volcengineIdentity, `"AccountId":123456789`, `"AccountId":0`, 1), code: 200},
		} {
			client := newHTTPClient()
			client.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				if tc.err != nil {
					return nil, tc.err
				}
				return &http.Response{StatusCode: tc.code, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
			})
			err := verifyHTTP(context.Background(), client, fixtureInput(provider), time.Now(), fixedNonce)
			if err == nil || strings.Contains(err.Error(), "sensitive") || strings.Contains(err.Error(), "fixture") {
				t.Fatalf("%s accepted or disclosed an invalid response", provider)
			}
		}
	}
}

func TestVerificationDoesNotSendIfNonceUnavailable(t *testing.T) {
	client := newHTTPClient()
	client.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
		t.Fatal("sent request without nonce")
		return nil, nil
	})
	if err := verifyHTTP(context.Background(), client, fixtureInput("aliyun"), time.Now(), func() (string, error) { return "", errors.New("fixture-secret") }); err != errVerification {
		t.Fatal("unsafe nonce failure")
	}
}

func TestHTTPClientEnforcesTLSRedirectAndTimeoutPolicies(t *testing.T) {
	client := newHTTPClient()
	defer client.CloseIdleConnections()
	config := client.Transport.(*http.Transport).TLSClientConfig
	if config.InsecureSkipVerify || config.MinVersion < tls.VersionTLS12 || client.Timeout != 30*time.Second {
		t.Fatal("unsafe TLS or timeout settings")
	}
	var destinationCalls int
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		destinationCalls++
	}))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()
	response, err := client.Get(source.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusTemporaryRedirect || destinationCalls != 0 {
		t.Fatal("redirect followed")
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("untrusted TLS request reached handler")
	}))
	defer server.Close()
	if response, err := client.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("untrusted certificate accepted")
	}
}
