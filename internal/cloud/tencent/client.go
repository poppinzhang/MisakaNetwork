package tencent

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type Input struct {
	SecretID        string          `json:"secret_id"`
	SecretKey       string          `json:"secret_key"`
	Template        json.RawMessage `json:"template,omitempty"`
	PublicKey       string          `json:"public_key,omitempty"`
	ClientToken     string          `json:"client_token,omitempty"`
	SecurityGroupID string          `json:"security_group_id,omitempty"`
	KeyID           string          `json:"key_id,omitempty"`
	InstanceName    string          `json:"instance_name,omitempty"`
	Region          string          `json:"region,omitempty"`
	InstanceID      string          `json:"instance_id,omitempty"`
	NetworkKind     string          `json:"network_kind,omitempty"`
	VpcID           string          `json:"vpc_id,omitempty"`
	SubnetID        string          `json:"subnet_id,omitempty"`
	SubnetCIDR      string          `json:"subnet_cidr,omitempty"`
}

type caller interface {
	call(context.Context, string, string, string, any, any) error
}

type client struct {
	secretID, secretKey string
	http                *http.Client
	now                 func() time.Time
}

func newClient(id, key string) *client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	return &client{secretID: id, secretKey: key, now: time.Now, http: &http.Client{
		Transport: transport, Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func sha(s []byte) string { h := sha256.Sum256(s); return hex.EncodeToString(h[:]) }
func mac(key []byte, value string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(value))
	return h.Sum(nil)
}

// canonicalRequest and authorization follow the official TC3-HMAC-SHA256
// specification: https://cloud.tencent.com/document/api/213/30654 .
func canonicalRequest(host, action string, payload []byte) string {
	return "POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:" + host + "\nx-tc-action:" + strings.ToLower(action) + "\n\ncontent-type;host;x-tc-action\n" + sha(payload)
}

func authorization(id, key, service, action string, payload []byte, now time.Time) string {
	date := now.UTC().Format("2006-01-02")
	scope := date + "/" + service + "/tc3_request"
	toSign := "TC3-HMAC-SHA256\n" + strconv.FormatInt(now.Unix(), 10) + "\n" + scope + "\n" + sha([]byte(canonicalRequest(service+".tencentcloudapi.com", action, payload)))
	k := mac(mac(mac([]byte("TC3"+key), date), service), "tc3_request")
	return "TC3-HMAC-SHA256 Credential=" + id + "/" + scope + ", SignedHeaders=content-type;host;x-tc-action, Signature=" + hex.EncodeToString(mac(k, toSign))
}

type apiError struct{ code string }

func (e *apiError) Error() string {
	// Never relay upstream Message, HTTP bodies, URLs or credential-bearing
	// transport errors. Only a fixed category enters the UI.
	category := strings.SplitN(e.code, ".", 2)[0]
	switch category {
	case "AuthFailure", "UnauthorizedOperation":
		return "腾讯云身份或权限校验失败，请检查 API 密钥及授权"
	case "LimitExceeded", "RequestLimitExceeded":
		return "腾讯云配额或请求频率受限，请稍后查询结果"
	case "InsufficientFunds":
		return "腾讯云账户余额不足"
	case "InvalidParameter", "InvalidParameterValue", "MissingParameter":
		return "腾讯云拒绝了资源参数，请检查模板与云端资源"
	case "ResourceInsufficient", "ResourceUnavailable":
		return "腾讯云当前资源不可用，请检查库存和实例状态"
	default:
		return "腾讯云请求未成功，请在控制台核对操作结果后重试查询"
	}
}

func (c *client) call(ctx context.Context, service, action, region string, input, result any) error {
	if (service != "cvm" && service != "vpc" && service != "sts") ||
		(service == "sts" && action != "GetCallerIdentity") || !regionPattern.MatchString(region) {
		return errors.New("腾讯云请求参数无效")
	}
	body, err := json.Marshal(input)
	if err != nil {
		return errors.New("腾讯云请求参数无效")
	}
	now := c.now()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+service+".tencentcloudapi.com/", bytes.NewReader(body))
	if err != nil {
		return errors.New("腾讯云请求参数无效")
	}
	// Mutations are never automatically replayed by this adapter.
	req.GetBody = nil
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("X-TC-Action", action)
	req.Header.Set("X-TC-Version", "2017-03-12")
	if service == "sts" {
		req.Header.Set("X-TC-Version", "2018-08-13")
	}
	req.Header.Set("X-TC-Region", region)
	req.Header.Set("X-TC-Timestamp", strconv.FormatInt(now.Unix(), 10))
	req.Header.Set("Authorization", authorization(c.secretID, c.secretKey, service, action, body, now))
	response, err := c.http.Do(req)
	if err != nil {
		return errors.New("腾讯云网络请求未完成，操作结果可能未知，请重新查询或到控制台核对")
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil || len(data) > 2<<20 || response.StatusCode != http.StatusOK {
		return errors.New("腾讯云响应异常，操作结果可能未知，请查询确认")
	}
	var envelope struct{ Response json.RawMessage }
	var status struct {
		Error       *struct{ Code string }
		RequestID   string          `json:"RequestId"`
		InstanceIDs json.RawMessage `json:"InstanceIdSet"`
	}
	if json.Unmarshal(data, &envelope) != nil || len(envelope.Response) == 0 || json.Unmarshal(envelope.Response, &status) != nil {
		return errors.New("腾讯云响应格式异常，请查询确认操作结果")
	}
	if !matches(`^[a-zA-Z0-9-]{1,128}$`, status.RequestID) {
		return errors.New("腾讯云响应缺少有效请求标识，请查询确认操作结果")
	}
	if status.Error != nil {
		// A purchase error with a success payload is not proof that no instance
		// was created. Never authorize another zone from a conflicting response.
		if action == "RunInstances" && len(status.InstanceIDs) != 0 {
			return errors.New("腾讯云创建响应矛盾，请查询确认操作结果")
		}
		return &apiError{code: status.Error.Code}
	}
	if err := json.Unmarshal(envelope.Response, result); err != nil {
		return errors.New("腾讯云响应格式异常，请查询确认操作结果")
	}
	return nil
}

func Execute(action string, in Input) (any, error) {
	for _, value := range []string{in.SecretID, in.SecretKey} {
		if value == "" || len(value) > 2048 || strings.ContainsAny(value, " \r\n\t") || strings.ContainsFunc(value, func(r rune) bool { return r < 33 || r > 126 }) {
			return nil, errors.New("腾讯云 API 凭据格式无效")
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	c := newClient(in.SecretID, in.SecretKey)
	defer c.http.CloseIdleConnections()
	return execute(ctx, c, action, in)
}

func execute(ctx context.Context, api caller, action string, in Input) (any, error) {
	switch action {
	case "tencent_prepare", "tencent_create", "tencent_network_lookup", "tencent_network_create", "tencent_zones":
		t, err := parseTemplate(in.Template)
		if err != nil {
			return nil, err
		}
		if action == "tencent_prepare" {
			return prepare(ctx, api, t, in.PublicKey)
		}
		if action == "tencent_zones" {
			return availableZones(ctx, api, t)
		}
		if action == "tencent_network_lookup" {
			return lookupNetwork(ctx, api, t, in)
		}
		if action == "tencent_network_create" {
			return createNetwork(ctx, api, t, in), nil
		}
		return create(ctx, api, t, in)
	case "tencent_describe", "tencent_release", "tencent_recover":
		if !regionPattern.MatchString(in.Region) || !tokenPattern.MatchString(in.ClientToken) || (action != "tencent_recover" && !instancePattern.MatchString(in.InstanceID)) {
			return nil, errors.New("腾讯云实例标识或操作记录无效")
		}
		if action == "tencent_release" {
			return release(ctx, api, in)
		}
		return describe(ctx, api, in, action == "tencent_recover")
	default:
		return nil, fmt.Errorf("不支持的腾讯云操作")
	}
}
