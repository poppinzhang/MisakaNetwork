package volcengine

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Input struct {
	SecretID         string          `json:"secret_id"`
	SecretKey        string          `json:"secret_key"`
	Template         json.RawMessage `json:"template,omitempty"`
	PublicKey        string          `json:"public_key,omitempty"`
	ClientToken      string          `json:"client_token,omitempty"`
	SecurityGroupID  string          `json:"security_group_id,omitempty"`
	KeyID            string          `json:"key_id,omitempty"` // ECS binds by KeyPairName.
	InstanceName     string          `json:"instance_name,omitempty"`
	Region           string          `json:"region,omitempty"`
	InstanceID       string          `json:"instance_id,omitempty"`
	EipID            string          `json:"eip_id,omitempty"`
	ReleaseSubmitted bool            `json:"release_submitted,omitempty"`
	NetworkKind      string          `json:"network_kind,omitempty"`
	VpcID            string          `json:"vpc_id,omitempty"`
	SubnetID         string          `json:"subnet_id,omitempty"`
	SubnetCIDR       string          `json:"subnet_cidr,omitempty"`
}
type caller interface {
	call(context.Context, string, string, string, url.Values, any) error
}
type client struct {
	secretID, secretKey string
	http                *http.Client
	now                 func() time.Time
}

func newClient(id, key string) *client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	// Cross-region TLS setup can exceed the default ten seconds. Keep this
	// bounded by the per-request timeout and the overall operation context.
	t.TLSHandshakeTimeout = 20 * time.Second
	// VPC uses GET even for mutations. HTTP/1 retries requests on reused
	// connections, and HTTP/2 can replay a bodyless request after GOAWAY or
	// REFUSED_STREAM. Use a fresh HTTP/1 connection for each API call so a lost
	// response can only be recovered by our explicit resource queries.
	t.DisableKeepAlives = true
	t.Protocols = new(http.Protocols)
	t.Protocols.SetHTTP1(true)
	return &client{id, key, &http.Client{Transport: t, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, time.Now}
}
func sha(value []byte) string { h := sha256.Sum256(value); return hex.EncodeToString(h[:]) }
func mac(key []byte, value string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(value))
	return h.Sum(nil)
}

// RFC3986 encoding and HMAC derivation follow the official Volcengine signer:
// https://github.com/volcengine/volc-sdk-golang/blob/main/base/sign.go
func authorization(id, key, service, region, host, method, query, body string, now time.Time) string {
	stamp := now.UTC().Format("20060102T150405Z")
	scope := stamp[:8] + "/" + region + "/" + service + "/request"
	headers := "host:" + host + "\nx-date:" + stamp + "\n"
	signed := "host;x-date"
	if method == http.MethodPost {
		headers = "content-type:application/x-www-form-urlencoded\n" + headers
		signed = "content-type;" + signed
	}
	canonical := strings.Join([]string{method, "/", query, headers, signed, sha([]byte(body))}, "\n")
	k := mac(mac(mac(mac([]byte(key), stamp[:8]), region), service), "request")
	sig := hex.EncodeToString(mac(k, "HMAC-SHA256\n"+stamp+"\n"+scope+"\n"+sha([]byte(canonical))))
	return "HMAC-SHA256 Credential=" + id + "/" + scope + ", SignedHeaders=" + signed + ", Signature=" + sig
}

type apiError struct{ code string }

func (e *apiError) Error() string {
	switch {
	case strings.Contains(e.code, "Auth") || strings.HasPrefix(e.code, "Forbidden") || strings.HasPrefix(e.code, "AccessDenied") || strings.HasPrefix(e.code, "Signature") || e.code == "InvalidCredential" || e.code == "InvalidAccessKeyId" || e.code == "InvalidAccessKey" || e.code == "InvalidSignature":
		return "火山引擎身份或权限校验失败，请检查访问密钥及授权"
	case strings.HasPrefix(e.code, "QuotaExceeded") || strings.HasPrefix(e.code, "LimitExceeded") || strings.HasPrefix(e.code, "Throttling"):
		return "火山引擎配额或请求频率受限，请查询确认后重试"
	case strings.Contains(e.code, "Balance"):
		return "火山引擎账户余额不足"
	case strings.HasPrefix(e.code, "Invalid") || strings.HasPrefix(e.code, "Missing"):
		return "火山引擎拒绝了资源参数，请核对模板和云端状态"
	default:
		return "火山引擎请求未成功，请查询确认操作结果"
	}
}

