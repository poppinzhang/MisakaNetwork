// Package credentials authenticates cloud API keys with read-only STS identity
// requests. It never creates resources or writes credentials to local storage.
package credentials

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/MisakaNetwork/MisakaNetwork/internal/cloud/tencent"
)

type Input struct {
	Provider        string `json:"provider"`
	AccessKeyID     string `json:"access_key_id"`
	AccessKeySecret string `json:"access_key_secret"`
}

type Result struct {
	Verified bool   `json:"verified"`
	Provider string `json:"provider"`
}

var errVerification = errors.New("云凭证联网验证未通过，请检查密钥、身份查询权限和网络后重试")

// Verify returns a positive result only after a signed HTTPS identity query
// succeeds. No endpoint, action, headers, session token, or ambient credential
// sources are accepted from the caller.
func Verify(in Input) (Result, error) {
	if err := validate(in); err != nil {
		return Result{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var err error
	if in.Provider == "tencent" {
		err = tencent.VerifyCredential(ctx, in.AccessKeyID, in.AccessKeySecret)
	} else {
		client := newHTTPClient()
		defer client.CloseIdleConnections()
		err = verifyHTTP(ctx, client, in, time.Now(), nonce)
	}
	if err != nil {
		return Result{}, errVerification
	}
	return Result{Verified: true, Provider: in.Provider}, nil
}

func validate(in Input) error {
	if in.Provider != "tencent" && in.Provider != "aliyun" && in.Provider != "volcengine" {
		return errors.New("不支持此云厂商的凭证验证")
	}
	for _, value := range []string{in.AccessKeyID, in.AccessKeySecret} {
		if value == "" || len(value) > 2048 || strings.ContainsFunc(value, func(r rune) bool { return r < 33 || r > 126 }) {
			return errors.New("云 API 凭据格式无效")
		}
	}
	return nil
}

func newHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	return &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func nonce() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", errVerification
	}
	return hex.EncodeToString(value[:]), nil
}

func verifyHTTP(ctx context.Context, client *http.Client, in Input, now time.Time, newNonce func() (string, error)) error {
	var request *http.Request
	var err error
	switch in.Provider {
	case "aliyun":
		var unique string
		unique, err = newNonce()
		if err == nil {
			request, err = aliyunRequest(ctx, in, now, unique)
		}
	case "volcengine":
		request, err = volcengineRequest(ctx, in, now)
	default:
		return errVerification
	}
	if err != nil {
		return errVerification
	}
	response, err := client.Do(request)
	if err != nil {
		return errVerification
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errVerification
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		return errVerification
	}
	if in.Provider == "aliyun" {
		var identity struct {
			RequestId, AccountId, Arn, IdentityType string
			Code                                    json.RawMessage
		}
		if json.Unmarshal(data, &identity) != nil || len(identity.Code) != 0 ||
			!present(identity.RequestId, identity.AccountId, identity.Arn, identity.IdentityType) {
			return errVerification
		}
	} else {
		var identity struct {
			ResponseMetadata struct {
				RequestId, Action, Version, Service string
				Error                               json.RawMessage
			}
			Result struct {
				AccountId                     uint64
				Trn, IdentityType, IdentityId string
			}
		}
		if json.Unmarshal(data, &identity) != nil || len(identity.ResponseMetadata.Error) != 0 ||
			identity.ResponseMetadata.Action != "GetCallerIdentity" ||
			identity.ResponseMetadata.Version != "2018-01-01" ||
			identity.ResponseMetadata.Service != "sts" || identity.Result.AccountId == 0 ||
			!present(identity.ResponseMetadata.RequestId, identity.Result.Trn, identity.Result.IdentityType, identity.Result.IdentityId) {
			return errVerification
		}
	}
	return nil
}

func present(values ...string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) == "" || len(value) > 2048 {
			return false
		}
	}
	return true
}

func digest(value string) string {
	h := sha256.Sum256([]byte(value))
	return hex.EncodeToString(h[:])
}

func mac(key []byte, value string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(value))
	return h.Sum(nil)
}

// ACS3 follows the official request specification; the identity query has no
// request body or business query parameters.
// https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature
// https://github.com/aliyun/alibabacloud-python-sdk/blob/master/sts-20150401/alibabacloud_sts20150401/client.py
func aliyunRequest(ctx context.Context, in Input, now time.Time, unique string) (*http.Request, error) {
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://sts.aliyuncs.com/", nil)
	if err != nil {
		return nil, errVerification
	}
	r.Header.Set("Accept", "application/json")
	r.Header.Set("x-acs-action", "GetCallerIdentity")
	r.Header.Set("x-acs-version", "2015-04-01")
	r.Header.Set("x-acs-date", now.UTC().Format("2006-01-02T15:04:05Z"))
	r.Header.Set("x-acs-signature-nonce", unique)
	r.Header.Set("x-acs-content-sha256", digest(""))
	signAliyun(r, in.AccessKeyID, in.AccessKeySecret)
	return r, nil
}

func signAliyun(r *http.Request, id, secret string) {
	const signed = "host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version"
	headers := "host:" + r.URL.Host + "\n"
	for _, name := range strings.Split(signed, ";")[1:] {
		headers += name + ":" + r.Header.Get(name) + "\n"
	}
	canonical := strings.Join([]string{r.Method, "/", r.URL.RawQuery, headers, signed, digest("")}, "\n")
	signature := hex.EncodeToString(mac([]byte(secret), "ACS3-HMAC-SHA256\n"+digest(canonical)))
	r.Header.Set("Authorization", "ACS3-HMAC-SHA256 Credential="+id+",SignedHeaders="+signed+",Signature="+signature)
}

// The service and region follow the STS identity endpoint's documented example;
// the key derivation matches the vendor's HMAC-SHA256 signing specification.
// https://docs.volcengine.com/docs/iam/get-caller-identity-get-request-or-identity-information?lang=zh
// https://github.com/volcengine/volc-sdk-golang/blob/main/base/sign.go
func volcengineRequest(ctx context.Context, in Input, now time.Time) (*http.Request, error) {
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://sts.volcengineapi.com/?Action=GetCallerIdentity&Version=2018-01-01", nil)
	if err != nil {
		return nil, errVerification
	}
	const signed = "host;x-date"
	stamp := now.UTC().Format("20060102T150405Z")
	scope := stamp[:8] + "/cn-beijing/sts/request"
	headers := "host:" + r.URL.Host + "\nx-date:" + stamp + "\n"
	canonical := strings.Join([]string{r.Method, "/", r.URL.RawQuery, headers, signed, digest("")}, "\n")
	key := mac(mac(mac(mac([]byte(in.AccessKeySecret), stamp[:8]), "cn-beijing"), "sts"), "request")
	signature := hex.EncodeToString(mac(key, "HMAC-SHA256\n"+stamp+"\n"+scope+"\n"+digest(canonical)))
	r.Header.Set("Accept", "application/json")
	r.Header.Set("X-Date", stamp)
	r.Header.Set("Authorization", "HMAC-SHA256 Credential="+in.AccessKeyID+"/"+scope+", SignedHeaders="+signed+", Signature="+signature)
	return r, nil
}
