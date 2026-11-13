package tencent

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// Names locate candidates; ownership tags and configuration must also match.
// CreateVpc/CreateSubnet have no documented ClientToken. The controller must
// persist each mutation intent, and use lookup only after an unknown outcome.
const networkVpcName = "MisakaNetwork-VPC"
const networkVpcCIDR = "10.8.0.0/16"
const networkTag = "misaka-network"
const networkValue = "shared-v1"
const networkPageSize = 100
const maxNetworkResources = 4096

var errNetworkResponse = errors.New("腾讯云网络查询结果不完整或格式异常，请重新查询")
var errNetworkNotVisible = errors.New("共享网络尚未可见，请稍后查询确认")
var errNetworkConflict = errors.New("同名共享网络的归属或配置不匹配，请在腾讯云控制台核对")

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
	VpcID     string `json:"VpcId"`
	VpcName   string
	CidrBlock string
	IsDefault bool
	TagSet    []tag
}

type networkSubnet struct {
	SubnetID                string `json:"SubnetId"`
	VpcID                   string `json:"VpcId"`
	SubnetName              string
	Zone                    string
	CidrBlock               string
	IsDefault               bool
	IsCdcSubnet             int
	IsRemoteVpcSnat         bool
	AvailableIpAddressCount *int
	TagSet                  []tag
}

func (v networkVpc) resourceID() string    { return v.VpcID }
func (s networkSubnet) resourceID() string { return s.SubnetID }

// Exhaust pagination before concluding absence or allocating an address range.
// Counts changing mid-query and repeated pages fail closed without mutations.
func networkPages[T interface{ resourceID() string }](ctx context.Context, api caller, region, action string, filters []any) ([]T, error) {
	var result []T
	total := -1
	seen := map[string]bool{}
	for total < 0 || len(result) < total {
		if ctx.Err() != nil {
			return nil, errNetworkResponse
		}
		var out struct {
			TotalCount *int
			VpcSet     *[]T
			SubnetSet  *[]T
		}
		payload := map[string]any{"Filters": filters, "Limit": strconv.Itoa(networkPageSize), "Offset": strconv.Itoa(len(result))}
		if err := api.call(ctx, "vpc", action, region, payload, &out); err != nil {
			return nil, err
		}
		rows, idPattern := out.VpcSet, `^vpc-[a-z0-9]+$`
		if action == "DescribeSubnets" {
			rows, idPattern = out.SubnetSet, `^subnet-[a-z0-9]+$`
		}
		if out.TotalCount == nil || *out.TotalCount < 0 || *out.TotalCount > maxNetworkResources || rows == nil ||
			(total >= 0 && total != *out.TotalCount) || len(*rows) > networkPageSize ||
			len(result)+len(*rows) > *out.TotalCount || (len(*rows) == 0 && len(result) < *out.TotalCount) {
			return nil, errNetworkResponse
		}
		total = *out.TotalCount
		for _, row := range *rows {
			id := row.resourceID()
			if !matches(idPattern, id) || seen[id] {
				return nil, errNetworkResponse
			}
			seen[id] = true
			result = append(result, row)
		}
	}
	return result, nil
}

func networkTags() []tag {
	return []tag{{Key: managedTag, Value: managedValue}, {Key: networkTag, Value: networkValue}}
}

func isManagedNetwork(tags []tag) bool {
	return hasTag(tags, managedTag, managedValue) && hasTag(tags, networkTag, networkValue)
}

func subnetName(zone string) string { return "MisakaNetwork-Subnet-" + zone }