var allowedActions = map[string]map[string]bool{
	"ecs": {"DescribeImages": true, "DescribeKeyPairs": true, "ImportKeyPair": true, "RunInstances": true, "DescribeInstances": true, "DeleteInstances": true, "DescribeAvailableResource": true},
	"vpc": {"DescribeVpcs": true, "CreateVpc": true, "DescribeSubnets": true, "CreateSubnet": true, "DescribeSecurityGroups": true, "CreateSecurityGroup": true, "DescribeSecurityGroupAttributes": true, "AuthorizeSecurityGroupIngress": true, "AuthorizeSecurityGroupEgress": true, "DescribeEipAddresses": true},
}

// HTTP GET does not mean read-only for this API. Only these exact queries may
// be repeated after a transient transport failure; mutations are never retried.
var retryableReadActions = map[string]map[string]bool{
	"ecs": {"DescribeImages": true, "DescribeKeyPairs": true, "DescribeInstances": true, "DescribeAvailableResource": true},
	"vpc": {"DescribeVpcs": true, "DescribeSubnets": true, "DescribeSecurityGroups": true, "DescribeSecurityGroupAttributes": true, "DescribeEipAddresses": true},
}

const cloudReadRetryDelay = 100 * time.Millisecond

func (c *client) call(ctx context.Context, service, action, region string, payload url.Values, result any) error {
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return transportError(err)
		}
		err := c.callOnce(ctx, service, action, region, payload, result)
		var failure *transportFailure
		if err == nil || attempt >= 2 || ctx.Err() != nil || !retryableReadActions[service][action] || !errors.As(err, &failure) || !transientTransportError(failure.cause) {
			return err
		}
		timer := time.NewTimer(cloudReadRetryDelay * time.Duration(attempt+1))
		select {
		case <-ctx.Done():
			timer.Stop()
			return transportError(ctx.Err())
		case <-timer.C:
		}
	}
}

