package tencent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func ownedVpc() networkVpc {
	return networkVpc{VpcID: "vpc-fixture", VpcName: networkVpcName, CidrBlock: networkVpcCIDR, TagSet: networkTags()}
}

func ownedSubnet(t Template, id, cidr string) networkSubnet {
	available := 250
	return networkSubnet{SubnetID: id, VpcID: "vpc-fixture", SubnetName: subnetName(t.RunInstances.Placement.Zone),
		Zone: t.RunInstances.Placement.Zone, CidrBlock: cidr, AvailableIpAddressCount: &available, TagSet: networkTags()}
}

func vpcResponse(rows ...networkVpc) map[string]any {
	return map[string]any{"TotalCount": len(rows), "VpcSet": append([]networkVpc{}, rows...)}
}

func subnetResponse(rows ...networkSubnet) map[string]any {
	return map[string]any{"TotalCount": len(rows), "SubnetSet": append([]networkSubnet{}, rows...)}
}

type networkHarness struct {
	api     *fakeAPI
	vpcs    []networkVpc
	subnets []networkSubnet
}

func newNetworkHarness(t *testing.T) *networkHarness {
	h := &networkHarness{api: &fakeAPI{t: t}}
	h.api.respond = func(c callRecord) (any, error) {
		if c.service != "vpc" || c.region != "ap-guangzhou" {
			t.Fatalf("unexpected network API scope: %s %s", c.service, c.region)
		}
		switch c.action {
		case "DescribeVpcs", "DescribeSubnets":
			offset, ok := c.body["Offset"].(string)
			if !ok || c.body["Limit"] != "100" {
				t.Fatal("VPC pagination must use string offsets and limits")
			}
			start, err := strconv.Atoi(offset)
			if err != nil {
				t.Fatal(err)
			}
			if c.action == "DescribeVpcs" {
				return map[string]any{"TotalCount": len(h.vpcs), "VpcSet": append([]networkVpc{}, h.vpcs[start:min(start+100, len(h.vpcs))]...)}, nil
			}
			return map[string]any{"TotalCount": len(h.subnets), "SubnetSet": append([]networkSubnet{}, h.subnets[start:min(start+100, len(h.subnets))]...)}, nil
		case "CreateVpc":
			if c.body["VpcName"] != networkVpcName || c.body["CidrBlock"] != networkVpcCIDR || len(c.body) != 3 {
				t.Fatal("VPC create parameters escaped managed defaults")
			}
			checkNetworkTags(t, c.body["Tags"])
			vpc := ownedVpc()
			h.vpcs = append(h.vpcs, vpc)
			return map[string]any{"Vpc": vpc}, nil
		case "CreateSubnet":
			zone, _ := c.body["Zone"].(string)
			if c.body["VpcId"] != "vpc-fixture" || c.body["SubnetName"] != subnetName(zone) || len(c.body) != 5 {
				t.Fatal("subnet create parameters escaped managed defaults")
			}
			checkNetworkTags(t, c.body["Tags"])
			template := fixtureTemplate()
			template.RunInstances.Placement.Zone = zone
			subnet := ownedSubnet(template, fmt.Sprintf("subnet-fixture%d", len(h.subnets)), c.body["CidrBlock"].(string))
			h.subnets = append(h.subnets, subnet)
			return map[string]any{"Subnet": subnet}, nil
		default:
			t.Fatalf("unexpected network action %s", c.action)
			return nil, nil
		}
	}
	return h
}

func checkNetworkTags(t *testing.T, raw any) {
	t.Helper()
	data, _ := json.Marshal(raw)
	var tags []tag
	if json.Unmarshal(data, &tags) != nil || len(tags) != 2 || !isManagedNetwork(tags) {
		t.Fatal("missing managed network ownership tags")
	}
}

func networkMutations(api *fakeAPI) int {
	count := 0
	for _, call := range api.calls {
		if strings.HasPrefix(call.action, "Create") {
			count++
		}
	}
	return count
}

