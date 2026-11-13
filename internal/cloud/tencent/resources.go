package tencent

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"net/netip"
	"sort"
	"strings"
	"sync"

	"golang.org/x/crypto/ssh"
)

const managedTag = "misaka-managed"
const managedValue = "lastorder-v1"
const operationTag = "misaka-operation"
const groupDescription = "MisakaNetwork managed SSH and Sisters TLS rules v1"

// Serializes preparation inside the Android helper. Desktop operation
// serialization is provided by CloudController; names are not a cloud lock.
var prepareMu sync.Mutex

type Prepared struct {
	SecurityGroupID string `json:"security_group_id"`
	KeyID           string `json:"key_id"`
}
type Created struct {
	InstanceID string `json:"instance_id"`
	RequestID  string `json:"request_id"`
}
type Status struct {
	InstanceID string `json:"instance_id"`
	State      string `json:"state"`
	PublicIP   string `json:"public_ip"`
	RequestID  string `json:"request_id"`
	Exists     bool   `json:"exists"`
}
type Released struct {
	RequestID string `json:"request_id"`
}
type tag struct {
	Key   string
	Value string
}
type instance struct {
	InstanceID         string `json:"InstanceId"`
	InstanceState      string
	InstanceChargeType string
	PublicIPAddresses  []string `json:"PublicIpAddresses"`
	Tags               []tag
	DataDisks          []json.RawMessage
}

func filter(name, value string) map[string]any {
	return map[string]any{"Name": name, "Values": []string{value}}
}

func preflightImage(ctx context.Context, api caller, t Template) error {
	var out struct {
		TotalCount int
		ImageSet   []struct {
			ImageId, OsName, ImageType, Architecture, ImageState, Platform string
			ImageSize                                                      int
		}
	}
	if err := api.call(ctx, "cvm", "DescribeImages", t.Region, map[string]any{"ImageIds": []string{t.RunInstances.ImageID}}, &out); err != nil {
		return err
	}
	if len(out.ImageSet) != 1 || out.TotalCount != 1 {
		return errors.New("模板镜像不存在或无权访问")
	}
	i := out.ImageSet[0]
	arch := "x86_64"
	if t.Architecture == "arm64" {
		arch = "arm"
	}
	if i.ImageId != t.RunInstances.ImageID || i.ImageType != "PUBLIC_IMAGE" || i.ImageState != "NORMAL" || i.Architecture != arch || !strings.EqualFold(i.Platform, "Ubuntu") || !matches(`(?i)\bubuntu(?:\s+server)?\s+24\.04(?:\D|$)`, i.OsName) || i.ImageSize < 1 || i.ImageSize > t.DiskGB {
		return errors.New("模板镜像必须是可用的 Ubuntu 24.04 官方镜像，架构与系统盘大小必须匹配")
	}
	return nil
}

func publicKey(value string) (ssh.PublicKey, error) {
	key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(value))
	if err != nil || len(options) != 0 || len(bytes.TrimSpace(rest)) != 0 || key.Type() != ssh.KeyAlgoRSA {
		return nil, errors.New("SSH 公钥必须是有效的 OpenSSH RSA 公钥")
	}
	crypto, ok := key.(ssh.CryptoPublicKey)
	if !ok {
		return nil, errors.New("SSH 公钥无效")
	}
	rsaKey, ok := crypto.CryptoPublicKey().(*rsa.PublicKey)
	if !ok || rsaKey.N.BitLen() < 2048 {
		return nil, errors.New("SSH 公钥必须至少为 RSA 2048 位")
	}
	return key, nil
}

func prepare(ctx context.Context, api caller, t Template, rawKey string) (Prepared, error) {
	key, err := publicKey(rawKey)
	if err != nil {
		return Prepared{}, err
	}
	prepareMu.Lock()
	defer prepareMu.Unlock()
	if err = preflightImage(ctx, api, t); err != nil {
		return Prepared{}, err
	}
	// Do not expose private key bytes; only this normalized public key is sent.
	keyID, err := ensureKey(ctx, api, t.Region, key)
	if err != nil {
		return Prepared{}, err
	}
	groupID, err := ensureGroup(ctx, api, t)
	if err != nil {
		return Prepared{}, err
	}
	return Prepared{SecurityGroupID: groupID, KeyID: keyID}, nil
}

