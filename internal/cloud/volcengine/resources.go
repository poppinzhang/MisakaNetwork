package volcengine

import (
	"bytes"
	"context"
	"crypto/rsa"
	"errors"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
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
	EipID      string `json:"eip_id"`
	State      string `json:"state"`
	PublicIP   string `json:"public_ip"`
	RequestID  string `json:"request_id"`
	Exists     bool   `json:"exists"`
}
type Released struct {
	RequestID string `json:"request_id"`
	EipID     string `json:"eip_id"`
}
type instance struct {
	InstanceID                 string `json:"InstanceId"`
	Status, InstanceChargeType string
	Tags                       []tag
	EipAddress                 struct {
		AllocationID string `json:"AllocationId"`
		IpAddress    string
	}
	Volumes []struct {
		VolumeID string `json:"VolumeId"`
	}
}
type eip struct {
	AllocationID                                              string `json:"AllocationId"`
	InstanceID                                                string `json:"InstanceId"`
	InstanceType, Status, EipAddress, ISP, BandwidthPackageID string
	BillingType                                               int
	ReleaseWithInstance                                       *bool
}

func hasTag(tags []tag, key, value string) bool {
	count := 0
	for _, t := range tags {
		if t.Key == key {
			if t.Value != value {
				return false
			}
			count++
		}
	}
	return count == 1
}
func publicKey(value string) (ssh.PublicKey, error) {
	k, _, opts, rest, e := ssh.ParseAuthorizedKey([]byte(value))
	if e != nil || len(opts) != 0 || len(bytes.TrimSpace(rest)) != 0 || k.Type() != ssh.KeyAlgoRSA {
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
func preflightImage(ctx context.Context, api caller, t Template) error {
	type image struct {
		ImageID                      string `json:"ImageId"`
		OsType, Status, Architecture string
		Size                         int
		Snapshots                    []struct{ VolumeKind string }
	}
	rows, e := pages[image](ctx, api, "ecs", t.Region, "DescribeImages", "Images", params("ImageIds.1", t.RunInstances.ImageID))
	if e != nil {
		return e
	}
	// The API does not document which visibility categories an omitted selector
	// covers. Resolve the selected ID in each documented category after an empty
	// default result; never turn a failed or contradictory lookup into a fallback.
	// https://docs.volcengine.com/docs/ecs/DescribeImages-Queriesimages?lang=en
	for _, visibility := range []string{"public", "private", "shared"} {
		if len(rows) != 0 {
			break
		}
		rows, e = pages[image](ctx, api, "ecs", t.Region, "DescribeImages", "Images", params("ImageIds.1", t.RunInstances.ImageID, "Visibility", visibility))
		if e != nil {
			return e
		}
	}
	if len(rows) != 1 {
		return errors.New("模板镜像不存在或无权访问")
	}
	i := rows[0]
	arch := "amd64"
	if t.Architecture == "arm64" {
		arch = "arm64"
	}
	if i.ImageID != t.RunInstances.ImageID || i.Status != "available" || i.Architecture != arch || i.OsType != "Linux" || i.Size < 1 || i.Size > t.DiskGB {
		return errors.New("模板镜像必须是可用的 Linux 镜像，架构与系统盘须匹配")
	}
	for _, snapshot := range i.Snapshots {
		if len(i.Snapshots) != 1 || snapshot.VolumeKind != "system" {
			return errors.New("模板镜像不允许附带数据盘")
		}
	}
	return nil
}

var errPreparationPending = errors.New("云资源仍在准备中，请稍后重试查询确认")

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
		if ready || e != nil {
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
func prepare(ctx context.Context, api caller, t Template, in Input) (Prepared, error) {
	k, e := publicKey(in.PublicKey)
	if e != nil {
		return Prepared{}, preparationError("SSH 公钥检查", e)
	}
	if !matches(`^vpc-[a-z0-9]+$`, in.VpcID) {
		return Prepared{}, preparationError("共享 VPC 复核", errors.New("云资源准备缺少已确认的 VPC"))
	}
	prepareMu.Lock()
	defer prepareMu.Unlock()
	if e = preflightImage(ctx, api, t); e != nil {
		return Prepared{}, preparationError("镜像检查", e)
	}
	v, e := lookupVpc(ctx, api, t.Region, in.VpcID)
	if e != nil {
		return Prepared{}, preparationError("共享 VPC 复核", e)
	}
	if v == nil || v.Status != "Available" {
		return Prepared{}, preparationError("共享 VPC 复核", errNetworkNotVisible)
	}
	key, e := ensureKey(ctx, api, t.Region, k)
	if e != nil {
		return Prepared{}, preparationError("SSH 公钥准备", e)
	}
	group, e := ensureGroup(ctx, api, t, in.VpcID)
	return Prepared{SecurityGroupID: group, KeyID: key}, preparationError("安全组准备", e)
}
func cloudKeyName(k ssh.PublicKey) string { return "misaka-" + sha(k.Marshal())[:32] }
func normalizedMD5(s string) string {
	return strings.ReplaceAll(strings.TrimPrefix(strings.ToLower(s), "md5:"), ":", "")
}
func ensureKey(ctx context.Context, api caller, region string, k ssh.PublicKey) (string, error) {
	name := cloudKeyName(k)
	finger := normalizedMD5(ssh.FingerprintLegacyMD5(k))
	lookup := func(ctx context.Context) (bool, error) {
		type key struct {
			KeyPairID                string `json:"KeyPairId"`
			KeyPairName, FingerPrint string
			Tags                     []tag
		}
		rows, e := pages[key](ctx, api, "ecs", region, "DescribeKeyPairs", "KeyPairs", params("KeyPairNames.1", name))
		if e != nil {
			return false, e
		}
		if len(rows) > 1 {
			return false, errors.New("同名云密钥不唯一，请在控制台核对")
		}
		if len(rows) == 0 {
			return false, nil
		}
		x := rows[0]
		if x.KeyPairName != name || !matches(`^kp-[a-z0-9]+$`, x.KeyPairID) || normalizedMD5(x.FingerPrint) != finger || !hasTag(x.Tags, managedTag, managedValue) {
			return false, errors.New("同名云密钥的归属或指纹不匹配")
		}
		return true, nil
	}
	found, e := lookup(ctx)
	if e != nil || found {
		return name, e
	}
	q := params("KeyPairName", name, "PublicKey", strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k))), "ClientToken", sha([]byte("ImportKeyPair\n"+region+"\n"+name)))
	addTags(q, []tag{{managedTag, managedValue}})
	var out struct{ KeyPairName, FingerPrint string }
	mutationErr := api.call(ctx, "ecs", "ImportKeyPair", region, q, &out)
	if mutationErr == nil && (out.KeyPairName != name || normalizedMD5(out.FingerPrint) != finger) {
		return "", errors.New("SSH 密钥导入响应异常，请在控制台核对")
	}
	e = waitPreparation(ctx, func(ctx context.Context) (bool, error) {
		ok, e := lookup(ctx)
		if e == nil && !ok && definiteNetworkRejection(mutationErr) {
			return false, mutationErr
		}
		return ok, e
	})
	return name, e
}

