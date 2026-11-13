package aliyun

import (
	"bytes"
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
	"net/url"
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
	call(context.Context, string, string, string, url.Values, any) error
}
type client struct {
	secretID, secretKey string
	http                *http.Client
	now                 func() time.Time
	nonce               func() (string, error)
}

func newClient(id, key string) *client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	// Even empty-body POSTs must not be replayed by HTTP/2 on GOAWAY, nor by
	// HTTP/1 on a reused connection. Only the explicit read policy below retries.
	tr.DisableKeepAlives = true
	tr.Protocols = new(http.Protocols)
	tr.Protocols.SetHTTP1(true)
	tr.TLSHandshakeTimeout = 20 * time.Second
	return &client{id, key, &http.Client{Transport: tr, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, time.Now, nonce}
}
func nonce() (string, error) {
	var b [16]byte
	_, e := rand.Read(b[:])
	return hex.EncodeToString(b[:]), e
}
func sha(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func mac(k []byte, s string) []byte {
	h := hmac.New(sha256.New, k)
	h.Write([]byte(s))
	return h.Sum(nil)
}
func params(p ...string) url.Values {
	v := url.Values{}
	for i := 0; i < len(p); i += 2 {
		v.Set(p[i], p[i+1])
	}
	return v
}
func clone(v url.Values) url.Values {
	r := url.Values{}
	for k, values := range v {
		r[k] = append([]string(nil), values...)
	}
	return r
}
func encoded(v url.Values) string { return strings.ReplaceAll(v.Encode(), "+", "%20") }

// ACS3 canonicalization follows the official native HTTP example:
// https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature
func sign(r *http.Request, id, key string) {
	const signed = "host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version"
	headers := "host:" + r.URL.Host + "\n"
	for _, name := range strings.Split(signed, ";")[1:] {
		headers += name + ":" + r.Header.Get(name) + "\n"
	}
	canonical := strings.Join([]string{r.Method, "/", r.URL.RawQuery, headers, signed, sha(nil)}, "\n")
	r.Header.Set("Authorization", "ACS3-HMAC-SHA256 Credential="+id+",SignedHeaders="+signed+",Signature="+hex.EncodeToString(mac([]byte(key), "ACS3-HMAC-SHA256\n"+sha([]byte(canonical)))))
}

var actions = map[string]map[string]bool{
	"ecs": {"DescribeImages": true, "DescribeKeyPairs": true, "ImportKeyPair": true, "DescribeSecurityGroups": true, "CreateSecurityGroup": true, "DescribeSecurityGroupAttribute": true, "AuthorizeSecurityGroup": true, "AuthorizeSecurityGroupEgress": true, "RunInstances": true, "DescribeInstances": true, "DescribeDisks": true, "DeleteInstance": true, "DescribeAvailableResource": true},
	"vpc": {"DescribeVpcs": true, "CreateVpc": true, "DescribeVSwitches": true, "CreateVSwitch": true},
}

type apiError struct{ code string }

func (e *apiError) Error() string {
	switch {
	case strings.HasPrefix(e.code, "InvalidAccessKeyId"), strings.HasPrefix(e.code, "Signature"), strings.HasPrefix(e.code, "Forbidden"), strings.HasPrefix(e.code, "Unauthorized"), e.code == "InvalidSecurityToken", e.code == "RegionUnauthorized":
		return "阿里云身份或权限校验失败，请检查 API 密钥及授权"
	case strings.HasPrefix(e.code, "Throttling"), strings.Contains(e.code, "Quota"), strings.Contains(e.code, "LimitExceeded"):
		return "阿里云配额或请求频率受限，请稍后查询结果"
	case e.code == "InsufficientBalance", e.code == "InvalidAccountStatus.NotEnoughBalance":
		return "阿里云账户余额不足"
	case strings.HasPrefix(e.code, "Invalid"), strings.HasPrefix(e.code, "Missing"):
		return "阿里云拒绝了资源参数，请检查模板与云端资源"
	default:
		return "阿里云请求未成功，请在控制台核对操作结果后重试查询"
	}
}

// HTTP POST does not imply a mutation here. Only these exact read APIs may be
// retried after a known transient transport failure, never writes or API errors.
var retryableReadActions = map[string]map[string]bool{
	"ecs": {"DescribeImages": true, "DescribeKeyPairs": true, "DescribeSecurityGroups": true, "DescribeSecurityGroupAttribute": true, "DescribeInstances": true, "DescribeDisks": true, "DescribeAvailableResource": true},
	"vpc": {"DescribeVpcs": true, "DescribeVSwitches": true},
}

const cloudReadRetryDelay = 100 * time.Millisecond

func (c *client) call(ctx context.Context, service, action, region string, input url.Values, result any) error {
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return transportError(err)
		}
		err := c.callOnce(ctx, service, action, region, input, result)
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

func (c *client) callOnce(ctx context.Context, service, action, region string, input url.Values, result any) error {
	if !actions[service][action] || !regionPattern.MatchString(region) {
		return errors.New("阿里云请求参数无效")
	}
	p := clone(input)
	for _, key := range []string{"Action", "Version", "Signature", "AccessKeyId", "RegionId"} {
		if _, ok := p[key]; ok {
			return errors.New("阿里云请求参数无效")
		}
	}
	p.Set("RegionId", region)
	unique, e := c.nonce()
	if e != nil {
		return errors.New("阿里云请求标识生成失败")
	}
	r, e := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+service+"."+region+".aliyuncs.com/?"+encoded(p), nil)
	if e != nil {
		return errors.New("阿里云请求参数无效")
	}
	r.GetBody = nil
	r.Header.Set("Accept", "application/json")
	r.Header.Set("x-acs-action", action)
	version := "2014-05-26"
	if service == "vpc" {
		version = "2016-04-28"
	}
	r.Header.Set("x-acs-version", version)
	r.Header.Set("x-acs-date", c.now().UTC().Format("2006-01-02T15:04:05Z"))
	r.Header.Set("x-acs-signature-nonce", unique)
	r.Header.Set("x-acs-content-sha256", sha(nil))
	sign(r, c.secretID, c.secretKey)
	response, e := c.http.Do(r)
	if e != nil {
		return &transportFailure{cause: e}
	}
	defer response.Body.Close()
	b, e := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if e != nil {
		return responseError(action, responseReadFailure, e)
	}
	if len(b) > 2<<20 {
		return responseError(action, responseTooLarge, nil)
	}
	var status struct {
		RequestID      string `json:"RequestId"`
		Code           string
		InstanceID     json.RawMessage `json:"InstanceId"`
		InstanceIDSets json.RawMessage `json:"InstanceIdSets"`
	}
	if !uniqueJSON(b) || json.Unmarshal(b, &status) != nil || !matches(`^[a-zA-Z0-9-]{1,128}$`, status.RequestID) {
		return errors.New("阿里云响应缺少有效请求标识或格式异常，请查询确认操作结果")
	}
	if status.Code != "" {
		var keys map[string]json.RawMessage
		json.Unmarshal(b, &keys)
		if strings.HasPrefix(action, "Create") || action == "ImportKeyPair" {
			for name := range keys {
				switch strings.ToLower(name) {
				case "vpcid", "vswitchid", "securitygroupid", "keypairname":
					return errors.New("阿里云创建响应矛盾，请查询确认操作结果")
				}
			}
		}
		if action == "RunInstances" && (len(status.InstanceID) > 0 || len(status.InstanceIDSets) > 0) {
			return errors.New("阿里云创建响应矛盾，请查询确认操作结果")
		}
		// 5xx responses are never authoritative proof of rejection.
		if response.StatusCode < 400 || response.StatusCode >= 500 {
			return errors.New("阿里云服务响应异常，操作结果可能未知，请查询确认")
		}
		return &apiError{status.Code}
	}
	if response.StatusCode != http.StatusOK {
		return responseError(action, responseHTTPStatus, nil)
	}
	if e = json.Unmarshal(b, result); e != nil {
		return responseError(action, responseFieldType, e)
	}
	return nil
}
func Execute(action string, in Input) (any, error) {
	for _, v := range []string{in.SecretID, in.SecretKey} {
		if v == "" || len(v) > 2048 || strings.ContainsFunc(v, func(r rune) bool { return r < 33 || r > 126 }) {
			return nil, errors.New("阿里云 API 凭据格式无效")
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
	case "aliyun_prepare", "aliyun_create", "aliyun_network_lookup", "aliyun_network_create", "aliyun_zones":
		t, e := parseTemplate(in.Template)
		if e != nil {
			return nil, e
		}
		switch action {
		case "aliyun_prepare":
			return prepare(ctx, api, t, in)
		case "aliyun_network_lookup":
			return lookupNetwork(ctx, api, t, in)
		case "aliyun_network_create":
			return createNetwork(ctx, api, t, in), nil
		case "aliyun_zones":
			return availableZones(ctx, api, t)
		default:
			return create(ctx, api, t, in)
		}
	case "aliyun_describe", "aliyun_release", "aliyun_recover":
		if !regionPattern.MatchString(in.Region) || !tokenPattern.MatchString(in.ClientToken) || (action != "aliyun_recover" && !instancePattern.MatchString(in.InstanceID)) {
			return nil, errors.New("阿里云实例标识或操作记录无效")
		}
		if action == "aliyun_release" {
			return release(ctx, api, in)
		}
		return describe(ctx, api, in, action == "aliyun_recover")
	default:
		return nil, errors.New("不支持的阿里云操作")
	}
}

// Read complete, stable pagination before concluding absence. Nested list names
// differ between ECS and VPC, so callers supply both documented envelope names.
func pages[T any](ctx context.Context, api caller, service, region, action, container, item string, p url.Values) ([]T, string, error) {
	var all []T
	total := -1
	requestID := ""
	seen := map[string]bool{}
	for page := 1; total < 0 || len(all) < total; page++ {
		in := clone(p)
		in.Set("PageSize", "50")
		in.Set("PageNumber", strconv.Itoa(page))
		var out map[string]json.RawMessage
		if e := api.call(ctx, service, action, region, in, &out); e != nil {
			return nil, "", e
		}
		var next string
		if raw, ok := out["NextToken"]; ok && (json.Unmarshal(raw, &next) != nil || next != "") {
			return nil, "", errors.New("阿里云分页查询模式异常，请重新查询")
		}
		var count, number, size int
		var nested map[string]json.RawMessage
		var rows []T
		if json.Unmarshal(out["TotalCount"], &count) != nil || json.Unmarshal(out["PageNumber"], &number) != nil || json.Unmarshal(out["PageSize"], &size) != nil || json.Unmarshal(out[container], &nested) != nil || json.Unmarshal(nested[item], &rows) != nil || !objectRows(nested[item]) || count < 0 || count > 4096 || number != page || size != 50 || len(rows) > 50 || (total >= 0 && total != count) || len(all)+len(rows) > count || (len(rows) == 0 && len(all) < count) {
			return nil, "", errors.New("阿里云分页查询结果不完整或格式异常，请重新查询")
		}
		total = count
		for _, row := range rows {
			b, _ := json.Marshal(row)
			key := string(b)
			if seen[key] {
				return nil, "", errors.New("阿里云分页查询结果重复，请重新查询")
			}
			seen[key] = true
		}
		all = append(all, rows...)
		json.Unmarshal(out["RequestId"], &requestID)
	}
	return all, requestID, nil
}

// Duplicate keys and trailing values make a response ambiguous. Never permit
// last-key-wins decoding to authorize another purchase or conclude absence.
func uniqueJSON(data []byte) bool {
	d := json.NewDecoder(bytes.NewReader(data))
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 128 {
			return false
		}
		t, e := d.Token()
		if e != nil {
			return false
		}
		delimiter, ok := t.(json.Delim)
		if !ok {
			return true
		}
		switch delimiter {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				name, ok := k.(string)
				if e != nil || !ok || seen[strings.ToLower(name)] {
					return false
				}
				seen[strings.ToLower(name)] = true
				if !value(depth + 1) {
					return false
				}
			}
			end, e := d.Token()
			return e == nil && end == json.Delim('}')
		case '[':
			for d.More() {
				if !value(depth + 1) {
					return false
				}
			}
			end, e := d.Token()
			return e == nil && end == json.Delim(']')
		default:
			return false
		}
	}
	if !value(0) {
		return false
	}
	_, e := d.Token()
	return e == io.EOF
}