func ensureKey(ctx context.Context, api caller, region string, key ssh.PublicKey) (string, error) {
	name := "misaka_" + sha(key.Marshal())[:18] // CVM limit: 25 chars.
	lookup := func() (string, error) {
		var out struct {
			TotalCount *int
			KeyPairSet []struct {
				KeyId, KeyName, PublicKey string
				ProjectId                 int
			}
		}
		if err := api.call(ctx, "cvm", "DescribeKeyPairs", region, map[string]any{"Filters": []any{filter("key-name", name), filter("project-id", "0")}, "Limit": 100}, &out); err != nil {
			return "", err
		}
		if out.TotalCount == nil || *out.TotalCount != len(out.KeyPairSet) {
			return "", errors.New("同名云密钥数量异常，请在控制台核对")
		}
		var ids []string
		for _, existing := range out.KeyPairSet {
			parsed, err := publicKey(existing.PublicKey)
			if existing.KeyName != name || existing.ProjectId != 0 || err != nil || !bytes.Equal(parsed.Marshal(), key.Marshal()) || !matches(`^skey-[a-z0-9]+$`, existing.KeyId) {
				return "", errors.New("同名云 SSH 密钥内容不匹配，已停止创建")
			}
			ids = append(ids, existing.KeyId)
		}
		sort.Strings(ids)
		if len(ids) > 0 {
			return ids[0], nil
		}
		return "", nil
	}
	id, err := lookup()
	if err != nil || id != "" {
		return id, err
	}
	var imported struct{ KeyId string }
	err = api.call(ctx, "cvm", "ImportKeyPair", region, map[string]any{"KeyName": name, "ProjectId": 0, "PublicKey": strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))}, &imported)
	if err != nil {
		// Creation may have succeeded despite a lost response, or another
		// controller may have imported the identical key concurrently.
		if id, lookupErr := lookup(); lookupErr == nil && id != "" {
			return id, nil
		}
		return "", err
	}
	if !matches(`^skey-[a-z0-9]+$`, imported.KeyId) {
		return "", errors.New("云 SSH 密钥导入结果异常，请在控制台核对")
	}
	return imported.KeyId, nil
}

type policy struct {
	Protocol        string
	Port            string `json:",omitempty"`
	CidrBlock       string
	Action          string
	Ipv6CidrBlock   string         `json:",omitempty"`
	SecurityGroupId string         `json:",omitempty"`
	AddressTemplate map[string]any `json:",omitempty"`
	ServiceTemplate map[string]any `json:",omitempty"`
}

func groupName(t Template) string {
	return "MisakaNetwork-Sisters-20001-" + sha([]byte(t.SSHCIDR + "\n" + t.GRPCCIDR))[:12]
}
func expectedPolicies(t Template) ([]policy, []policy) {
	return []policy{{Protocol: "TCP", Port: "22", CidrBlock: t.SSHCIDR, Action: "ACCEPT"}, {Protocol: "TCP", Port: "20001", CidrBlock: t.GRPCCIDR, Action: "ACCEPT"}}, []policy{{Protocol: "ALL", Port: "all", CidrBlock: "0.0.0.0/0", Action: "ACCEPT"}}
}

func emptyTemplate(m map[string]any) bool {
	for _, v := range m {
		if v == nil {
			continue
		}
		if text, ok := v.(string); ok && text == "" {
			continue
		}
		return false
	}
	return true
}

func policyKey(p policy) string {
	if strings.EqualFold(p.Protocol, "ALL") && (p.Port == "" || strings.EqualFold(p.Port, "all")) {
		p.Port = "all"
	}
	return strings.ToUpper(p.Protocol) + "|" + p.Port + "|" + p.CidrBlock + "|" + p.Action
}

func missingPolicies(actual, expected []policy) ([]policy, error) {
	wanted := map[string]policy{}
	for _, p := range expected {
		wanted[policyKey(p)] = p
	}
	for _, p := range actual {
		if p.Ipv6CidrBlock != "" || p.SecurityGroupId != "" || !emptyTemplate(p.AddressTemplate) || !emptyTemplate(p.ServiceTemplate) {
			return nil, errors.New("同名安全组包含模板以外的规则，请在控制台核对")
		}
		if _, ok := wanted[policyKey(p)]; !ok {
			return nil, errors.New("同名安全组规则已改变，请在控制台核对")
		}
		delete(wanted, policyKey(p))
	}
	var missing []policy
	for _, p := range expected {
		if _, ok := wanted[policyKey(p)]; ok {
			missing = append(missing, p)
		}
	}
	return missing, nil
}