func lookupVpc(ctx context.Context, api caller, region, expectedID string) (*networkVpc, error) {
	rows, err := networkPages[networkVpc](ctx, api, region, "DescribeVpcs", []any{filter("vpc-name", networkVpcName)})
	if err != nil {
		return nil, err
	}
	var found *networkVpc
	for _, row := range rows {
		// The provider's name filter is fuzzy.
		if row.VpcName != networkVpcName {
			continue
		}
		if found != nil || row.CidrBlock != networkVpcCIDR || row.IsDefault || !isManagedNetwork(row.TagSet) ||
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
	if vpc == nil {
		return nil, nil, errNetworkNotVisible
	}
	rows, err := networkPages[networkSubnet](ctx, api, t.Region, "DescribeSubnets", []any{filter("vpc-id", vpcID)})
	if err != nil {
		return nil, nil, err
	}
	var found *networkSubnet
	var occupied []netip.Prefix
	for _, row := range rows {
		prefix, valid := subnetPrefix(row.CidrBlock)
		if row.VpcID != vpcID || !valid {
			return nil, nil, errNetworkResponse
		}
		for _, existing := range occupied {
			if existing.Overlaps(prefix) {
				return nil, nil, errNetworkResponse
			}
		}
		occupied = append(occupied, prefix)
		if row.SubnetName != subnetName(t.RunInstances.Placement.Zone) {
			continue
		}
		if found != nil || row.Zone != t.RunInstances.Placement.Zone || prefix.Bits() != 24 || row.IsDefault ||
			row.IsCdcSubnet != 0 || row.IsRemoteVpcSnat || !isManagedNetwork(row.TagSet) {
			return nil, nil, errNetworkConflict
		}
		if row.AvailableIpAddressCount == nil || *row.AvailableIpAddressCount <= 0 {
			return nil, nil, errors.New("共享子网可用地址不足或尚未确认，请在腾讯云控制台核对")
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
	return "", errors.New("共享 VPC 内没有可用的子网地址段，请在腾讯云控制台核对")
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
		return NetworkLookup{Found: true, VpcID: vpc.VpcID}, nil
	}
	if in.NetworkKind != "subnet" || !matches(`^vpc-[a-z0-9]+$`, in.VpcID) ||
		(in.SubnetID != "" && !matches(`^subnet-[a-z0-9]+$`, in.SubnetID)) ||
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
		return NetworkLookup{Found: true, VpcID: in.VpcID, SubnetID: subnet.SubnetID, SubnetCIDR: subnet.CidrBlock}, nil
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
	switch strings.SplitN(cloud.code, ".", 2)[0] {
	case "AuthFailure", "UnauthorizedOperation", "InvalidParameter", "InvalidParameterValue", "MissingParameter", "RequestLimitExceeded":
		return true
	}
	return cloud.code == "LimitExceeded" || cloud.code == "ResourceNotFound" || cloud.code == "UnsupportedOperation.AppIdMismatch"
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
	if (in.NetworkKind == "vpc" && in.VpcID != "") || (in.NetworkKind == "subnet" && in.SubnetID != "") {
		return NetworkCreated{State: "unknown", VpcID: in.VpcID, SubnetID: in.SubnetID, SubnetCIDR: in.SubnetCIDR,
			Error: "已记录的共享网络尚未可见，不会重复创建，请继续查询确认"}
	}
	var action string
	var payload map[string]any
	if in.NetworkKind == "vpc" {
		action = "CreateVpc"
		payload = map[string]any{"VpcName": networkVpcName, "CidrBlock": networkVpcCIDR, "Tags": networkTags()}
	} else {
		// Recheck the persisted plan, never replace it with a different CIDR
		// inside the mutation call when another client consumes that range.
		existing, occupied, lookupErr := lookupSubnet(ctx, api, t, in.VpcID)
		if lookupErr == nil && existing != nil {
			if existing.CidrBlock != in.SubnetCIDR {
				return rejected
			}
			return networkReady(NetworkLookup{Found: true, VpcID: in.VpcID, SubnetID: existing.SubnetID, SubnetCIDR: existing.CidrBlock})
		}
		if lookupErr != nil || !cidrAvailable(in.SubnetCIDR, occupied) {
			return rejected
		}
		action = "CreateSubnet"
		payload = map[string]any{"VpcId": in.VpcID, "SubnetName": subnetName(t.RunInstances.Placement.Zone),
			"Zone": t.RunInstances.Placement.Zone, "CidrBlock": in.SubnetCIDR, "Tags": networkTags()}
	}
	var response struct {
		Vpc struct {
			VpcID string `json:"VpcId"`
		}
		Subnet struct {
			SubnetID string `json:"SubnetId"`
		}
	}
	mutationErr := api.call(ctx, "vpc", action, t.Region, payload, &response)
	confirmed, lookupErr := lookupNetwork(ctx, api, t, in)
	if lookupErr == nil && confirmed.Found {
		// A successful response identifying a different resource is a conflict,
		// not an excuse to silently select an arbitrary concurrent creation.
		returnedID, confirmedID, idPattern := response.Vpc.VpcID, confirmed.VpcID, `^vpc-[a-z0-9]+$`
		if in.NetworkKind == "subnet" {
			returnedID, confirmedID, idPattern = response.Subnet.SubnetID, confirmed.SubnetID, `^subnet-[a-z0-9]+$`
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
		Error: "共享网络创建结果尚未确认，请刷新查询或到腾讯云控制台核对；不会自动重复创建"}
	// Preserve a syntactically valid returned ID even when ownership verification
	// is not yet complete. Recovery must pin that ID, not adopt a later namesake.
	if in.NetworkKind == "vpc" && matches(`^vpc-[a-z0-9]+$`, response.Vpc.VpcID) {
		unknown.VpcID = response.Vpc.VpcID
	}
	if in.NetworkKind == "subnet" && matches(`^subnet-[a-z0-9]+$`, response.Subnet.SubnetID) {
		unknown.SubnetID = response.Subnet.SubnetID
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
