package aliyun

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"golang.org/x/crypto/ssh"
	"net/netip"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
)

const managedTag = "misaka-managed"
const managedValue = "lastorder-v1"
const operationTag = "misaka-operation"
const groupName = "MisakaNetwork-Sisters-20001-v1"
const groupDescription = "MisakaNetwork managed SSH and Sisters TLS rules v1"

var prepareMu sync.Mutex

type tag struct{ Key, Value string }
type Prepared struct {
	SecurityGroupID string `json:"security_group_id"`
	KeyID           string `json:"key_id"`
}
type Created struct {
	State      string `json:"state,omitempty"`
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

func hasTag(tags []tag, key, value string) bool {
	n := 0
	for _, t := range tags {
		if t.Key == key {
			if t.Value != value {
				return false
			}
			n++
		}
	}
	return n == 1
}
func addTags(p url.Values, tags []tag) {
	for i, t := range tags {
		prefix := "Tag." + strconv.Itoa(i+1)
		p.Set(prefix+".Key", t.Key)
		p.Set(prefix+".Value", t.Value)
	}
}
func publicKey(raw string) (ssh.PublicKey, error) {
	k, _, opts, rest, e := ssh.ParseAuthorizedKey([]byte(raw))
	if e != nil || len(opts) > 0 || len(bytes.TrimSpace(rest)) > 0 || k.Type() != ssh.KeyAlgoRSA {
		return nil, errors.New("SSH 公钥必须是有效的 OpenSSH RSA 公钥")
	}
	c, ok := k.(ssh.CryptoPublicKey)
	if !ok {
		return nil, errors.New("SSH 公钥无效")
	}
	r, ok := c.CryptoPublicKey().(*rsa.PublicKey)
	if !ok || r.N.BitLen() < 2048 {
		return nil, errors.New("SSH 公钥必须至少为 RSA 2048 位")
	}
	return k, nil
}
func keyName(k ssh.PublicKey) string { return "misaka_" + sha(k.Marshal())[:24] }
func preflightImage(ctx context.Context, api caller, t Template) error {
	type image struct {
		ImageID                                                         string `json:"ImageId"`
		ImageOwnerAlias, OSName, OSType, Platform, Architecture, Status string
		Size                                                            int
		DiskDeviceMappings                                              *struct{ DiskDeviceMapping []struct{ Type, Size string } }
	}
	rows, _, e := pages[image](ctx, api, "ecs", t.Region, "DescribeImages", "Images", "Image", params("ImageId", t.RunInstances.ImageID, "Status", "ALL"))
	if e != nil {
		return e
	}
	// An empty owner selector excludes Marketplace/community images. Resolve
	// the administrator's exact ID across those documented source partitions.
	// No instance type, architecture, distribution, or version filter is sent.
	// https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describeimages
	for _, source := range []url.Values{
		params("ImageId", t.RunInstances.ImageID, "Status", "ALL", "ImageOwnerAlias", "marketplace"),
		params("ImageId", t.RunInstances.ImageID, "Status", "ALL", "ImageOwnerAlias", "others", "IsPublic", "true"),
	} {
		if len(rows) != 0 {
			break
		}
		rows, _, e = pages[image](ctx, api, "ecs", t.Region, "DescribeImages", "Images", "Image", source)
		if e != nil {
			return e
		}
	}
	if len(rows) != 1 {
		return errors.New("模板镜像不存在或无权访问")
	}
	i := rows[0]
	arch := "x86_64"
	if t.Architecture == "arm64" {
		arch = "arm64"
	}
	if i.ImageID != t.RunInstances.ImageID || i.Status != "Available" || i.OSType != "linux" || i.Architecture != arch || i.Size < 1 || i.Size > t.DiskGB {
		return errors.New("模板镜像必须是可用的 Linux 镜像，架构与系统盘大小必须匹配")
	}
	if i.DiskDeviceMappings == nil || len(i.DiskDeviceMappings.DiskDeviceMapping) == 0 {
		// Public images can omit snapshot mappings entirely. Only the source
		// returned by the provider authorizes using the validated system size;
		// custom/shared/Marketplace images still need explicit disk mappings.
		if i.ImageOwnerAlias == "system" {
			return nil
		}
		return errors.New("模板镜像缺少磁盘映射信息，无法确认单系统盘配置")
	}
	if len(i.DiskDeviceMappings.DiskDeviceMapping) != 1 || i.DiskDeviceMappings.DiskDeviceMapping[0].Type == "data" {
		return errors.New("模板镜像必须仅包含一块系统盘，不允许附带数据盘")
	}
	mapping := i.DiskDeviceMappings.DiskDeviceMapping[0]
	// Official public-image responses can omit Type on the sole system-disk
	// mapping. Only infer it for the provider-reported system source; custom,
	// shared and Marketplace images still require an explicit system type.
	// https://docs-aliyun.cn-hangzhou.oss.aliyun-inc.com/pdf/ecs-open-api-intl-en-2016-09-14.pdf#page=137
	if mapping.Type != "system" && !(i.ImageOwnerAlias == "system" && mapping.Type == "") {
		return errors.New("模板镜像磁盘类型无法确认，已停止创建")
	}
	mappingSize, e := strconv.Atoi(mapping.Size)
	if e != nil || mappingSize < 1 || mappingSize != i.Size || mappingSize > t.DiskGB {
		return errors.New("模板镜像系统盘映射与容量不匹配")
	}
	return nil
}

var errPreparationPending = errors.New("云资源仍在准备中，尚未提交服务器购买；请稍后重试查询确认")

func waitPreparation(ctx context.Context, check func(context.Context) (bool, error)) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		if ctx.Err() != nil {
			return errPreparationPending
		}
		ready, e := check(ctx)
		if ctx.Err() != nil {
			return errPreparationPending
		}
		if e != nil || ready {
			return e
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return errPreparationPending
		case <-timer.C:
		}
	}
}
func awaitID(ctx context.Context, lookup func(context.Context) (string, error), expected string, mutation error) (string, error) {
	id := ""
	e := waitPreparation(ctx, func(ctx context.Context) (bool, error) {
		found, e := lookup(ctx)
		if e != nil {
			return false, e
		}
		if found == "" {
			if definiteNetworkRejection(mutation) {
				return false, mutation
			}
			return false, nil
		}
		if expected != "" && found != expected {
			return false, errors.New("云资源与创建响应标识不匹配，请在控制台核对")
		}
		id = found
		return true, nil
	})
	return id, e
}
func lookupKey(ctx context.Context, api caller, region, name string, key ssh.PublicKey) (string, error) {
	type pair struct{ KeyPairName, PublicKey string }
	rows, _, e := pages[pair](ctx, api, "ecs", region, "DescribeKeyPairs", "KeyPairs", "KeyPair", params("KeyPairName", name, "IncludePublicKey", "true"))
	if e != nil {
		return "", e
	}
	if len(rows) > 1 {
		return "", errors.New("同名云资源不唯一，请在控制台核对")
	}
	if len(rows) == 0 {
		return "", nil
	}
	p := rows[0]
	parsed, e := publicKey(p.PublicKey)
	if e != nil || p.KeyPairName != name || keyName(parsed) != name || (key != nil && !bytes.Equal(parsed.Marshal(), key.Marshal())) {
		return "", errors.New("同名云 SSH 密钥内容不匹配，已停止创建")
	}
	return name, nil
}
func ensureKey(ctx context.Context, api caller, region string, key ssh.PublicKey) (string, error) {
	name := keyName(key)
	lookup := func(ctx context.Context) (string, error) { return lookupKey(ctx, api, region, name, key) }
	id, e := lookup(ctx)
	if e != nil || id != "" {
		return id, e
	}
	p := params("KeyPairName", name, "PublicKeyBody", strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))))
	addTags(p, []tag{{managedTag, managedValue}})
	var out struct{ KeyPairName string }
	mutation := api.call(ctx, "ecs", "ImportKeyPair", region, p, &out)
	if mutation == nil && out.KeyPairName != name {
		return "", errors.New("云 SSH 密钥导入结果异常，请在控制台核对")
	}
	return awaitID(ctx, lookup, name, mutation)
}
func prepare(ctx context.Context, api caller, t Template, in Input) (Prepared, error) {
	if !matches(`^vpc-[a-z0-9]+$`, in.VpcID) {
		return Prepared{}, preparationError("共享 VPC 复核", errors.New("共享网络操作记录无效"))
	}
	key, e := publicKey(in.PublicKey)
	if e != nil {
		return Prepared{}, preparationError("SSH 公钥检查", e)
	}
	prepareMu.Lock()
	defer prepareMu.Unlock()
	v, e := lookupVpc(ctx, api, t.Region, in.VpcID)
	if e != nil {
		return Prepared{}, preparationError("共享 VPC 复核", e)
	}
	if v == nil || v.Status != "Available" {
		return Prepared{}, preparationError("共享 VPC 复核", errNetworkNotVisible)
	}
	if e = preflightImage(ctx, api, t); e != nil {
		return Prepared{}, preparationError("镜像检查", e)
	}
	keyID, e := ensureKey(ctx, api, t.Region, key)
	if e != nil {
		return Prepared{}, preparationError("SSH 公钥准备", e)
	}
	group, e := ensureGroup(ctx, api, t, in.VpcID)
	if e != nil {
		return Prepared{}, preparationError("安全组准备", e)
	}
	return Prepared{group, keyID}, nil
}