func ensureGroup(ctx context.Context, api caller, t Template) (string, error) {
	name := groupName(t)
	lookup := func() (string, error) {
		var out struct {
			TotalCount       *int
			SecurityGroupSet []struct {
				SecurityGroupId, SecurityGroupName, SecurityGroupDesc string
				ProjectId                                             json.RawMessage
			}
		}
		if err := api.call(ctx, "vpc", "DescribeSecurityGroups", t.Region, map[string]any{"Filters": []any{filter("security-group-name", name), filter("project-id", "0")}, "Limit": "100"}, &out); err != nil {
			return "", err
		}
		if out.TotalCount == nil || *out.TotalCount != len(out.SecurityGroupSet) {
			return "", errors.New("同名安全组数量异常，请在控制台核对")
		}
		var ids []string
		for _, group := range out.SecurityGroupSet {
			if group.SecurityGroupName != name || group.SecurityGroupDesc != groupDescription || (string(group.ProjectId) != "0" && string(group.ProjectId) != `"0"`) || !matches(`^sg-[a-z0-9]+$`, group.SecurityGroupId) {
				return "", errors.New("同名安全组不是本应用的匹配配置，已停止创建")
			}
			ids = append(ids, group.SecurityGroupId)
		}
		sort.Strings(ids)
		if len(ids) > 0 {
			return ids[0], nil
		}
		return "", nil
	}
	id, err := lookup()
	if err != nil {
		return "", err
	}
	if id == "" {
		var out struct {
			SecurityGroup struct{ SecurityGroupId string }
		}
		err := api.call(ctx, "vpc", "CreateSecurityGroup", t.Region, map[string]any{"GroupName": name, "GroupDescription": groupDescription, "ProjectId": "0"}, &out)
		if err != nil {
			var lookupErr error
			id, lookupErr = lookup()
			if lookupErr != nil || id == "" {
				return "", err
			}
		} else {
			id = out.SecurityGroup.SecurityGroupId
		}
		if !matches(`^sg-[a-z0-9]+$`, id) {
			return "", errors.New("安全组创建结果异常，请在控制台核对")
		}
	}
	if err := reconcilePolicies(ctx, api, t, id, true); err != nil {
		return "", err
	}
	return id, nil
}

func reconcilePolicies(ctx context.Context, api caller, t Template, id string, allowAdd bool) error {
	var out struct {
		SecurityGroupPolicySet *struct {
			Ingress []policy
			Egress  []policy
			Version string
		}
	}
	if err := api.call(ctx, "vpc", "DescribeSecurityGroupPolicies", t.Region, map[string]any{"SecurityGroupId": id}, &out); err != nil {
		return err
	}
	if out.SecurityGroupPolicySet == nil || !matches(`^[0-9]{1,20}$`, out.SecurityGroupPolicySet.Version) {
		return errors.New("安全组规则响应不完整，已停止操作")
	}
	ingress, egress := expectedPolicies(t)
	for _, direction := range []struct {
		name             string
		actual, expected []policy
	}{{"Ingress", out.SecurityGroupPolicySet.Ingress, ingress}, {"Egress", out.SecurityGroupPolicySet.Egress, egress}} {
		missing, err := missingPolicies(direction.actual, direction.expected)
		if err != nil {
			return err
		}
		if len(missing) == 0 {
			continue
		}
		if !allowAdd {
			return errors.New("安全组规则未完成，请重试准备操作")
		}
		// VPC accepts only one direction per CreateSecurityGroupPolicies call.
		var response struct{ RequestId string }
		if err := api.call(ctx, "vpc", "CreateSecurityGroupPolicies", t.Region, map[string]any{"SecurityGroupId": id, "SecurityGroupPolicySet": map[string]any{direction.name: missing}}, &response); err != nil {
			return err
		}
	}
	if allowAdd {
		return reconcilePolicies(ctx, api, t, id, false)
	}
	return nil
}

func create(ctx context.Context, api caller, t Template, in Input) (Created, error) {
	if !tokenPattern.MatchString(in.ClientToken) || !matches(`^sg-[a-z0-9]+$`, in.SecurityGroupID) || !matches(`^skey-[a-z0-9]+$`, in.KeyID) || !textOK(in.InstanceName, 60) {
		return Created{}, errors.New("腾讯云创建操作记录不完整")
	}
	if err := preflightImage(ctx, api, t); err != nil {
		return Created{}, err
	}
	if err := reconcilePolicies(ctx, api, t, in.SecurityGroupID, false); err != nil {
		return Created{}, err
	}
	encoded, _ := json.Marshal(t.RunInstances)
	var payload map[string]any
	json.Unmarshal(encoded, &payload)
	payload["InstanceChargeType"] = "POSTPAID_BY_HOUR"
	payload["InstanceCount"] = 1
	payload["ClientToken"] = in.ClientToken
	payload["InstanceName"] = in.InstanceName
	payload["SecurityGroupIds"] = []string{in.SecurityGroupID}
	payload["LoginSettings"] = map[string]any{"KeyIds": []string{in.KeyID}}
	payload["TagSpecification"] = []any{map[string]any{"ResourceType": "instance", "Tags": []tag{{Key: managedTag, Value: managedValue}, {Key: operationTag, Value: in.ClientToken}}}}
	var out struct {
		InstanceIdSet []string
		RequestId     string
	}
	if err := api.call(ctx, "cvm", "RunInstances", t.Region, payload, &out); err != nil {
		return Created{}, err
	}
	if len(out.InstanceIdSet) != 1 || !instancePattern.MatchString(out.InstanceIdSet[0]) {
		return Created{}, errors.New("云服务器创建返回结果异常，请按操作记录查询核对，勿重复购买")
	}
	return Created{InstanceID: out.InstanceIdSet[0], RequestID: out.RequestId}, nil
}