// Cursor pagination is complete only when NextToken is exhausted. TotalCount
// belongs to page-number pagination and is explicitly meaningless for cursor
// queries of instances and disks; it must not reject rows or prove absence.
// https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describeinstances
// https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describedisks
func tokenPages[T any](ctx context.Context, api caller, service, region, action, container, item string, p url.Values) ([]T, string, error) {
	var all []T
	next := ""
	requestID := ""
	seenTokens := map[string]bool{}
	seenRows := map[string]bool{}
	for {
		in := clone(p)
		in.Set("MaxResults", "50")
		if next != "" {
			in.Set("NextToken", next)
		}
		var out map[string]json.RawMessage
		if e := api.call(ctx, service, action, region, in, &out); e != nil {
			return nil, "", e
		}
		var nested map[string]json.RawMessage
		var rows []T
		if json.Unmarshal(out[container], &nested) != nil || json.Unmarshal(nested[item], &rows) != nil || !objectRows(nested[item]) || len(rows) > 50 || len(all)+len(rows) > 4096 {
			return nil, "", errors.New("阿里云分页查询结果不完整或格式异常，请重新查询")
		}
		next = ""
		if raw, ok := out["NextToken"]; ok && json.Unmarshal(raw, &next) != nil {
			return nil, "", errors.New("阿里云分页查询模式异常，请重新查询")
		}
		for _, row := range rows {
			b, _ := json.Marshal(row)
			k := string(b)
			if seenRows[k] {
				return nil, "", errors.New("阿里云分页查询结果重复，请重新查询")
			}
			seenRows[k] = true
		}
		all = append(all, rows...)
		json.Unmarshal(out["RequestId"], &requestID)
		if next == "" {
			return all, requestID, nil
		}
		if seenTokens[next] || len(rows) == 0 || len(next) > 2048 {
			return nil, "", errors.New("阿里云分页查询模式异常，请重新查询")
		}
		seenTokens[next] = true
	}
}

func objectRows(raw json.RawMessage) bool {
	var rows []json.RawMessage
	if json.Unmarshal(raw, &rows) != nil || string(raw) == "null" {
		return false
	}
	for _, row := range rows {
		trimmed := bytes.TrimSpace(row)
		if len(trimmed) < 2 || trimmed[0] != '{' {
			return false
		}
	}
	return true
}