func TestManagedNetworksPlanCreateReuseAndAllocateByZone(t *testing.T) {
	h := newNetworkHarness(t)
	template, in := fixtureTemplate(), fixtureInput()
	in.NetworkKind, in.VpcID, in.SubnetID = "vpc", "", ""
	plan, err := lookupNetwork(context.Background(), h.api, template, in)
	if err != nil || plan.Found || networkMutations(h.api) != 0 {
		t.Fatalf("first VPC plan: %+v %v", plan, err)
	}
	for range 2 {
		created := createNetwork(context.Background(), h.api, template, in)
		if created.State != "ready" || created.VpcID != "vpc-fixture" {
			t.Fatalf("VPC create/reuse failed: %+v", created)
		}
	}
	if networkMutations(h.api) != 1 {
		t.Fatal("VPC was recreated on reuse")
	}
	in.NetworkKind, in.VpcID = "subnet", "vpc-fixture"
	for index, zone := range []string{"ap-guangzhou-7", "ap-guangzhou-6"} {
		template.RunInstances.Placement.Zone = zone
		in.SubnetCIDR = ""
		plan, err := lookupNetwork(context.Background(), h.api, template, in)
		if err != nil || plan.Found || plan.SubnetCIDR != fmt.Sprintf("10.8.%d.0/24", index) {
			t.Fatalf("subnet plan: %+v %v", plan, err)
		}
		in.SubnetCIDR = plan.SubnetCIDR
		for range 2 {
			result := createNetwork(context.Background(), h.api, template, in)
			if result.State != "ready" || result.SubnetID != fmt.Sprintf("subnet-fixture%d", index) || result.SubnetCIDR != in.SubnetCIDR {
				t.Fatalf("subnet create/reuse: %+v", result)
			}
		}
	}
	if networkMutations(h.api) != 3 {
		t.Fatal("expected one VPC and one subnet per zone")
	}
}

func TestNetworkVpcOwnershipCollisionAndFuzzyNameFiltering(t *testing.T) {
	for _, scenario := range []string{"fuzzy-other", "foreign", "cidr", "default", "duplicates", "duplicate-tag", "wrong-saved-id", "saved-missing"} {
		t.Run(scenario, func(t *testing.T) {
			h := newNetworkHarness(t)
			vpc := ownedVpc()
			in := fixtureInput()
			in.NetworkKind, in.VpcID = "vpc", ""
			switch scenario {
			case "fuzzy-other":
				vpc.VpcName += "-other"
			case "foreign":
				vpc.TagSet = nil
			case "cidr":
				vpc.CidrBlock = "10.9.0.0/16"
			case "default":
				vpc.IsDefault = true
			case "duplicate-tag":
				vpc.TagSet = append(vpc.TagSet, vpc.TagSet[0])
			case "wrong-saved-id":
				in.VpcID = "vpc-different"
			}
			h.vpcs = []networkVpc{vpc}
			if scenario == "duplicates" {
				duplicate := ownedVpc()
				duplicate.VpcID = "vpc-second"
				h.vpcs = append(h.vpcs, duplicate)
			}
			if scenario == "saved-missing" {
				in.VpcID, h.vpcs = "vpc-fixture", nil
			}
			found, err := lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
			if scenario == "fuzzy-other" || scenario == "saved-missing" {
				if err != nil || found.Found {
					t.Fatal("fuzzy nonmatching name was adopted")
				}
			} else if err == nil {
				t.Fatal("foreign, changed or ambiguous VPC accepted")
			}
			if networkMutations(h.api) != 0 {
				t.Fatal("lookup mutated cloud network")
			}
		})
	}
}

func TestSubnetLookupChecksOwnershipZoneCapacityAndPersistedIdentity(t *testing.T) {
	for _, scenario := range []string{"foreign", "wrong-zone", "wrong-vpc", "wrong-cidr", "noncanonical", "empty", "missing-capacity", "cdc", "snat", "default", "duplicates", "wrong-saved-id", "wrong-saved-cidr", "saved-missing"} {
		t.Run(scenario, func(t *testing.T) {
			h := newNetworkHarness(t)
			h.vpcs = []networkVpc{ownedVpc()}
			row := ownedSubnet(fixtureTemplate(), "subnet-fixture", "10.8.0.0/24")
			in := fixtureInput()
			in.NetworkKind = "subnet"
			switch scenario {
			case "foreign":
				row.TagSet = nil
			case "wrong-zone":
				row.Zone = "ap-guangzhou-6"
			case "wrong-vpc":
				row.VpcID = "vpc-other"
			case "wrong-cidr":
				row.CidrBlock = "10.9.0.0/24"
			case "noncanonical":
				row.CidrBlock = "10.8.0.1/24"
			case "empty":
				*row.AvailableIpAddressCount = 0
			case "missing-capacity":
				row.AvailableIpAddressCount = nil
			case "cdc":
				row.IsCdcSubnet = 1
			case "snat":
				row.IsRemoteVpcSnat = true
			case "default":
				row.IsDefault = true
			case "wrong-saved-id":
				in.SubnetID = "subnet-other"
			case "wrong-saved-cidr":
				in.SubnetCIDR = "10.8.1.0/24"
			}
			h.subnets = []networkSubnet{row}
			if scenario == "duplicates" {
				duplicate := ownedSubnet(fixtureTemplate(), "subnet-second", "10.8.1.0/24")
				h.subnets = append(h.subnets, duplicate)
			}
			if scenario == "saved-missing" {
				h.subnets = nil
			}
			found, err := lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
			if scenario == "saved-missing" {
				if err != nil || found.Found || found.SubnetID != in.SubnetID {
					t.Fatal("pending subnet lost known identity")
				}
			} else if err == nil {
				t.Fatal("unsafe subnet accepted")
			}
			if networkMutations(h.api) != 0 {
				t.Fatal("lookup changed cloud resources")
			}
		})
	}
}

