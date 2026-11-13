package volcengine

import (
	"context"
	"errors"
	"net/url"
	"testing"
)

func TestSubnetEmptyResponsesAllowOneCreation(t *testing.T) {
	for _, empty := range []struct {
		name string
		rows any
	}{{"null", nil}, {"array", []networkSubnet{}}} {
		t.Run(empty.name, func(t *testing.T) {
			creates := 0
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				switch action {
				case "DescribeVpcs":
					return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
				case "DescribeSubnets":
					if creates == 0 {
						return map[string]any{"Subnets": empty.rows, "NextToken": ""}, nil
					}
					return map[string]any{"Subnets": []networkSubnet{validSubnet()}}, nil
				case "CreateSubnet":
					creates++
					if creates != 1 || q.Get("VpcId") != "vpc-fixture" || q.Get("CidrBlock") != "10.8.0.0/24" {
						t.Fatal("unexpected or repeated subnet creation")
					}
					return map[string]any{"SubnetId": "subnet-fixture"}, nil
				default:
					t.Fatal("unexpected action", action)
					return nil, nil
				}
			}}
			in := input()
			in.NetworkKind, in.SubnetID, in.SubnetCIDR = "subnet", "", ""
			planned, err := lookupNetwork(context.Background(), a, fixture(t), in)
			if err != nil || planned.Found || planned.SubnetID != "" || planned.SubnetCIDR != "10.8.0.0/24" {
				t.Fatalf("unexpected plan: %+v, %v", planned, err)
			}
			in.SubnetCIDR = planned.SubnetCIDR
			for range 2 {
				got := createNetwork(context.Background(), a, fixture(t), in)
				if got.State != "ready" || got.SubnetID != "subnet-fixture" {
					t.Fatalf("unexpected creation/reuse: %+v", got)
				}
			}
			if creates != 1 {
				t.Fatalf("created %d subnets", creates)
			}
		})
	}
}

func TestSubnetNullKeepsKnownIDWithoutRecreation(t *testing.T) {
	a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
		switch action {
		case "DescribeVpcs":
			return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
		case "DescribeSubnets":
			return map[string]any{"Subnets": nil}, nil
		default:
			t.Fatal("null query must not authorize another mutation", action)
			return nil, nil
		}
	}}
	in := input()
	in.NetworkKind = "subnet"
	got, err := lookupNetwork(context.Background(), a, fixture(t), in)
	if err != nil || got.Found || got.SubnetID != in.SubnetID || got.SubnetCIDR != in.SubnetCIDR {
		t.Fatalf("lost pending identity: %+v, %v", got, err)
	}
	created := createNetwork(context.Background(), a, fixture(t), in)
	if created.State != "unknown" || created.VpcID != in.VpcID || created.SubnetID != in.SubnetID || created.SubnetCIDR != in.SubnetCIDR {
		t.Fatalf("lost pending identity: %+v", created)
	}
	if err := verifyNetworkForPurchase(context.Background(), a, fixture(t), in); err == nil {
		t.Fatal("null query authorized an instance purchase")
	}
}

func TestSubnetCreatedIDSurvivesNullConfirmation(t *testing.T) {
	creates := 0
	a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
		switch action {
		case "DescribeVpcs":
			return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
		case "DescribeSubnets":
			return map[string]any{"Subnets": nil}, nil
		case "CreateSubnet":
			creates++
			return map[string]any{"SubnetId": "subnet-created"}, nil
		default:
			t.Fatal("unexpected action", action)
			return nil, nil
		}
	}}
	in := input()
	in.NetworkKind, in.SubnetID = "subnet", ""
	got := createNetwork(context.Background(), a, fixture(t), in)
	if got.State != "unknown" || got.SubnetID != "subnet-created" || got.SubnetCIDR != in.SubnetCIDR || creates != 1 {
		t.Fatalf("unexpected unconfirmed creation: %+v, creates=%d", got, creates)
	}
	in.SubnetID = got.SubnetID
	got = createNetwork(context.Background(), a, fixture(t), in)
	if got.State != "unknown" || got.SubnetID != in.SubnetID || creates != 1 {
		t.Fatalf("repeated pending creation: %+v, creates=%d", got, creates)
	}
}

