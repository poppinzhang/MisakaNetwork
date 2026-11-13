package aliyun

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"strings"
)

// Names locate candidates; tags, configuration and readiness must also match.
const networkVpcName = "MisakaNetwork-VPC"
const networkVpcCIDR = "10.8.0.0/16"
const networkTag = "misaka-network"
const networkValue = "shared-v1"

var errNetworkResponse = errors.New("阿里云网络查询结果不完整或格式异常，请重新查询")
var errNetworkNotVisible = errors.New("共享网络尚未可见，请稍后查询确认")
var errNetworkConflict = errors.New("同名共享网络的归属或配置不匹配，请在阿里云控制台核对")

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
	VpcID                                string `json:"VpcId"`
	VpcName, CidrBlock, Status, RegionID string
	IsDefault                            bool
	Tags                                 struct{ Tag []tag }
}
type networkSubnet struct {
	SubnetID                                   string `json:"VSwitchId"`
	VpcID                                      string `json:"VpcId"`
	SubnetName                                 string `json:"VSwitchName"`
	Zone                                       string `json:"ZoneId"`
	CidrBlock, Status, ShareType, NetworkAclID string
	IsDefault                                  bool
	AvailableIpAddressCount                    *int
	Tags                                       struct{ Tag []tag }
}

func networkTags() []tag {
	return []tag{{Key: managedTag, Value: managedValue}, {Key: networkTag, Value: networkValue}}
}

func isManagedNetwork(tags []tag) bool {
	return hasTag(tags, managedTag, managedValue) && hasTag(tags, networkTag, networkValue)
}

func subnetName(zone string) string { return "MisakaNetwork-Subnet-" + zone }

func lookupVpc(ctx context.Context, api caller, region, expectedID string) (*networkVpc, error) {
	rows, _, err := pages[networkVpc](ctx, api, "vpc", region, "DescribeVpcs", "Vpcs", "Vpc", params("VpcName", networkVpcName, "IsDefault", "false"))
	if err != nil {
		return nil, err
	}
	var found *networkVpc
	for _, row := range rows {
		if !matches(`^vpc-[a-z0-9]+$`, row.VpcID) || row.VpcName == "" || row.RegionID != region {
			return nil, errNetworkResponse
		}
		// The provider's name filter is fuzzy.
		if row.VpcName != networkVpcName {
			continue
		}
		if found != nil || !matches(`^vpc-[a-z0-9]+$`, row.VpcID) || row.RegionID != region || row.CidrBlock != networkVpcCIDR || row.IsDefault || !isManagedNetwork(row.Tags.Tag) ||
			(expectedID != "" && row.VpcID != expectedID) {
			return nil, errNetworkConflict
		}
		copy := row
		found = &copy
	}
	return found, nil
}

func subnetPrefix(value string) (netip.Prefix, bool) {
	p, err := netip.ParsePrefix(value)
	vpc := netip.MustParsePrefix(networkVpcCIDR)
	return p, err == nil && p.Addr().Is4() && p.Masked().String() == value && p.Bits() >= vpc.Bits() && vpc.Contains(p.Addr())
}

// The complete subnet list is also the source of truth for address allocation.
func lookupSubnet(ctx context.Context, api caller, t Template, vpcID string) (*networkSubnet, []netip.Prefix, error) {
	vpc, err := lookupVpc(ctx, api, t.Region, vpcID)
	if err != nil {
		return nil, nil, err
	}
	if vpc == nil || vpc.Status != "Available" {
		return nil, nil, errNetworkNotVisible
	}
	rows, _, err := pages[networkSubnet](ctx, api, "vpc", t.Region, "DescribeVSwitches", "VSwitches", "VSwitch", params("VpcId", vpcID))
	if err != nil {
		return nil, nil, err
	}
	var found *networkSubnet
	var occupied []netip.Prefix
	for _, row := range rows {
		prefix, valid := subnetPrefix(row.CidrBlock)
		if !matches(`^vsw-[a-z0-9]+$`, row.SubnetID) || row.VpcID != vpcID || !valid {
			return nil, nil, errNetworkResponse
		}
		for _, existing := range occupied {
			if existing.Overlaps(prefix) {
				return nil, nil, errNetworkResponse
			}
		}
		occupied = append(occupied, prefix)
		if row.SubnetName != subnetName(t.RunInstances.ZoneID) {
			continue
		}
		if found != nil || row.Zone != t.RunInstances.ZoneID || prefix.Bits() != 24 || row.IsDefault ||
			row.ShareType != "" || row.NetworkAclID != "" || !isManagedNetwork(row.Tags.Tag) {
			return nil, nil, errNetworkConflict
		}
		if row.AvailableIpAddressCount == nil || *row.AvailableIpAddressCount <= 0 {
			return nil, nil, errors.New("共享子网可用地址不足或尚未确认，请在阿里云控制台核对")
		}
		copy := row
		found = &copy
	}
	return found, occupied, nil
}