func hasTag(tags []tag, key, value string) bool {
	count := 0
	for _, item := range tags {
		if item.Key == key {
			if item.Value != value {
				return false
			}
			count++
		}
	}
	return count == 1
}

func query(ctx context.Context, api caller, in Input, recover bool) (*instance, string, error) {
	payload := map[string]any{"InstanceIds": []string{in.InstanceID}, "Limit": 100}
	if recover {
		payload = map[string]any{"Filters": []any{filter("tag:"+managedTag, managedValue), filter("tag:"+operationTag, in.ClientToken)}, "Limit": 100}
	}
	var out struct {
		InstanceSet []instance
		TotalCount  *int
		RequestId   string
	}
	if err := api.call(ctx, "cvm", "DescribeInstances", in.Region, payload, &out); err != nil {
		return nil, "", err
	}
	if out.TotalCount == nil || *out.TotalCount != len(out.InstanceSet) || len(out.InstanceSet) > 1 {
		return nil, "", errors.New("实例查询结果不唯一，请在腾讯云控制台核对")
	}
	if len(out.InstanceSet) == 0 {
		return nil, out.RequestId, nil
	}
	i := out.InstanceSet[0]
	if !instancePattern.MatchString(i.InstanceID) || (!recover && i.InstanceID != in.InstanceID) || !hasTag(i.Tags, managedTag, managedValue) || !hasTag(i.Tags, operationTag, in.ClientToken) {
		return nil, "", errors.New("云服务器与本地创建记录不匹配，已停止操作")
	}
	return &i, out.RequestId, nil
}

func describe(ctx context.Context, api caller, in Input, recover bool) (Status, error) {
	i, requestID, err := query(ctx, api, in, recover)
	if err != nil {
		return Status{}, err
	}
	if i == nil {
		return Status{InstanceID: in.InstanceID, RequestID: requestID}, nil
	}
	state := i.InstanceState
	if !matches(`^[A-Z_]{1,64}$`, state) {
		return Status{}, errors.New("云服务器状态格式异常")
	}
	ip := ""
	for _, value := range i.PublicIPAddresses {
		parsed, err := netip.ParseAddr(value)
		if err != nil || !parsed.Is4() || !parsed.IsGlobalUnicast() || parsed.IsPrivate() {
			continue
		}
		ip = parsed.String()
		break
	}
	return Status{InstanceID: i.InstanceID, State: state, PublicIP: ip, Exists: true, RequestID: requestID}, nil
}

func release(ctx context.Context, api caller, in Input) (Released, error) {
	i, requestID, err := query(ctx, api, in, false)
	if err != nil {
		return Released{}, err
	}
	if i == nil {
		return Released{RequestID: requestID}, nil
	}
	if i.InstanceChargeType != "POSTPAID_BY_HOUR" {
		return Released{}, errors.New("仅允许释放按量计费云服务器")
	}
	if !matches(`^[A-Z_]{1,64}$`, i.InstanceState) {
		return Released{}, errors.New("云服务器状态响应不完整，已停止释放")
	}
	if len(i.DataDisks) != 0 {
		return Released{}, errors.New("云服务器挂载了额外数据盘，请先在腾讯云控制台核对和处理")
	}
	var addresses struct {
		TotalCount *int
		AddressSet []json.RawMessage
	}
	if err := api.call(ctx, "vpc", "DescribeAddresses", in.Region, map[string]any{"Filters": []any{filter("instance-id", in.InstanceID)}, "Limit": 100}, &addresses); err != nil {
		return Released{}, err
	}
	if addresses.TotalCount == nil {
		return Released{}, errors.New("公网地址查询响应不完整，已停止释放")
	}
	if *addresses.TotalCount != 0 || len(addresses.AddressSet) != 0 {
		return Released{}, errors.New("云服务器关联了独立弹性公网 IP，请先在腾讯云控制台核对和处理")
	}
	if i.InstanceState == "TERMINATING" {
		return Released{RequestID: requestID}, nil
	}
	var out struct{ RequestId string }
	if err := api.call(ctx, "cvm", "TerminateInstances", in.Region, map[string]any{"InstanceIds": []string{in.InstanceID}, "ReleaseAddress": false, "ReleasePrepaidDataDisks": false}, &out); err != nil {
		return Released{}, err
	}
	return Released{RequestID: out.RequestId}, nil
}