func TestSubnetPendingWaitsWithoutRecreationOrPurchase(t *testing.T) {
	status := "Pending"
	a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
		switch action {
		case "DescribeVpcs":
			return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
		case "DescribeSubnets":
			s := validSubnet()
			s.Status = status
			if status == "Pending" {
				s.AvailableIpAddressCount = nil
			}
			return map[string]any{"Subnets": []networkSubnet{s}}, nil
		case "DescribeImages":
			return purchaseRead(action)
		default:
			t.Fatal("pending subnet authorized a mutation", action)
			return nil, nil
		}
	}}
	in := input()
	in.NetworkKind, in.SubnetID = "subnet", ""
	got, err := lookupNetwork(context.Background(), a, fixture(t), in)
	if err != nil || got.Found || got.SubnetID != "subnet-fixture" || got.SubnetCIDR != in.SubnetCIDR {
		t.Fatalf("pending response not pinned: %+v, %v", got, err)
	}
	created := createNetwork(context.Background(), a, fixture(t), in)
	if created.State != "unknown" || created.SubnetID != got.SubnetID {
		t.Fatalf("pending resource not preserved: %+v", created)
	}
	in.SubnetID = got.SubnetID
	if _, err = create(context.Background(), a, fixture(t), in); err == nil {
		t.Fatal("pending subnet allowed an instance purchase")
	}
	status = "Available"
	got, err = lookupNetwork(context.Background(), a, fixture(t), in)
	if err != nil || !got.Found || got.SubnetID != in.SubnetID {
		t.Fatalf("ready subnet was not recovered: %+v, %v", got, err)
	}
	if err = verifyNetworkForPurchase(context.Background(), a, fixture(t), in); err != nil {
		t.Fatalf("confirmed subnet remains unusable: %v", err)
	}
}

func TestSubnetNullFinalPagePreservesOccupiedCIDRs(t *testing.T) {
	subnetReads := 0
	a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
		if action == "DescribeVpcs" {
			return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
		}
		if action != "DescribeSubnets" {
			t.Fatal("unexpected action", action)
		}
		subnetReads++
		if subnetReads == 1 {
			s := validSubnet()
			s.SubnetName, s.CidrBlock = "another-subnet", "10.8.0.0/23"
			return map[string]any{"Subnets": []networkSubnet{s}, "NextToken": "last-page"}, nil
		}
		if subnetReads != 2 || q.Get("NextToken") != "last-page" {
			t.Fatal("incorrect pagination")
		}
		return map[string]any{"Subnets": nil, "NextToken": ""}, nil
	}}
	in := input()
	in.NetworkKind, in.SubnetID, in.SubnetCIDR = "subnet", "", ""
	got, err := lookupNetwork(context.Background(), a, fixture(t), in)
	if err != nil || got.Found || got.SubnetCIDR != "10.8.2.0/24" || subnetReads != 2 {
		t.Fatalf("lost previous-page allocations: %+v, %v, reads=%d", got, err, subnetReads)
	}
}

func TestSubnetAppearingBetweenPreflightReadsNeverCreatesDuplicate(t *testing.T) {
	for _, firstPage := range []struct {
		name string
		rows any
	}{{"null", nil}, {"array", []networkSubnet{}}} {
		t.Run(firstPage.name, func(t *testing.T) {
			reads := 0
			a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
				switch action {
				case "DescribeVpcs":
					return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
				case "DescribeSubnets":
					reads++
					if reads == 1 {
						return map[string]any{"Subnets": firstPage.rows}, nil
					}
					s := validSubnet()
					s.SubnetID, s.CidrBlock, s.Status = "subnet-concurrent", "10.8.1.0/24", "Pending"
					s.AvailableIpAddressCount = nil
					return map[string]any{"Subnets": []networkSubnet{s}}, nil
				default:
					t.Fatal("a concurrent same-name subnet authorized a duplicate", action)
					return nil, nil
				}
			}}
			in := input()
			in.NetworkKind, in.SubnetID = "subnet", ""
			got := createNetwork(context.Background(), a, fixture(t), in)
			if got.State != "rejected" || reads != 2 {
				t.Fatalf("newly visible same-name subnet was not rejected: %+v, reads=%d", got, reads)
			}
		})
	}
}

func TestSubnetPendingDoesNotBypassIdentityOrReadyAddressChecks(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*networkSubnet)
	}{
		{"pending-different-id", func(s *networkSubnet) { s.Status, s.SubnetID = "Pending", "subnet-other" }},
		{"pending-different-cidr", func(s *networkSubnet) { s.Status, s.CidrBlock = "Pending", "10.8.1.0/24" }},
		{"pending-foreign-tags", func(s *networkSubnet) { s.Status, s.Tags = "Pending", nil }},
		{"available-no-address-count", func(s *networkSubnet) { s.AvailableIpAddressCount = nil }},
		{"available-no-free-address", func(s *networkSubnet) { s.AvailableIpAddressCount = intp(0) }},
		{"missing-status", func(s *networkSubnet) { s.Status = "" }},
		{"unknown-status", func(s *networkSubnet) { s.Status = "Failed" }},
		{"unsupported-creating-status", func(s *networkSubnet) { s.Status = "Creating" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := validSubnet()
			tc.change(&s)
			a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
				switch action {
				case "DescribeVpcs":
					return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
				case "DescribeSubnets":
					return map[string]any{"Subnets": []networkSubnet{s}}, nil
				case "DescribeImages":
					return purchaseRead(action)
				default:
					t.Fatal("invalid subnet authorized a mutation", action)
					return nil, nil
				}
			}}
			in := input()
			in.NetworkKind = "subnet"
			if _, err := lookupNetwork(context.Background(), a, fixture(t), in); err == nil {
				t.Fatal("invalid subnet was accepted")
			}
			if _, err := create(context.Background(), a, fixture(t), in); err == nil {
				t.Fatal("invalid subnet authorized an instance purchase")
			}
		})
	}
}