type policy struct {
	Direction, Protocol, Policy, CidrIp, SourceGroupID, PrefixListID, LocalCidrIp string
	Priority, PortStart, PortEnd                                                  int
	SourcePortStart, SourcePortEnd                                                *int
}
type group struct {
	SecurityGroupID                                     string `json:"SecurityGroupId"`
	SecurityGroupName, Description, VpcID, Status, Type string
	ServiceManaged                                      bool
	Tags                                                []tag
	Permissions                                         *[]policy
}

func policyKey(p policy) string {
	return p.Direction + "|" + strings.ToLower(p.Protocol) + "|" + p.CidrIp + "|" + p.SourceGroupID + "|" + strconv.Itoa(p.PortStart) + "|" + strconv.Itoa(p.PortEnd) + "|" + strconv.Itoa(p.Priority)
}
func requiredPolicies() []policy {
	return []policy{{Direction: "ingress", Protocol: "tcp", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 1, PortStart: 22, PortEnd: 22}, {Direction: "ingress", Protocol: "tcp", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 1, PortStart: 20001, PortEnd: 20001}, {Direction: "egress", Protocol: "all", Policy: "accept", CidrIp: "0.0.0.0/0", Priority: 100, PortStart: -1, PortEnd: -1}}
}

// Volcengine automatically adds same-group ingress and IPv6 egress. Accept only
// these documented defaults in addition to our fixed rules, never arbitrary
// pre-existing wider ingress or referenced groups.
func missingPolicies(actual []policy, id string) ([]policy, error) {
	wanted := map[string]policy{}
	for _, p := range requiredPolicies() {
		wanted[policyKey(p)] = p
	}
	allowed := map[string]bool{}
	for k := range wanted {
		allowed[k] = true
	}
	for _, p := range []policy{{Direction: "egress", Protocol: "all", Policy: "accept", CidrIp: "::/0", Priority: 100, PortStart: -1, PortEnd: -1}, {Direction: "ingress", Protocol: "all", Policy: "accept", SourceGroupID: id, Priority: 1, PortStart: -1, PortEnd: -1}} {
		allowed[policyKey(p)] = true
	}
	seen := map[string]bool{}
	for _, p := range actual {
		k := policyKey(p)
		if !allowed[k] || seen[k] || p.Policy != "accept" || p.PrefixListID != "" || p.LocalCidrIp != "" || (p.SourcePortStart != nil && *p.SourcePortStart != -1) || (p.SourcePortEnd != nil && *p.SourcePortEnd != -1) {
			return nil, errors.New("安全组规则与固定策略不匹配，请在控制台核对")
		}
		seen[k] = true
		delete(wanted, k)
	}
	var missing []policy
	for _, p := range requiredPolicies() {
		if _, ok := wanted[policyKey(p)]; ok {
			missing = append(missing, p)
		}
	}
	return missing, nil
}
func verifyGroup(g group, vpcID string) error {
	if !matches(`^sg-[a-z0-9]+$`, g.SecurityGroupID) || g.VpcID != vpcID || g.SecurityGroupName != groupName || g.Description != groupDescription || g.Type != "normal" || g.ServiceManaged || !hasTag(g.Tags, managedTag, managedValue) {
		return errors.New("安全组归属或配置与项目不匹配")
	}
	return nil
}
func readPolicies(ctx context.Context, api caller, t Template, vpcID, id string) ([]policy, error) {
	var g group
	if e := api.call(ctx, "vpc", "DescribeSecurityGroupAttributes", t.Region, params("SecurityGroupId", id), &g); e != nil {
		return nil, e
	}
	if e := verifyGroup(g, vpcID); e != nil {
		return nil, e
	}
	if g.SecurityGroupID != id {
		return nil, errors.New("安全组查询响应不完整")
	}
	if g.Status == "Creating" {
		return nil, errPreparationPending
	}
	if g.Status != "Available" || g.Permissions == nil {
		return nil, errors.New("安全组查询响应不完整")
	}
	return missingPolicies(*g.Permissions, id)
}
func ensureGroup(ctx context.Context, api caller, t Template, vpcID string) (string, error) {
	lookup := func(ctx context.Context) (string, error) {
		rows, e := pages[group](ctx, api, "vpc", t.Region, "DescribeSecurityGroups", "SecurityGroups", params("VpcId", vpcID, "SecurityGroupNames.1", groupName))
		if e != nil {
			return "", e
		}
		if len(rows) > 1 {
			return "", errors.New("同名安全组不唯一，请在控制台核对")
		}
		if len(rows) == 0 {
			return "", nil
		}
		if e := verifyGroup(rows[0], vpcID); e != nil {
			return "", e
		}
		return rows[0].SecurityGroupID, nil
	}
	id, e := lookup(ctx)
	if e != nil {
		return "", e
	}
	if id == "" {
		q := params("VpcId", vpcID, "SecurityGroupName", groupName, "Description", groupDescription, "ClientToken", sha([]byte("CreateSecurityGroup\n"+t.Region+"\n"+vpcID+"\n"+groupName)))
		addTags(q, []tag{{managedTag, managedValue}})
		var out struct {
			SecurityGroupID string `json:"SecurityGroupId"`
		}
		mutationErr := api.call(ctx, "vpc", "CreateSecurityGroup", t.Region, q, &out)
		e = waitPreparation(ctx, func(ctx context.Context) (bool, error) {
			var e error
			id, e = lookup(ctx)
			if e != nil {
				return false, e
			}
			if id == "" && definiteNetworkRejection(mutationErr) {
				return false, mutationErr
			}
			if id != "" && out.SecurityGroupID != "" && id != out.SecurityGroupID {
				return false, errors.New("安全组创建结果与查询不符")
			}
			return id != "", nil
		})
		if e != nil {
			return "", e
		}
	}
	var missing []policy
	e = waitPreparation(ctx, func(ctx context.Context) (bool, error) {
		var e error
		missing, e = readPolicies(ctx, api, t, vpcID, id)
		if errors.Is(e, errPreparationPending) {
			return false, nil
		}
		return e == nil, e
	})
	if e != nil {
		return "", e
	}
	for _, p := range missing {
		action := "AuthorizeSecurityGroupIngress"
		if p.Direction == "egress" {
			action = "AuthorizeSecurityGroupEgress"
		}
		q := params("SecurityGroupId", id, "Protocol", p.Protocol, "PortStart", strconv.Itoa(p.PortStart), "PortEnd", strconv.Itoa(p.PortEnd), "CidrIp", p.CidrIp, "Policy", "accept", "Priority", strconv.Itoa(p.Priority))
		q.Set("ClientToken", sha([]byte(action+"\n"+t.Region+"\n"+q.Encode())))
		var out struct{}
		mutationErr := api.call(ctx, "vpc", action, t.Region, q, &out)
		e = waitPreparation(ctx, func(ctx context.Context) (bool, error) {
			remaining, e := readPolicies(ctx, api, t, vpcID, id)
			if errors.Is(e, errPreparationPending) {
				return false, nil
			}
			if e != nil {
				return false, e
			}
			for _, r := range remaining {
				if policyKey(r) == policyKey(p) {
					if definiteNetworkRejection(mutationErr) {
						return false, mutationErr
					}
					return false, nil
				}
			}
			return true, nil
		})
		if e != nil {
			return "", e
		}
	}
	return id, nil
}
func create(ctx context.Context, api caller, t Template, in Input) (Created, error) {
	if !tokenPattern.MatchString(in.ClientToken) || !matches(`^sg-[a-z0-9]+$`, in.SecurityGroupID) || !matches(`^misaka-[a-f0-9]{32}$`, in.KeyID) || !textOK(in.InstanceName, 60) || !matches(`^vpc-[a-z0-9]+$`, in.VpcID) || !matches(`^subnet-[a-z0-9]+$`, in.SubnetID) {
		return Created{}, errors.New("火山引擎创建操作记录不完整")
	}
	if e := preflightImage(ctx, api, t); e != nil {
		return Created{}, e
	}
	if e := verifyNetworkForPurchase(ctx, api, t, in); e != nil {
		return Created{}, e
	}
	missing, e := readPolicies(ctx, api, t, in.VpcID, in.SecurityGroupID)
	if e != nil {
		return Created{}, e
	}
	if len(missing) > 0 {
		return Created{}, errors.New("安全组规则尚未就绪")
	}
	p := t.RunInstances
	q := params("ZoneId", p.ZoneID, "InstanceTypeId", p.InstanceTypeID, "ImageId", p.ImageID, "InstanceName", in.InstanceName, "InstanceChargeType", "PostPaid", "Count", "1", "MinCount", "1", "SpotStrategy", "NoSpot", "ClientToken", in.ClientToken, "KeyPairName", in.KeyID, "KeepImageCredential", "false", "NetworkInterfaces.1.SubnetId", in.SubnetID, "NetworkInterfaces.1.SecurityGroupIds.1", in.SecurityGroupID, "Volumes.1.VolumeType", p.Volumes[0].VolumeType, "Volumes.1.Size", strconv.Itoa(p.Volumes[0].Size), "Volumes.1.DeleteWithInstance", "true", "EipAddress.ChargeType", "PayByTraffic", "EipAddress.ISP", "BGP", "EipAddress.BandwidthMbps", strconv.Itoa(p.EipAddress.BandwidthMbps), "EipAddress.ReleaseWithInstance", "true")
	addTags(q, []tag{{managedTag, managedValue}, {operationTag, in.ClientToken}})
	var out struct {
		InstanceIds []string
		RequestID   string `json:"RequestId"`
	}
	if e := api.call(ctx, "ecs", "RunInstances", t.Region, q, &out); e != nil {
		var refused *capacityRejection
		if errors.As(e, &refused) && len(out.InstanceIds) == 0 {
			return Created{State: "unavailable", RequestID: refused.requestID}, nil
		}
		return Created{}, e
	}
	if len(out.InstanceIds) != 1 || !instancePattern.MatchString(out.InstanceIds[0]) {
		return Created{}, errors.New("云服务器创建返回结果异常，请查询核对，勿重复购买")
	}
	return Created{InstanceID: out.InstanceIds[0], RequestID: out.RequestID}, nil
}
func query(ctx context.Context, api caller, in Input, recover bool) (*instance, error) {
	q := params("InstanceIds.1", in.InstanceID)
	if recover {
		q = params("TagFilters.1.Key", managedTag, "TagFilters.1.Values.1", managedValue, "TagFilters.2.Key", operationTag, "TagFilters.2.Values.1", in.ClientToken)
	}
	rows, e := pages[instance](ctx, api, "ecs", in.Region, "DescribeInstances", "Instances", q)
	if e != nil {
		return nil, e
	}
	if len(rows) > 1 {
		return nil, errors.New("实例查询结果不唯一，请在火山引擎控制台核对")
	}
	if len(rows) == 0 {
		return nil, nil
	}
	i := rows[0]
	if !instancePattern.MatchString(i.InstanceID) || (!recover && i.InstanceID != in.InstanceID) || !hasTag(i.Tags, managedTag, managedValue) || !hasTag(i.Tags, operationTag, in.ClientToken) {
		return nil, errors.New("云服务器与本地创建记录不匹配，已停止操作")
	}
	return &i, nil
}
func queryEip(ctx context.Context, api caller, region, id string) (*eip, error) {
	if !eipPattern.MatchString(id) {
		return nil, errors.New("公网 IP 记录缺失，不能确认联合释放")
	}
	rows, e := pages[eip](ctx, api, "vpc", region, "DescribeEipAddresses", "EipAddresses", params("AllocationIds.1", id))
	if e != nil {
		return nil, e
	}
	if len(rows) > 1 || (len(rows) == 1 && rows[0].AllocationID != id) {
		return nil, errors.New("公网 IP 查询与保存记录不匹配")
	}
	if len(rows) == 0 {
		return nil, nil
	}
	return &rows[0], nil
}
func describe(ctx context.Context, api caller, in Input, recover bool) (Status, error) {
	i, e := query(ctx, api, in, recover)
	if e != nil {
		return Status{}, e
	}
	s := Status{InstanceID: in.InstanceID, EipID: in.EipID}
	if i == nil {
		if !in.ReleaseSubmitted || !eipPattern.MatchString(in.EipID) || !instancePattern.MatchString(in.InstanceID) {
			return s, nil
		}
		address, e := queryEip(ctx, api, in.Region, in.EipID)
		if e != nil {
			return Status{}, e
		}
		s.Exists = true // completion is an explicit state, never inferred from absence.
		if address == nil {
			s.State = "TERMINATED"
		} else if address.Status == "Deleting" || address.Status == "Detaching" {
			s.State = "EIP_RELEASING"
		} else {
			s.State = "EIP_RELEASE_PENDING"
		}
		return s, nil
	}
	if !matches(`^[a-zA-Z_]{1,64}$`, i.Status) {
		return Status{}, errors.New("云服务器状态格式异常")
	}
	s.InstanceID = i.InstanceID
	s.State = strings.ToUpper(i.Status)
	// TERMINATED is our joint-release result, never a provider passthrough.
	// Even a terminal-looking ECS row is insufficient while the row/EIP remain.
	if s.State == "TERMINATED" {
		s.State = "DELETING"
	}
	s.Exists = true
	if i.EipAddress.AllocationID != "" {
		if !eipPattern.MatchString(i.EipAddress.AllocationID) || (in.EipID != "" && in.EipID != i.EipAddress.AllocationID) {
			return Status{}, errors.New("实例公网 IP 与已保存记录不一致，请在控制台核对")
		}
		s.EipID = i.EipAddress.AllocationID
		address, e := queryEip(ctx, api, in.Region, s.EipID)
		if e != nil {
			return Status{}, e
		}
		if address == nil {
			if in.ReleaseSubmitted && in.EipID == s.EipID {
				s.State = "DELETING"
				return s, nil
			}
			return Status{}, errors.New("实例公网 IP 尚未查询确认")
		}
		if in.ReleaseSubmitted && in.EipID == s.EipID && (address.Status == "Deleting" || address.Status == "Detaching") {
			s.State = "EIP_RELEASING"
			return s, nil
		}
		if address.InstanceID != i.InstanceID || address.InstanceType != "EcsInstance" || address.ReleaseWithInstance == nil || !*address.ReleaseWithInstance || address.BillingType != 3 {
			return Status{}, errors.New("公网 IP 绑定、计费或随实例释放属性不匹配")
		}
		ip, e := netip.ParseAddr(i.EipAddress.IpAddress)
		if e == nil && ip.Is4() && ip.IsGlobalUnicast() && !ip.IsPrivate() && address.EipAddress == ip.String() {
			s.PublicIP = ip.String()
		}
	}
	return s, nil
}
func release(ctx context.Context, api caller, in Input) (Released, error) {
	if !eipPattern.MatchString(in.EipID) {
		return Released{}, errors.New("尚未保存公网 IP 记录，请先刷新查询后再释放")
	}
	i, e := query(ctx, api, in, false)
	if e != nil {
		return Released{}, e
	}
	if i == nil {
		if !in.ReleaseSubmitted {
			return Released{}, errors.New("实例查询为空但未提交释放，不能确认资源已释放")
		}
		if _, e := queryEip(ctx, api, in.Region, in.EipID); e != nil {
			return Released{}, e
		}
		return Released{EipID: in.EipID}, nil
	}
	if i.InstanceChargeType != "PostPaid" || i.EipAddress.AllocationID != in.EipID || len(i.Volumes) != 1 || !matches(`^vol-[a-z0-9]+$`, i.Volumes[0].VolumeID) {
		return Released{}, errors.New("实例计费、公网 IP 或挂载磁盘与创建范围不匹配，已停止释放")
	}
	address, e := queryEip(ctx, api, in.Region, in.EipID)
	if e != nil {
		return Released{}, e
	}
	if address == nil || address.InstanceID != in.InstanceID || address.InstanceType != "EcsInstance" || address.BillingType != 3 || address.ReleaseWithInstance == nil || !*address.ReleaseWithInstance {
		return Released{}, errors.New("公网 IP 未确认随本实例释放，已停止释放，请在控制台核对")
	}
	if strings.ToUpper(i.Status) == "DELETING" {
		return Released{EipID: in.EipID}, nil
	}
	var out struct {
		RequestID        string `json:"RequestId"`
		OperationDetails *[]struct {
			InstanceID string `json:"InstanceId"`
			Error      *struct{ Code string }
		}
	}
	q := params("InstanceIds.1", in.InstanceID, "ClientToken", sha([]byte("DeleteInstances\n"+in.ClientToken+"\n"+in.InstanceID)))
	if e := api.call(ctx, "ecs", "DeleteInstances", in.Region, q, &out); e != nil {
		return Released{}, e
	}
	if out.OperationDetails == nil || len(*out.OperationDetails) != 1 || (*out.OperationDetails)[0].InstanceID != in.InstanceID {
		return Released{}, errors.New("释放响应未明确覆盖目标实例，请查询确认")
	}
	if d := (*out.OperationDetails)[0]; d.Error != nil && d.Error.Code != "" {
		return Released{}, &apiError{d.Error.Code}
	}
	return Released{RequestID: out.RequestID, EipID: in.EipID}, nil
}