func cidrAvailable(value string, occupied []netip.Prefix) bool {
	prefix, valid := subnetPrefix(value)
	if !valid || prefix.Bits() != 24 {
		return false
	}
	for _, other := range occupied {
		if prefix.Overlaps(other) {
			return false
		}
	}
	return true
}

func plannedSubnetCIDR(occupied []netip.Prefix) (string, error) {
	for third := range 256 {
		candidate := fmt.Sprintf("10.8.%d.0/24", third)
		if cidrAvailable(candidate, occupied) {
			return candidate, nil
		}
	}
	return "", errors.New("共享 VPC 内没有可用的子网地址段，请在阿里云控制台核对")
}

func lookupNetwork(ctx context.Context, api caller, t Template, in Input) (NetworkLookup, error) {
	if in.NetworkKind == "vpc" {
		if in.VpcID != "" && !matches(`^vpc-[a-z0-9]+$`, in.VpcID) {
			return NetworkLookup{}, errors.New("共享网络操作记录无效")
		}
		vpc, err := lookupVpc(ctx, api, t.Region, in.VpcID)
		if err != nil || vpc == nil {
			return NetworkLookup{VpcID: in.VpcID}, err
		}
		return NetworkLookup{Found: vpc.Status == "Available", VpcID: vpc.VpcID}, nil
	}
	if in.NetworkKind != "subnet" || !matches(`^vpc-[a-z0-9]+$`, in.VpcID) ||
		(in.SubnetID != "" && !matches(`^vsw-[a-z0-9]+$`, in.SubnetID)) ||
		(in.SubnetCIDR != "" && !cidrAvailable(in.SubnetCIDR, nil)) {
		return NetworkLookup{}, errors.New("共享网络操作记录无效")
	}
	subnet, occupied, err := lookupSubnet(ctx, api, t, in.VpcID)
	if errors.Is(err, errNetworkNotVisible) {
		return NetworkLookup{VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR}, nil
	}
	if err != nil {
		return NetworkLookup{}, err
	}
	if subnet != nil {
		if (in.SubnetID != "" && in.SubnetID != subnet.SubnetID) ||
			(in.SubnetCIDR != "" && in.SubnetCIDR != subnet.CidrBlock) {
			return NetworkLookup{}, errNetworkConflict
		}
		return NetworkLookup{Found: subnet.Status == "Available", VpcID: in.VpcID, SubnetID: subnet.SubnetID, SubnetCIDR: subnet.CidrBlock}, nil
	}
	if in.SubnetID != "" {
		return NetworkLookup{VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR}, nil
	}
	cidr, err := plannedSubnetCIDR(occupied)
	return NetworkLookup{VpcID: in.VpcID, SubnetCIDR: cidr}, err
}

func networkReady(value NetworkLookup) NetworkCreated {
	return NetworkCreated{State: "ready", VpcID: value.VpcID, SubnetID: value.SubnetID, SubnetCIDR: value.SubnetCIDR}
}

// Even a documented rejection is followed by lookup: a competing controller
// may have created the same shared resource. Generic/partial-service failures
// remain unknown; they must never clear the controller's persisted intent.
func definiteNetworkRejection(err error) bool {
	var cloud *apiError
	if !errors.As(err, &cloud) {
		return false
	}
	// Tag-related errors may originate after a resource has been provisioned.
	if strings.Contains(strings.ToLower(cloud.code), "tag") {
		return false
	}
	switch {
	case strings.HasPrefix(cloud.code, "InvalidAccessKeyId"), strings.HasPrefix(cloud.code, "Signature"), strings.HasPrefix(cloud.code, "Forbidden"), strings.HasPrefix(cloud.code, "Unauthorized"), strings.HasPrefix(cloud.code, "MissingParameter"):
		return true
	}
	return false
}