func TestMalformedSubnetResponsesNeverCreate(t *testing.T) {
	cases := []struct {
		name string
		data map[string]any
	}{
		{"missing", map[string]any{}},
		{"object", map[string]any{"Subnets": map[string]any{}}},
		{"string", map[string]any{"Subnets": "null"}},
		{"number", map[string]any{"Subnets": 0}},
		{"boolean", map[string]any{"Subnets": false}},
		{"null-with-next-page", map[string]any{"Subnets": nil, "NextToken": "next"}},
		{"null-with-whitespace-token", map[string]any{"Subnets": nil, "NextToken": " "}},
		{"null-with-token-number", map[string]any{"Subnets": nil, "NextToken": 1}},
		{"null-with-token-object", map[string]any{"Subnets": nil, "NextToken": map[string]any{}}},
		{"array-with-token-boolean", map[string]any{"Subnets": []networkSubnet{}, "NextToken": false}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, failAt := range []int{1, 2} {
				reads := 0
				a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
					switch action {
					case "DescribeVpcs":
						return map[string]any{"Vpcs": []networkVpc{validVpc()}}, nil
					case "DescribeSubnets":
						reads++
						if reads == failAt {
							return tc.data, nil
						}
						return map[string]any{"Subnets": nil}, nil
					default:
						t.Fatal("malformed query authorized a mutation", action)
						return nil, nil
					}
				}}
				in := input()
				in.NetworkKind, in.SubnetID = "subnet", ""
				got := createNetwork(context.Background(), a, fixture(t), in)
				if got.State != "rejected" || reads != failAt {
					t.Fatalf("invalid response at read %d was not rejected: %+v, reads=%d", failAt, got, reads)
				}
			}
		})
	}
}

func TestNullListAllowanceIsExclusiveToPreparationLists(t *testing.T) {
	for _, tc := range []struct{ service, action, key string }{
		{"vpc", "DescribeVpcs", "Vpcs"},
		{"vpc", "DescribeSubnets", "Subnets"},
		{"vpc", "DescribeSecurityGroups", "SecurityGroups"},
		{"ecs", "DescribeImages", "Images"},
		{"ecs", "DescribeKeyPairs", "KeyPairs"},
	} {
		t.Run("allow/"+tc.action, func(t *testing.T) {
			a := &fakeAPI{t: t, f: func(string, url.Values) (any, error) {
				return map[string]any{tc.key: nil}, nil
			}}
			rows, err := pages[map[string]any](context.Background(), a, tc.service, "cn-beijing", tc.action, tc.key, params())
			if err != nil || len(rows) != 0 {
				t.Fatalf("explicit empty preparation list was rejected: rows=%d, %v", len(rows), err)
			}
		})
	}
	for _, tc := range []struct{ service, action, key string }{
		{"vpc", "DescribeEipAddresses", "EipAddresses"},
		{"ecs", "DescribeInstances", "Instances"},
		// Guard each part of the service/action/list-name exception.
		{"vpc", "DescribeVpcs", "Subnets"},
		{"vpc", "DescribeSubnets", "Vpcs"},
		{"ecs", "DescribeInstances", "Subnets"},
		{"ecs", "DescribeImages", "KeyPairs"},
		{"vpc", "DescribeSecurityGroups", "KeyPairs"},
	} {
		t.Run(tc.action+"/"+tc.key, func(t *testing.T) {
			a := &fakeAPI{t: t, f: func(string, url.Values) (any, error) {
				return map[string]any{tc.key: nil}, nil
			}}
			_, err := pages[map[string]any](context.Background(), a, tc.service, "cn-beijing", tc.action, tc.key, params())
			if !errors.Is(err, errNetworkResponse) {
				t.Fatalf("null %s was accepted outside the preparation exceptions: %v", tc.key, err)
			}
		})
	}
}
