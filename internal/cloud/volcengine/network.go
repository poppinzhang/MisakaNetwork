package volcengine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
)

const networkVpcName = "MisakaNetwork-VPC"
const networkVpcCIDR = "10.8.0.0/16"
const networkTag = "misaka-network"
const networkValue = "shared-v1"

var errNetworkResponse = errors.New("火山引擎网络查询结果不完整，请重新查询")
var errNetworkConflict = errors.New("同名共享网络的归属或配置不匹配，请在火山引擎控制台核对")
var errNetworkNotVisible = errors.New("共享网络尚未就绪，请稍后查询确认")

type resourceListError struct{ message string }

func (e *resourceListError) Error() string        { return e.message }
func (e *resourceListError) Is(target error) bool { return target == errNetworkResponse }

var errResourceListMissing = &resourceListError{"火山引擎查询响应缺少资源列表，请重新查询"}
var errResourceListMalformed = &resourceListError{"火山引擎查询资源列表格式异常，请重新查询"}
var errResourcePagination = &resourceListError{"火山引擎查询分页结果不完整，请重新查询"}

// Preparation APIs use optional lists, which can encode an empty result as
// either [] or null. This does not apply to absence checks used for releasing
// instances/EIPs. Missing fields never establish an empty result.
func nullablePreparationList(service, action, key string) bool {
	return service == "vpc" && ((action == "DescribeVpcs" && key == "Vpcs") ||
		(action == "DescribeSubnets" && key == "Subnets") ||
		(action == "DescribeSecurityGroups" && key == "SecurityGroups")) ||
		service == "ecs" && ((action == "DescribeImages" && key == "Images") ||
			(action == "DescribeKeyPairs" && key == "KeyPairs"))
}

type NetworkLookup struct {
	Found      bool   `json:"found"`
	VpcID      string `json:"vpc_id"`
	SubnetID   string `json:"subnet_id"`
	SubnetCIDR string `json:"subnet_cidr"`
}
type NetworkCreated struct {
	State      string `json:"state"`
	VpcID      string `json:"vpc_id"`
	SubnetID   string `json:"subnet_id"`
	SubnetCIDR string `json:"subnet_cidr"`
	Error      string `json:"error,omitempty"`
}
type networkVpc struct {
	VpcID                      string `json:"VpcId"`
	VpcName, CidrBlock, Status string
	IsDefault                  bool
	Tags                       []tag
}
type networkSubnet struct {
	SubnetID                              string `json:"SubnetId"`
	VpcID                                 string `json:"VpcId"`
	SubnetName, ZoneID, CidrBlock, Status string
	IsDefault                             bool
	AvailableIpAddressCount               *int
	Tags                                  []tag
}

func (v networkVpc) resourceID() string    { return v.VpcID }
func (s networkSubnet) resourceID() string { return s.SubnetID }
func params(pairs ...string) url.Values {
	v := url.Values{}
	for i := 0; i < len(pairs); i += 2 {
		v.Set(pairs[i], pairs[i+1])
	}
	return v
}
func addTags(v url.Values, tags []tag) {
	for i, t := range tags {
		prefix := "Tags." + strconv.Itoa(i+1) + "."
		v.Set(prefix+"Key", t.Key)
		v.Set(prefix+"Value", t.Value)
	}
}
func networkTags() []tag { return []tag{{managedTag, managedValue}, {networkTag, networkValue}} }
func isManagedNetwork(tags []tag) bool {
	return hasTag(tags, managedTag, managedValue) && hasTag(tags, networkTag, networkValue)
}
func subnetName(zone string) string { return "MisakaNetwork-Subnet-" + zone }