func TestNetworkPaginationFindsLateMatchesAndAvoidsAllOccupiedRanges(t *testing.T) {
	h := newNetworkHarness(t)
	for i := range 100 {
		row := ownedVpc()
		row.VpcID, row.VpcName = fmt.Sprintf("vpc-other%d", i), networkVpcName+fmt.Sprintf("-other%d", i)
		h.vpcs = append(h.vpcs, row)
	}
	h.vpcs = append(h.vpcs, ownedVpc())
	in := fixtureInput()
	in.NetworkKind = "vpc"
	result, err := lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
	if err != nil || !result.Found || len(h.api.calls) != 2 || h.api.calls[1].body["Offset"] != "100" {
		t.Fatalf("VPC pagination failed: %+v %v", result, err)
	}
	h.vpcs = []networkVpc{ownedVpc()}
	for i := range 101 {
		row := ownedSubnet(fixtureTemplate(), fmt.Sprintf("subnet-other%d", i), fmt.Sprintf("10.8.%d.0/24", i))
		row.SubnetName, row.TagSet = "other", nil
		h.subnets = append(h.subnets, row)
	}
	in.NetworkKind, in.SubnetID = "subnet", ""
	result, err = lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
	if err != nil || result.Found || result.SubnetCIDR != "10.8.101.0/24" {
		t.Fatalf("subnet allocation missed later pages: %+v %v", result, err)
	}
	// Even a smaller foreign subnet prevents allocation of its containing /24.
	h.subnets[100].CidrBlock = "10.8.100.0/28"
	result, err = lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
	if err != nil || result.SubnetCIDR != "10.8.101.0/24" {
		t.Fatal("subnet overlap was ignored")
	}
	for i := 101; i < 256; i++ {
		row := ownedSubnet(fixtureTemplate(), fmt.Sprintf("subnet-other%d", i), fmt.Sprintf("10.8.%d.0/24", i))
		row.SubnetName = "other"
		h.subnets = append(h.subnets, row)
	}
	if _, err := lookupNetwork(context.Background(), h.api, fixtureTemplate(), in); err == nil {
		t.Fatal("exhausted VPC allocated a duplicate CIDR")
	}
}

func TestMalformedNetworkPaginationNeverMeansAbsent(t *testing.T) {
	for _, scenario := range []string{"missing-count", "missing-rows", "excessive-total", "empty-page", "extra-rows", "duplicate-id", "changed-total", "repeated-page"} {
		t.Run(scenario, func(t *testing.T) {
			calls := 0
			api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
				if c.action != "DescribeVpcs" {
					t.Fatal("malformed lookup caused mutation")
				}
				calls++
				row := ownedVpc()
				row.VpcName += "-other"
				out := vpcResponse(row)
				switch scenario {
				case "missing-count":
					delete(out, "TotalCount")
				case "missing-rows":
					delete(out, "VpcSet")
				case "excessive-total":
					out["TotalCount"] = maxNetworkResources + 1
				case "empty-page":
					out["VpcSet"] = []networkVpc{}
				case "extra-rows":
					out["TotalCount"] = 0
				case "duplicate-id":
					out = vpcResponse(row, row)
				case "changed-total":
					if calls == 1 {
						out["TotalCount"] = 2
					}
				case "repeated-page":
					out["TotalCount"] = 2
				}
				return out, nil
			}}
			in := fixtureInput()
			in.NetworkKind, in.VpcID = "vpc", ""
			if _, err := lookupNetwork(context.Background(), api, fixtureTemplate(), in); err == nil {
				t.Fatal("malformed pagination accepted as a complete lookup")
			}
		})
	}
}