func (c *client) callOnce(ctx context.Context, service, action, region string, payload url.Values, result any) error {
	if !regionPattern.MatchString(region) || !allowedActions[service][action] {
		return errors.New("火山引擎请求参数无效")
	}
	queryParams := params("Action", action, "Version", "2020-04-01")
	method := http.MethodPost
	bodyText := payload.Encode()
	// Unlike ECS (which supports POST forms), VPC APIs only accept GET with
	// all business parameters in the URL query, including CreateVpc and rules.
	// https://docs.volcengine.com/docs/virtual-private-cloud/request-structure?lang=zh
	if service == "vpc" {
		method, bodyText = http.MethodGet, ""
		for name, values := range payload {
			if name == "Action" || name == "Version" {
				return errors.New("火山引擎请求参数无效")
			}
			queryParams[name] = append([]string(nil), values...)
		}
	}
	// The official signer uses RFC3986 query encoding, not form-style '+'.
	query := strings.ReplaceAll(queryParams.Encode(), "+", "%20")
	host := service + "." + region + ".volcengineapi.com"
	r, err := http.NewRequestWithContext(ctx, method, "https://"+host+"/?"+query, strings.NewReader(bodyText))
	if err != nil {
		return errors.New("火山引擎请求参数无效")
	}
	now := c.now()
	r.Header.Set("Accept", "application/json")
	if method == http.MethodPost {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	r.Header.Set("X-Date", now.UTC().Format("20060102T150405Z"))
	r.Header.Set("Authorization", authorization(c.secretID, c.secretKey, service, region, host, method, query, bodyText, now))
	// Also prevent body replay for ECS POSTs. The transport above protects
	// bodyless VPC GETs, whose HTTP verb does not imply a read-only operation.
	r.GetBody = nil
	resp, err := c.http.Do(r)
	if err != nil {
		return &transportFailure{cause: err}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (2<<20)+1))
	if err != nil {
		return &transportFailure{cause: err}
	}
	if len(data) > 2<<20 {
		return errors.New("火山引擎响应异常，请查询确认")
	}
	var env struct {
		ResponseMetadata struct {
			RequestID                        string `json:"RequestId"`
			Action, Version, Service, Region string
			Error                            *struct{ Code string }
		}
		Result json.RawMessage
	}
	if json.Unmarshal(data, &env) != nil || !matches(`^[a-zA-Z0-9-]{1,128}$`, env.ResponseMetadata.RequestID) || env.ResponseMetadata.Action != action || env.ResponseMetadata.Version != "2020-04-01" || env.ResponseMetadata.Service != service || env.ResponseMetadata.Region != region {
		return errors.New("火山引擎响应格式异常，请查询确认")
	}
	if action == "DescribeAvailableResource" && !uniqueJSONDocument(data) {
		return errors.New("火山引擎库存响应字段存在歧义，请稍后重新查询")
	}
	if env.ResponseMetadata.Error != nil {
		if capacityCode(env.ResponseMetadata.Error.Code) {
			if action == "RunInstances" && resp.StatusCode == http.StatusInternalServerError && unambiguousRejectionEnvelope(data) {
				return &capacityRejection{code: env.ResponseMetadata.Error.Code, requestID: env.ResponseMetadata.RequestID}
			}
			return errors.New("火山引擎容量响应无法确认为购买拒绝，请查询核对操作结果")
		}
		if len(env.Result) > 0 && string(env.Result) != "null" && string(env.Result) != "{}" {
			return errors.New("火山引擎响应相互矛盾，请查询确认")
		}
		return &apiError{env.ResponseMetadata.Error.Code}
	}
	if resp.StatusCode != http.StatusOK || len(env.Result) == 0 || string(env.Result) == "null" {
		return errors.New("火山引擎响应异常，请查询确认")
	}
	// RequestId lives in metadata for ECS and may also be returned inside Result.
	var obj map[string]json.RawMessage
	if json.Unmarshal(env.Result, &obj) != nil || obj == nil {
		return errors.New("火山引擎响应格式异常，请查询确认")
	}
	obj["RequestId"], _ = json.Marshal(env.ResponseMetadata.RequestID)
	body, _ := json.Marshal(obj)
	if json.Unmarshal(body, result) != nil {
		return errors.New("火山引擎响应字段异常，请查询确认")
	}
	return nil
}
func Execute(action string, in Input) (any, error) {
	for _, v := range []string{in.SecretID, in.SecretKey} {
		if v == "" || len(v) > 2048 || strings.ContainsFunc(v, func(r rune) bool { return r < 33 || r > 126 }) {
			return nil, errors.New("火山引擎 API 凭据格式无效")
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
	case "volcengine_prepare", "volcengine_create", "volcengine_network_lookup", "volcengine_network_create", "volcengine_zones":
		t, err := parseTemplate(in.Template)
		if err != nil {
			return nil, err
		}
		switch action {
		case "volcengine_zones":
			return availableZones(ctx, api, t)
		case "volcengine_prepare":
			return prepare(ctx, api, t, in)
		case "volcengine_network_lookup":
			return lookupNetwork(ctx, api, t, in)
		case "volcengine_network_create":
			return createNetwork(ctx, api, t, in), nil
		default:
			return create(ctx, api, t, in)
		}
	case "volcengine_describe", "volcengine_recover", "volcengine_release":
		if !regionPattern.MatchString(in.Region) || !tokenPattern.MatchString(in.ClientToken) || (action != "volcengine_recover" && !instancePattern.MatchString(in.InstanceID)) || (in.EipID != "" && !eipPattern.MatchString(in.EipID)) {
			return nil, errors.New("火山引擎实例或操作记录无效")
		}
		if action == "volcengine_release" {
			return release(ctx, api, in)
		}
		return describe(ctx, api, in, action == "volcengine_recover")
	default:
		return nil, errors.New("不支持的火山引擎操作")
	}
}