// Exhaust the documented NextToken pagination. Never treat a truncated or
// malformed list as absence: absence may authorize a network mutation.
func pages[T any](ctx context.Context, api caller, service, region, action, key string, q url.Values) ([]T, error) {
	copy := url.Values{}
	for k, v := range q {
		copy[k] = append([]string(nil), v...)
	}
	q = copy
	q.Set("MaxResults", "100")
	seen := map[string]bool{}
	result := []T{}
	for n := 0; n < 42; n++ {
		var out map[string]json.RawMessage
		if err := api.call(ctx, service, action, region, q, &out); err != nil {
			return nil, err
		}
		var rows []T
		var next string
		if len(out[key]) == 0 {
			return nil, errResourceListMissing
		}
		if (strings.TrimSpace(string(out[key])) == "null" && !nullablePreparationList(service, action, key)) || json.Unmarshal(out[key], &rows) != nil {
			return nil, errResourceListMalformed
		}
		if len(rows) > 100 {
			return nil, errResourcePagination
		}
		if b := out["NextToken"]; len(b) > 0 && json.Unmarshal(b, &next) != nil {
			return nil, errResourcePagination
		}
		result = append(result, rows...)
		if len(result) > 4096 {
			return nil, errResourcePagination
		}
		if next == "" {
			return result, nil
		}
		if seen[next] || len(next) > 8192 || len(rows) == 0 {
			return nil, errResourcePagination
		}
		seen[next] = true
		q.Set("NextToken", next)
	}
	return nil, errResourcePagination
}
func lookupVpc(ctx context.Context, api caller, region, expectedID string) (*networkVpc, error) {
	rows, err := pages[networkVpc](ctx, api, "vpc", region, "DescribeVpcs", "Vpcs", params("VpcName", networkVpcName))
	if err != nil {
		return nil, err
	}
	var found *networkVpc
	for _, row := range rows {
		if !matches(`^vpc-[a-z0-9]+$`, row.VpcID) {
			return nil, errNetworkResponse
		}
		if row.VpcName != networkVpcName {
			continue
		}
		if found != nil || row.IsDefault || row.CidrBlock != networkVpcCIDR || !isManagedNetwork(row.Tags) || (expectedID != "" && row.VpcID != expectedID) {
			return nil, errNetworkConflict
		}
		copy := row
		found = &copy
	}
	return found, nil
}
func subnetPrefix(value string) (netip.Prefix, bool) {
	p, e := netip.ParsePrefix(value)
	v := netip.MustParsePrefix(networkVpcCIDR)
	return p, e == nil && p.Addr().Is4() && p.Masked().String() == value && p.Bits() >= v.Bits() && v.Contains(p.Addr())
}
func lookupSubnet(ctx context.Context, api caller, t Template, vpcID string) (*networkSubnet, []netip.Prefix, error) {
	v, err := lookupVpc(ctx, api, t.Region, vpcID)
	if err != nil {
		return nil, nil, err
	}
	if v == nil || v.Status != "Available" {
		return nil, nil, errNetworkNotVisible
	}
	rows, err := pages[networkSubnet](ctx, api, "vpc", t.Region, "DescribeSubnets", "Subnets", params("VpcId", vpcID))
	if err != nil {
		return nil, nil, err
	}
	var found *networkSubnet
	var occupied []netip.Prefix
	seen := map[string]bool{}
	for _, r := range rows {
		p, valid := subnetPrefix(r.CidrBlock)
		if !valid || r.VpcID != vpcID || !matches(`^subnet-[a-z0-9]+$`, r.SubnetID) || seen[r.SubnetID] {
			return nil, nil, errNetworkResponse
		}
		seen[r.SubnetID] = true
		for _, o := range occupied {
			if p.Overlaps(o) {
				return nil, nil, errNetworkResponse
			}
		}
		occupied = append(occupied, p)
		if r.SubnetName != subnetName(t.RunInstances.ZoneID) {
			continue
		}
		if found != nil || r.IsDefault || r.ZoneID != t.RunInstances.ZoneID || p.Bits() != 24 || !isManagedNetwork(r.Tags) {
			return nil, nil, errNetworkConflict
		}
		copy := r
		found = &copy
	}
	return found, occupied, nil
}
func cidrAvailable(value string, occupied []netip.Prefix) bool {
	p, valid := subnetPrefix(value)
	if !valid || p.Bits() != 24 {
		return false
	}
	for _, o := range occupied {
		if p.Overlaps(o) {
			return false
		}
	}
	return true
}
func plannedSubnetCIDR(occupied []netip.Prefix) (string, error) {
	for i := range 256 {
		c := fmt.Sprintf("10.8.%d.0/24", i)
		if cidrAvailable(c, occupied) {
			return c, nil
		}
	}
	return "", errors.New("共享 VPC 内没有可用的子网地址段")
}
func lookupNetwork(ctx context.Context, api caller, t Template, in Input) (NetworkLookup, error) {
	if in.NetworkKind == "vpc" {
		if in.VpcID != "" && !matches(`^vpc-[a-z0-9]+$`, in.VpcID) {
			return NetworkLookup{}, errNetworkResponse
		}
		v, err := lookupVpc(ctx, api, t.Region, in.VpcID)
		if err != nil || v == nil {
			return NetworkLookup{VpcID: in.VpcID}, err
		}
		if v.Status != "Available" && v.Status != "Creating" && v.Status != "Pending" {
			return NetworkLookup{}, errNetworkResponse
		}
		return NetworkLookup{Found: v.Status == "Available", VpcID: v.VpcID}, nil
	}
	if in.NetworkKind != "subnet" || !matches(`^vpc-[a-z0-9]+$`, in.VpcID) || (in.SubnetID != "" && !matches(`^subnet-[a-z0-9]+$`, in.SubnetID)) || (in.SubnetCIDR != "" && !cidrAvailable(in.SubnetCIDR, nil)) {
		return NetworkLookup{}, errNetworkResponse
	}
	s, occupied, err := lookupSubnet(ctx, api, t, in.VpcID)
	if errors.Is(err, errNetworkNotVisible) {
		return NetworkLookup{VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR}, nil
	}
	if err != nil {
		return NetworkLookup{}, err
	}
	if s != nil {
		if (in.SubnetID != "" && in.SubnetID != s.SubnetID) || (in.SubnetCIDR != "" && in.SubnetCIDR != s.CidrBlock) {
			return NetworkLookup{}, errNetworkConflict
		}
		if s.Status != "Available" && s.Status != "Pending" {
			return NetworkLookup{}, errNetworkResponse
		}
		ready := s.Status == "Available"
		if ready && (s.AvailableIpAddressCount == nil || *s.AvailableIpAddressCount <= 0) {
			return NetworkLookup{}, errors.New("共享子网可用地址不足或未确认")
		}
		return NetworkLookup{Found: ready, VpcID: in.VpcID, SubnetID: s.SubnetID, SubnetCIDR: s.CidrBlock}, nil
	}
	if in.SubnetID != "" {
		return NetworkLookup{VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR}, nil
	}
	cidr, err := plannedSubnetCIDR(occupied)
	return NetworkLookup{VpcID: in.VpcID, SubnetCIDR: cidr}, err
}
func networkReady(v NetworkLookup) NetworkCreated {
	return NetworkCreated{State: "ready", VpcID: v.VpcID, SubnetID: v.SubnetID, SubnetCIDR: v.SubnetCIDR}
}
func definiteNetworkRejection(err error) bool {
	var e *apiError
	if !errors.As(err, &e) || strings.Contains(strings.ToLower(e.code), "tag") {
		return false
	}
	return strings.HasPrefix(e.code, "Invalid") || strings.HasPrefix(e.code, "Missing") || strings.HasPrefix(e.code, "QuotaExceeded") || strings.HasPrefix(e.code, "Forbidden") || strings.HasPrefix(e.code, "AccessDenied") || strings.HasPrefix(e.code, "Signature")
}
func createNetwork(ctx context.Context, api caller, t Template, in Input) NetworkCreated {
	prepareMu.Lock()
	defer prepareMu.Unlock()
	reject := NetworkCreated{State: "rejected", Error: "共享网络创建未提交或被拒绝，请核对后重试"}
	current, err := lookupNetwork(ctx, api, t, in)
	if err != nil {
		return reject
	}
	if current.Found {
		return networkReady(current)
	}
	unknown := NetworkCreated{State: "unknown", VpcID: current.VpcID, SubnetID: current.SubnetID, SubnetCIDR: current.SubnetCIDR, Error: "共享网络仍待核实，不会重复创建，请继续查询"}
	// An existing resource that is still being configured is never a new create.
	if (in.NetworkKind == "vpc" && current.VpcID != "") || (in.NetworkKind == "subnet" && current.SubnetID != "") {
		return unknown
	}
	q := params()
	action := "CreateVpc"
	if in.NetworkKind == "vpc" {
		q.Set("VpcName", networkVpcName)
		q.Set("CidrBlock", networkVpcCIDR)
	} else {
		existing, occupied, e := lookupSubnet(ctx, api, t, in.VpcID)
		if e != nil || existing != nil || !cidrAvailable(in.SubnetCIDR, occupied) {
			return reject
		}
		action = "CreateSubnet"
		q = params("VpcId", in.VpcID, "SubnetName", subnetName(t.RunInstances.ZoneID), "ZoneId", t.RunInstances.ZoneID, "CidrBlock", in.SubnetCIDR)
		unknown.SubnetCIDR = in.SubnetCIDR
	}
	addTags(q, networkTags())
	// Names, region and requested CIDR form a stable request identity; the
	// controller additionally persists unknown intents and never retries them.
	q.Set("ClientToken", sha([]byte(action+"\n"+t.Region+"\n"+q.Encode())))
	var out struct {
		VpcID    string `json:"VpcId"`
		SubnetID string `json:"SubnetId"`
	}
	mutationErr := api.call(ctx, "vpc", action, t.Region, q, &out)
	if matches(`^vpc-[a-z0-9]+$`, out.VpcID) {
		unknown.VpcID = out.VpcID
		in.VpcID = out.VpcID
	}
	if matches(`^subnet-[a-z0-9]+$`, out.SubnetID) {
		unknown.SubnetID = out.SubnetID
		in.SubnetID = out.SubnetID
	}
	confirmed, e := lookupNetwork(ctx, api, t, in)
	if e == nil && confirmed.Found {
		return networkReady(confirmed)
	}
	if definiteNetworkRejection(mutationErr) {
		return reject
	}
	return unknown
}
func verifyNetworkForPurchase(ctx context.Context, api caller, t Template, in Input) error {
	in.NetworkKind = "subnet"
	v, e := lookupNetwork(ctx, api, t, in)
	if e != nil {
		return e
	}
	if !v.Found || v.VpcID != in.VpcID || v.SubnetID != in.SubnetID {
		return errors.New("云服务器网络与已确认的共享网络不匹配")
	}
	return nil
}