type permission struct {
	SecurityGroupRuleID                                                                                                                                                                                                         string `json:"SecurityGroupRuleId"`
	Direction, IpProtocol, PortRange, SourceCidrIp, DestCidrIp, Ipv6SourceCidrIp, Ipv6DestCidrIp, SourceGroupId, DestGroupId, SourcePrefixListId, DestPrefixListId, SourcePortRange, PortRangeListId, Policy, NicType, Priority string
}

func (p *permission) UnmarshalJSON(data []byte) error {
	type fields permission
	var decoded struct {
		fields
		Priority json.RawMessage
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	// The documented representation is a string. Also accept an equivalent
	// integer token, but never coerce other rule fields or broaden the range.
	raw := bytes.TrimSpace(decoded.Priority)
	priority := string(raw)
	if len(raw) > 0 && raw[0] == '"' {
		if err := json.Unmarshal(raw, &priority); err != nil {
			return err
		}
	}
	if !matches(`^(?:[1-9][0-9]?|100)$`, priority) {
		return &json.UnmarshalTypeError{Value: "invalid priority", Type: reflect.TypeFor[string](), Field: "Priority"}
	}
	decoded.fields.Priority = priority
	*p = permission(decoded.fields)
	return nil
}

func ruleKey(p permission) string {
	return strings.ToLower(p.Direction) + "|" + strings.ToLower(p.IpProtocol) + "|" + p.PortRange + "|" + p.SourceCidrIp + "|" + p.DestCidrIp + "|" + p.Ipv6DestCidrIp
}
func requiredRules() []permission {
	return []permission{
		{Direction: "ingress", IpProtocol: "tcp", PortRange: "22/22", SourceCidrIp: "0.0.0.0/0"},
		{Direction: "ingress", IpProtocol: "tcp", PortRange: "20001/20001", SourceCidrIp: "0.0.0.0/0"},
		{Direction: "egress", IpProtocol: "all", PortRange: "-1/-1", DestCidrIp: "0.0.0.0/0"},
	}
}
func missingRules(actual []permission) ([]permission, error) {
	wanted := map[string]permission{}
	for _, p := range requiredRules() {
		wanted[ruleKey(p)] = p
	}
	// The provider may return its default unrestricted IPv6 egress policy.
	ipv6 := ruleKey(permission{Direction: "egress", IpProtocol: "all", PortRange: "-1/-1", Ipv6DestCidrIp: "::/0"})
	seen := map[string]bool{}
	for _, p := range actual {
		k := ruleKey(p)
		if p.Policy != "Accept" || p.NicType != "intranet" || p.SourceGroupId != "" || p.DestGroupId != "" || p.SourcePrefixListId != "" || p.DestPrefixListId != "" || p.Ipv6SourceCidrIp != "" || p.PortRangeListId != "" || (p.SourcePortRange != "" && p.SourcePortRange != "-1/-1") || !matches(`^(?:[1-9][0-9]?|100)$`, p.Priority) || seen[k] {
			return nil, errors.New("同名安全组包含模板以外的规则，请在控制台核对")
		}
		seen[k] = true
		if _, ok := wanted[k]; !ok && k != ipv6 {
			return nil, errors.New("同名安全组规则已改变，请在控制台核对")
		}
		delete(wanted, k)
	}
	var missing []permission
	for _, p := range requiredRules() {
		if _, ok := wanted[ruleKey(p)]; ok {
			missing = append(missing, p)
		}
	}
	return missing, nil
}
func readRules(ctx context.Context, api caller, t Template, vpc, id string) ([]permission, error) {
	var all []permission
	next := ""
	seen := map[string]bool{}
	for {
		p := params("SecurityGroupId", id, "Direction", "all", "MaxResults", "1000")
		if next != "" {
			p.Set("NextToken", next)
		}
		var out struct {
			SecurityGroupID                                              string `json:"SecurityGroupId"`
			VpcID                                                        string `json:"VpcId"`
			SecurityGroupName, Description, InnerAccessPolicy, NextToken string
			Permissions                                                  *struct{ Permission *[]permission }
		}
		if e := api.call(ctx, "ecs", "DescribeSecurityGroupAttribute", t.Region, p, &out); e != nil {
			return nil, e
		}
		if out.SecurityGroupID != id || out.VpcID != vpc || out.SecurityGroupName != groupName || out.Description != groupDescription || out.InnerAccessPolicy != "Accept" || out.Permissions == nil || out.Permissions.Permission == nil || len(*out.Permissions.Permission) > 1000 || len(all)+len(*out.Permissions.Permission) > 4096 {
			return nil, errors.New("安全组规则响应不完整或归属不匹配，已停止操作")
		}
		all = append(all, (*out.Permissions.Permission)...)
		if out.NextToken == "" {
			break
		}
		if seen[out.NextToken] || len(*out.Permissions.Permission) == 0 || len(out.NextToken) > 2048 {
			return nil, errors.New("安全组分页响应异常，已停止操作")
		}
		seen[out.NextToken] = true
		next = out.NextToken
	}
	if _, e := missingRules(all); e != nil {
		return nil, e
	}
	return all, nil
}
func reconcileRules(ctx context.Context, api caller, t Template, vpc, id string, allowAdd bool) error {
	actual, e := readRules(ctx, api, t, vpc, id)
	if e != nil {
		return e
	}
	missing, e := missingRules(actual)
	if e != nil {
		return e
	}
	if !allowAdd && len(missing) > 0 {
		return errors.New("安全组规则未完成，请重试准备操作")
	}
	for _, rule := range missing {
		p := params("SecurityGroupId", id, "Permissions.1.IpProtocol", rule.IpProtocol, "Permissions.1.PortRange", rule.PortRange, "Permissions.1.NicType", "intranet", "Permissions.1.Policy", "accept", "Permissions.1.Priority", "1")
		action := "AuthorizeSecurityGroup"
		if rule.Direction == "ingress" {
			p.Set("Permissions.1.SourceCidrIp", rule.SourceCidrIp)
		} else {
			action = "AuthorizeSecurityGroupEgress"
			p.Set("Permissions.1.DestCidrIp", rule.DestCidrIp)
		}
		var out struct{ RequestId string }
		mutation := api.call(ctx, "ecs", action, t.Region, p, &out)
		e = waitPreparation(ctx, func(ctx context.Context) (bool, error) {
			actual, e := readRules(ctx, api, t, vpc, id)
			if e != nil {
				return false, e
			}
			remaining, e := missingRules(actual)
			if e != nil {
				return false, e
			}
			for _, r := range remaining {
				if ruleKey(r) == ruleKey(rule) {
					if definiteNetworkRejection(mutation) {
						return false, mutation
					}
					return false, nil
				}
			}
			return true, nil
		})
		if e != nil {
			return e
		}
	}
	if allowAdd {
		return reconcileRules(ctx, api, t, vpc, id, false)
	}
	return nil
}
func ensureGroup(ctx context.Context, api caller, t Template, vpc string) (string, error) {
	lookup := func(ctx context.Context) (string, error) {
		type group struct {
			SecurityGroupID                                          string `json:"SecurityGroupId"`
			SecurityGroupName, Description, VpcId, SecurityGroupType string
			Tags                                                     struct {
				Tag []struct{ TagKey, TagValue string }
			}
		}
		rows, _, e := tokenPages[group](ctx, api, "ecs", t.Region, "DescribeSecurityGroups", "SecurityGroups", "SecurityGroup", params("VpcId", vpc, "SecurityGroupName", groupName))
		if e != nil {
			return "", e
		}
		id := ""
		for _, g := range rows {
			if !matches(`^sg-[a-z0-9]+$`, g.SecurityGroupID) || g.SecurityGroupName == "" {
				return "", errors.New("同名安全组不是本应用的匹配配置，已停止创建")
			}
			if g.SecurityGroupName != groupName {
				continue
			}
			tags := []tag{}
			for _, t := range g.Tags.Tag {
				tags = append(tags, tag{t.TagKey, t.TagValue})
			}
			if id != "" || g.Description != groupDescription || g.VpcId != vpc || g.SecurityGroupType != "normal" || !hasTag(tags, managedTag, managedValue) || !matches(`^sg-[a-z0-9]+$`, g.SecurityGroupID) {
				return "", errors.New("同名安全组不是本应用的匹配配置，已停止创建")
			}
			id = g.SecurityGroupID
		}
		return id, nil
	}
	id, e := lookup(ctx)
	if e != nil {
		return "", e
	}
	if id == "" {
		p := params("SecurityGroupName", groupName, "Description", groupDescription, "VpcId", vpc, "SecurityGroupType", "normal")
		addTags(p, []tag{{managedTag, managedValue}})
		var out struct{ SecurityGroupId string }
		mutation := api.call(ctx, "ecs", "CreateSecurityGroup", t.Region, p, &out)
		expected := ""
		if matches(`^sg-[a-z0-9]+$`, out.SecurityGroupId) {
			expected = out.SecurityGroupId
		} else if mutation == nil {
			return "", errors.New("安全组创建结果异常，请在控制台核对")
		}
		id, e = awaitID(ctx, lookup, expected, mutation)
		if e != nil {
			return "", e
		}
	}
	if e = reconcileRules(ctx, api, t, vpc, id, true); e != nil {
		return "", e
	}
	return id, nil
}
func create(ctx context.Context, api caller, t Template, in Input) (Created, error) {
	if !tokenPattern.MatchString(in.ClientToken) || !matches(`^sg-[a-z0-9]+$`, in.SecurityGroupID) || !matches(`^misaka_[a-f0-9]{24}$`, in.KeyID) || !textOK(in.InstanceName, 60) || !matches(`^vpc-[a-z0-9]+$`, in.VpcID) || !matches(`^vsw-[a-z0-9]+$`, in.SubnetID) {
		return Created{}, errors.New("阿里云创建操作记录不完整")
	}
	if e := preflightImage(ctx, api, t); e != nil {
		return Created{}, e
	}
	if e := verifyNetworkForPurchase(ctx, api, t, in); e != nil {
		return Created{}, e
	}
	if e := reconcileRules(ctx, api, t, in.VpcID, in.SecurityGroupID, false); e != nil {
		return Created{}, e
	}
	key, e := lookupKey(ctx, api, t.Region, in.KeyID, nil)
	if e != nil {
		return Created{}, e
	}
	if key == "" {
		return Created{}, errors.New("云 SSH 密钥尚未可见，已停止购买")
	}
	r := t.RunInstances
	p := params("ZoneId", r.ZoneID, "InstanceType", r.InstanceType, "ImageId", r.ImageID, "SystemDisk.Category", r.SystemDisk.Category, "SystemDisk.Size", strconv.Itoa(r.SystemDisk.Size), "InternetChargeType", "PayByTraffic", "InternetMaxBandwidthOut", strconv.Itoa(r.InternetMaxBandwidthOut), "InstanceChargeType", "PostPaid", "SpotStrategy", "NoSpot", "Amount", "1", "MinAmount", "1", "ClientToken", in.ClientToken, "InstanceName", in.InstanceName, "SecurityGroupId", in.SecurityGroupID, "KeyPairName", in.KeyID, "VSwitchId", in.SubnetID, "ImageOptions.LoginAsNonRoot", strconv.FormatBool(t.SSHUsername == "ecs-user"), "PasswordInherit", "false", "DeletionProtection", "false")
	// Explicit categories avoid provider default changes. Disable optional paid
	// cloud_auto bursting; ESSD uses the fixed baseline performance tier.
	if r.SystemDisk.Category == "cloud_auto" {
		p.Set("SystemDisk.BurstingEnabled", "false")
		p.Set("SystemDisk.ProvisionedIops", "0")
	}
	if r.SystemDisk.Category == "cloud_essd" {
		p.Set("SystemDisk.PerformanceLevel", "PL1")
	}
	addTags(p, []tag{{managedTag, managedValue}, {operationTag, in.ClientToken}})
	var out struct {
		RequestId      string
		InstanceIdSets *struct{ InstanceIdSet []string }
	}
	if e = api.call(ctx, "ecs", "RunInstances", t.Region, p, &out); e != nil {
		if zoneUnavailable(e) {
			return Created{State: "unavailable"}, nil
		}
		return Created{}, e
	}
	if out.InstanceIdSets == nil || len(out.InstanceIdSets.InstanceIdSet) != 1 || !instancePattern.MatchString(out.InstanceIdSets.InstanceIdSet[0]) {
		return Created{}, errors.New("云服务器创建返回结果异常，请按操作记录查询核对，勿重复购买")
	}
	return Created{InstanceID: out.InstanceIdSets.InstanceIdSet[0], RequestID: out.RequestId}, nil
}

type instance struct {
	InstanceId, Status, InstanceChargeType, SpotStrategy, InstanceNetworkType string
	Tags                                                                      struct {
		Tag []struct{ TagKey, TagValue string }
	}
	PublicIpAddress   struct{ IpAddress []string }
	EipAddress        struct{ AllocationId, IpAddress string }
	NetworkInterfaces *struct {
		NetworkInterface []struct{ NetworkInterfaceId, Type string }
	}
}

func query(ctx context.Context, api caller, in Input, recover bool) (*instance, string, error) {
	p := params()
	if recover {
		addTags(p, []tag{{managedTag, managedValue}, {operationTag, in.ClientToken}})
	} else {
		b, _ := json.Marshal([]string{in.InstanceID})
		p.Set("InstanceIds", string(b))
	}
	rows, rid, e := tokenPages[instance](ctx, api, "ecs", in.Region, "DescribeInstances", "Instances", "Instance", p)
	if e != nil {
		return nil, "", e
	}
	if len(rows) > 1 {
		return nil, "", errors.New("实例查询结果不唯一，请在阿里云控制台核对")
	}
	if len(rows) == 0 {
		return nil, rid, nil
	}
	i := rows[0]
	tags := []tag{}
	for _, t := range i.Tags.Tag {
		tags = append(tags, tag{t.TagKey, t.TagValue})
	}
	if !instancePattern.MatchString(i.InstanceId) || (!recover && i.InstanceId != in.InstanceID) || !hasTag(tags, managedTag, managedValue) || !hasTag(tags, operationTag, in.ClientToken) {
		return nil, "", errors.New("云服务器与本地创建记录不匹配，已停止操作")
	}
	return &i, rid, nil
}
func describe(ctx context.Context, api caller, in Input, recover bool) (Status, error) {
	i, rid, e := query(ctx, api, in, recover)
	if e != nil {
		return Status{}, e
	}
	if i == nil {
		return Status{InstanceID: in.InstanceID, RequestID: rid}, nil
	}
	state := strings.ToUpper(i.Status)
	switch state {
	case "PENDING", "RUNNING", "STARTING", "STOPPING", "STOPPED":
	default:
		return Status{}, errors.New("云服务器状态格式异常")
	}
	ip := ""
	for _, v := range i.PublicIpAddress.IpAddress {
		a, e := netip.ParseAddr(v)
		if e == nil && a.Is4() && a.IsGlobalUnicast() && !a.IsPrivate() {
			ip = a.String()
			break
		}
	}
	return Status{i.InstanceId, state, ip, rid, true}, nil
}
func release(ctx context.Context, api caller, in Input) (Released, error) {
	i, rid, e := query(ctx, api, in, false)
	if e != nil {
		return Released{}, e
	}
	if i == nil {
		return Released{rid}, nil
	}
	if i.InstanceChargeType != "PostPaid" || i.SpotStrategy != "NoSpot" || i.InstanceNetworkType != "vpc" {
		return Released{}, errors.New("仅允许释放本应用创建的普通按量 VPC 云服务器")
	}
	if i.NetworkInterfaces != nil {
		interfaces := i.NetworkInterfaces.NetworkInterface
		if len(interfaces) != 1 || interfaces[0].Type != "Primary" || !matches(`^eni-[a-z0-9]+$`, interfaces[0].NetworkInterfaceId) {
			return Released{}, errors.New("云服务器网卡配置已改变或不完整，请先在阿里云控制台核对和处理")
		}
	}
	if i.EipAddress.AllocationId != "" || i.EipAddress.IpAddress != "" {
		return Released{}, errors.New("云服务器关联了独立弹性公网 IP，请先在阿里云控制台核对和处理")
	}
	type disk struct {
		DiskId, InstanceId, Type, Status string
		DeleteWithInstance               *bool
	}
	disks, _, e := tokenPages[disk](ctx, api, "ecs", in.Region, "DescribeDisks", "Disks", "Disk", params("InstanceId", in.InstanceID))
	if e != nil {
		return Released{}, e
	}
	if len(disks) != 1 || !matches(`^d-[a-z0-9]+$`, disks[0].DiskId) || disks[0].InstanceId != in.InstanceID || disks[0].Type != "system" || disks[0].DeleteWithInstance == nil || !*disks[0].DeleteWithInstance {
		return Released{}, errors.New("云服务器磁盘不符合随实例释放的单系统盘配置，请先在阿里云控制台核对和处理")
	}
	switch i.Status {
	case "Running", "Stopped":
	default:
		return Released{}, errors.New("云服务器仍在变更状态，请稍后查询再释放")
	}
	var out struct{ RequestId string }
	if e = api.call(ctx, "ecs", "DeleteInstance", in.Region, params("InstanceId", in.InstanceID, "Force", "true", "ForceStop", "false"), &out); e != nil {
		return Released{}, e
	}
	return Released{out.RequestId}, nil
}