func createNetwork(ctx context.Context, api caller, t Template, in Input) NetworkCreated {
	prepareMu.Lock()
	defer prepareMu.Unlock()
	rejected := NetworkCreated{State: "rejected", Error: "共享网络创建未提交或被明确拒绝，请检查权限、网络配置与配额后重试"}
	current, err := lookupNetwork(ctx, api, t, in)
	if err != nil {
		return rejected // No mutation has been attempted by this call.
	}
	if current.Found {
		return networkReady(current)
	}
	if (in.NetworkKind == "vpc" && current.VpcID != "") || (in.NetworkKind == "subnet" && current.SubnetID != "") {
		return NetworkCreated{State: "unknown", VpcID: current.VpcID, SubnetID: current.SubnetID, SubnetCIDR: current.SubnetCIDR,
			Error: "已记录的共享网络尚未可见，不会重复创建，请继续查询确认"}
	}
	var action string
	var payload url.Values
	if in.NetworkKind == "vpc" {
		action = "CreateVpc"
		payload = params("VpcName", networkVpcName, "CidrBlock", networkVpcCIDR, "EnableIpv6", "false")
	} else {
		// Recheck the persisted plan, never replace it with a different CIDR
		// inside the mutation call when another client consumes that range.
		existing, occupied, lookupErr := lookupSubnet(ctx, api, t, in.VpcID)
		if lookupErr == nil && existing != nil {
			if existing.Status != "Available" {
				return NetworkCreated{State: "unknown", VpcID: in.VpcID, SubnetID: existing.SubnetID, SubnetCIDR: existing.CidrBlock, Error: errNetworkNotVisible.Error()}
			}
			if existing.CidrBlock != in.SubnetCIDR {
				return rejected
			}
			return networkReady(NetworkLookup{Found: true, VpcID: in.VpcID, SubnetID: existing.SubnetID, SubnetCIDR: existing.CidrBlock})
		}
		if lookupErr != nil || !cidrAvailable(in.SubnetCIDR, occupied) {
			return rejected
		}
		action = "CreateVSwitch"
		payload = params("VpcId", in.VpcID, "VSwitchName", subnetName(t.RunInstances.ZoneID), "ZoneId", t.RunInstances.ZoneID, "CidrBlock", in.SubnetCIDR)
	}
	addTags(payload, networkTags())
	// Stable intent token is provider-scoped by API/region/operation; the same
	// network plan is never submitted with a fresh token after an unknown result.
	payload.Set("ClientToken", sha([]byte(in.SecretID + "|" + t.Region + "|" + action + "|" + in.VpcID + "|" + in.SubnetCIDR + "|" + t.RunInstances.ZoneID))[:48])
	var response struct {
		VpcID    string `json:"VpcId"`
		SubnetID string `json:"VSwitchId"`
	}

	mutationErr := api.call(ctx, "vpc", action, t.Region, payload, &response)
	confirmed, lookupErr := lookupNetwork(ctx, api, t, in)
	if lookupErr == nil && confirmed.Found {
		// A successful response identifying a different resource is a conflict,
		// not an excuse to silently select an arbitrary concurrent creation.
		returnedID, confirmedID, idPattern := response.VpcID, confirmed.VpcID, `^vpc-[a-z0-9]+$`
		if in.NetworkKind == "subnet" {
			returnedID, confirmedID, idPattern = response.SubnetID, confirmed.SubnetID, `^vsw-[a-z0-9]+$`
		}
		idMatches := mutationErr != nil
		if matches(idPattern, returnedID) {
			// JSON decoding may populate an ID before reporting an error on
			// another field. That known ID still pins recovery to this resource.
			idMatches = returnedID == confirmedID
		}
		if idMatches {
			return networkReady(confirmed)
		}
	}
	if definiteNetworkRejection(mutationErr) {
		return rejected
	}
	unknown := NetworkCreated{State: "unknown", VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR,
		Error: "共享网络创建结果尚未确认，请刷新查询或到阿里云控制台核对；不会自动重复创建"}
	// Preserve a syntactically valid returned ID even when ownership verification
	// is not yet complete. Recovery must pin that ID, not adopt a later namesake.
	if in.NetworkKind == "vpc" && matches(`^vpc-[a-z0-9]+$`, response.VpcID) {
		unknown.VpcID = response.VpcID
	}
	if in.NetworkKind == "subnet" && matches(`^vsw-[a-z0-9]+$`, response.SubnetID) {
		unknown.SubnetID = response.SubnetID
	}
	return unknown
}

func verifyNetworkForPurchase(ctx context.Context, api caller, t Template, in Input) error {
	lookupInput := in
	lookupInput.NetworkKind = "subnet"
	found, err := lookupNetwork(ctx, api, t, lookupInput)
	if err != nil {
		return err
	}
	if !found.Found || found.VpcID != in.VpcID || found.SubnetID != in.SubnetID {
		return errors.New("云服务器网络与已确认的共享网络不匹配，已停止购买")
	}
	return nil
}