func TestNetworkCreationResponseLossAndRejectionsNeverReplayMutation(t *testing.T) {
	for _, kind := range []string{"vpc", "subnet"} {
		for _, scenario := range []string{"lost-but-created", "unknown", "internal-error", "failed-operation", "tag-error", "rejected", "bad-response-id", "post-query-fails", "lost-tags"} {
			t.Run(kind+"/"+scenario, func(t *testing.T) {
				h := newNetworkHarness(t)
				in := fixtureInput()
				in.NetworkKind, in.VpcID, in.SubnetID = kind, "", ""
				if kind == "subnet" {
					h.vpcs = []networkVpc{ownedVpc()}
					in.VpcID, in.SubnetCIDR = "vpc-fixture", "10.8.0.0/24"
				}
				original := h.api.respond
				mutated := false
				h.api.respond = func(c callRecord) (any, error) {
					if !strings.HasPrefix(c.action, "Create") {
						if mutated && scenario == "post-query-fails" {
							return nil, errors.New("sensitive query failure")
						}
						return original(c)
					}
					mutated = true
					switch scenario {
					case "unknown":
						return nil, errors.New("sensitive transport failure")
					case "internal-error":
						return nil, &apiError{code: "InternalError"}
					case "failed-operation":
						return nil, &apiError{code: "FailedOperation.NetDetectTimeOut"}
					case "tag-error":
						return nil, &apiError{code: "InvalidParameterValue.TagInvalidKey"}
					case "rejected":
						return nil, &apiError{code: "AuthFailure.SignatureFailure"}
					}
					out, err := original(c)
					if scenario == "lost-but-created" {
						return nil, errors.New("sensitive lost response")
					}
					if scenario == "lost-tags" {
						if kind == "vpc" {
							h.vpcs[0].TagSet = nil
						} else {
							h.subnets[0].TagSet = nil
						}
					}
					if scenario == "bad-response-id" {
						return map[string]any{}, nil
					}
					return out, err
				}
				result := createNetwork(context.Background(), h.api, fixtureTemplate(), in)
				want := "unknown"
				if scenario == "lost-but-created" {
					want = "ready"
				} else if scenario == "rejected" {
					want = "rejected"
				}
				if result.State != want || strings.Contains(result.Error, "sensitive") || networkMutations(h.api) != 1 {
					t.Fatalf("unsafe mutation recovery: %+v; want %s", result, want)
				}
				if scenario == "post-query-fails" || scenario == "lost-tags" {
					if kind == "vpc" && result.VpcID != "vpc-fixture" || kind == "subnet" && (result.VpcID != "vpc-fixture" || result.SubnetID != "subnet-fixture0" || result.SubnetCIDR != in.SubnetCIDR) {
						t.Fatal("unverified returned resource ID was lost")
					}
				}
				// Refresh after an unknown result never creates a second resource.
				lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
				if networkMutations(h.api) != 1 {
					t.Fatal("lookup retried the uncertain mutation")
				}
			})
		}
	}
}

func TestTagAndInternalFailuresCannotClearNetworkIntent(t *testing.T) {
	for _, code := range []string{"InvalidParameterValue.TagInvalidKey", "InvalidParameterValue.InvalidTag", "UnauthorizedOperation.CreateTags", "LimitExceeded.TAG_QUOTA", "InternalError", "FailedOperation.NetDetectTimeOut", "UnsupportedOperation.RecordExists"} {
		if definiteNetworkRejection(&apiError{code: code}) {
			t.Fatalf("potential partial mutation classified as rejected: %s", code)
		}
	}
	for _, code := range []string{"AuthFailure.SignatureFailure", "UnauthorizedOperation", "InvalidParameterValue.SubnetOverlap", "MissingParameter", "RequestLimitExceeded", "LimitExceeded"} {
		if !definiteNetworkRejection(&apiError{code: code}) {
			t.Fatalf("definite request rejection classified as unknown: %s", code)
		}
	}
}

