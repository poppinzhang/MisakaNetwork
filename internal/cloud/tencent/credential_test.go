package tencent

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestCredentialVerificationUsesOnlySTSIdentityQuery(t *testing.T) {
	c := newClient("fixture-id", "fixture-secret")
	calls := 0
	c.http.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		body, _ := io.ReadAll(r.Body)
		if r.URL.String() != "https://sts.tencentcloudapi.com/" || r.Method != http.MethodPost || string(body) != "{}" || r.Header.Get("X-TC-Action") != "GetCallerIdentity" || r.Header.Get("X-TC-Version") != "2018-08-13" || r.Header.Get("X-TC-Region") != "ap-guangzhou" || !strings.Contains(r.Header.Get("Authorization"), "/sts/tc3_request") {
			t.Fatal("incorrect STS identity request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"Response":{"RequestId":"fixture-request","AccountId":"123456789","UserId":"987654321","Arn":"qcs::cam:123456789:uin/987654321","Type":"CAMUser"}}`))}, nil
	})
	if err := verifyCredential(context.Background(), c); err != nil || calls != 1 {
		t.Fatalf("identity check failed: %v", err)
	}
	if err := c.call(context.Background(), "sts", "AssumeRole", "ap-guangzhou", struct{}{}, new(any)); err == nil || calls != 1 {
		t.Fatal("STS action allowlist accepted a different action")
	}
}

func TestCredentialVerificationRejectsIncompleteIdentityAndSafeFailures(t *testing.T) {
	for _, body := range []string{
		`{"Response":{"RequestId":"fixture-request"}}`,
		`{"Response":{"RequestId":"fixture-request","AccountId":"123456789","UserId":"987654321","Arn":"qcs::cam:123456789:uin/987654321"}}`,
		`{"Response":{"RequestId":"fixture-request","Error":{"Code":"AuthFailure.SignatureFailure","Message":"fixture-secret"}}}`,
		`{"Response":{"AccountId":"123456789","UserId":"987654321","Arn":"qcs::cam:123456789:uin/987654321","Type":"CAMUser"}}`,
		`{"Response":null}`,
		`not-json`,
	} {
		c := newClient("fixture-id", "fixture-secret")
		c.http.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})
		if err := verifyCredential(context.Background(), c); err == nil || strings.Contains(err.Error(), "fixture") {
			t.Fatal("malformed identity accepted or disclosed")
		}
	}
	api := &fakeAPI{t: t, respond: func(callRecord) (any, error) { return nil, errors.New("fixture-secret") }}
	if err := verifyCredential(context.Background(), api); err == nil || strings.Contains(err.Error(), "fixture") {
		t.Fatal("raw API error disclosed")
	}
	if err := VerifyCredential(context.Background(), "bad\nheader", "fixture-secret"); err == nil || strings.Contains(err.Error(), "fixture") {
		t.Fatal("invalid input accepted or disclosed")
	}
}