func TestPartialNetworkResponseDecodeStillPinsKnownID(t *testing.T) {
	for _, kind := range []string{"vpc", "subnet"} {
		for _, sameID := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/same-id-%t", kind, sameID), func(t *testing.T) {
				h := newNetworkHarness(t)
				in := fixtureInput()
				in.NetworkKind, in.VpcID, in.SubnetID = kind, "", ""
				if kind == "subnet" {
					h.vpcs = []networkVpc{ownedVpc()}
					in.VpcID, in.SubnetCIDR = "vpc-fixture", "10.8.0.0/24"
				}
				original := h.api.respond
				h.api.respond = func(c callRecord) (any, error) {
					out, err := original(c)
					if !strings.HasPrefix(c.action, "Create") {
						return out, err
					}
					response := out.(map[string]any)
					if kind == "vpc" {
						// The valid VPC ID is decoded despite the other field's error.
						response["Subnet"] = map[string]any{"SubnetId": 123}
						if !sameID {
							h.vpcs[0].VpcID = "vpc-concurrent"
						}
					} else {
						response["Vpc"] = map[string]any{"VpcId": 123}
						if !sameID {
							h.subnets[0].SubnetID = "subnet-concurrent"
						}
					}
					return response, nil // fakeAPI performs the real partial JSON decode.
				}
				result := createNetwork(context.Background(), h.api, fixtureTemplate(), in)
				want := "unknown"
				if sameID {
					want = "ready"
				}
				if result.State != want || result.VpcID != "vpc-fixture" || (kind == "subnet" && result.SubnetID != "subnet-fixture0") || networkMutations(h.api) != 1 {
					t.Fatalf("partial decoding lost known identity: %+v, want %s", result, want)
				}
			})
		}
	}
}

func TestSubnetCreateRechecksPersistedPlanAndConcurrentCreation(t *testing.T) {
	for _, scenario := range []string{"occupied", "existing-between-checks", "wrong-plan", "invalid-kind", "lookup-failure"} {
		t.Run(scenario, func(t *testing.T) {
			h := newNetworkHarness(t)
			h.vpcs = []networkVpc{ownedVpc()}
			in := fixtureInput()
			in.NetworkKind, in.SubnetID, in.SubnetCIDR = "subnet", "", "10.8.0.0/24"
			if scenario == "occupied" {
				row := ownedSubnet(fixtureTemplate(), "subnet-foreign", in.SubnetCIDR)
				row.SubnetName, row.TagSet = "other", nil
				h.subnets = []networkSubnet{row}
			}
			if scenario == "wrong-plan" {
				in.SubnetCIDR = "10.9.0.0/24"
			}
			if scenario == "invalid-kind" {
				in.NetworkKind = "DeleteVpc"
			}
			original, subnetQueries := h.api.respond, 0
			h.api.respond = func(c callRecord) (any, error) {
				if scenario == "lookup-failure" {
					return nil, errors.New("sensitive lookup failure")
				}
				if c.action == "DescribeSubnets" {
					subnetQueries++
					if scenario == "existing-between-checks" && subnetQueries == 2 {
						h.subnets = []networkSubnet{ownedSubnet(fixtureTemplate(), "subnet-concurrent", in.SubnetCIDR)}
					}
				}
				return original(c)
			}
			result := createNetwork(context.Background(), h.api, fixtureTemplate(), in)
			want := "rejected"
			if scenario == "existing-between-checks" {
				want = "ready"
			}
			if result.State != want || networkMutations(h.api) != 0 || strings.Contains(result.Error, "sensitive") {
				t.Fatalf("stale plan was mutated: %+v", result)
			}
		})
	}
}

func TestPurchaseRejectsUnmanagedOrMismatchedRuntimeNetwork(t *testing.T) {
	for _, scenario := range []string{"missing-id", "foreign-vpc", "wrong-subnet", "wrong-zone", "no-capacity"} {
		t.Run(scenario, func(t *testing.T) {
			h := newNetworkHarness(t)
			h.vpcs = []networkVpc{ownedVpc()}
			h.subnets = []networkSubnet{ownedSubnet(fixtureTemplate(), "subnet-fixture", "10.8.0.0/24")}
			in := fixtureInput()
			switch scenario {
			case "missing-id":
				in.VpcID = ""
			case "foreign-vpc":
				h.vpcs[0].TagSet = nil
			case "wrong-subnet":
				in.SubnetID = "subnet-other"
			case "wrong-zone":
				h.subnets[0].Zone = "ap-guangzhou-6"
			case "no-capacity":
				*h.subnets[0].AvailableIpAddressCount = 0
			}
			original := h.api.respond
			h.api.respond = func(c callRecord) (any, error) {
				if c.action == "RunInstances" {
					t.Fatal("unsafe network reached a purchase")
				}
				if c.action == "DescribeImages" {
					return imageResponse(), nil
				}
				if c.action == "DescribeSecurityGroupPolicies" {
					return policyResponse(), nil
				}
				return original(c)
			}
			if _, err := execute(context.Background(), h.api, "tencent_create", in); err == nil {
				t.Fatal("unsafe network was accepted")
			}
		})
	}
}
