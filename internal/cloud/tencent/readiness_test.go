package tencent

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestPreparationWaitsForResourceAndPolicyVisibilityWithoutReplayingWrites(t *testing.T) {
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := ssh.NewPublicKey(&private.PublicKey)
	for _, loseResponse := range []bool{false, true} {
		t.Run(map[bool]string{false: "accepted", true: "lost-response"}[loseResponse], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var imported, created bool
				keyReads, groupReads, policyReads := 0, 0, 0
				writes := map[string]int{}
				visible := map[string]bool{}
				pendingReads := map[string]int{}
				api := &fakeAPI{t: t}
				api.respond = func(c callRecord) (any, error) {
					switch c.action {
					case "DescribeImages":
						return imageResponse(), nil
					case "DescribeKeyPairs":
						if imported {
							keyReads++
						}
						if keyReads < 3 {
							return map[string]any{"TotalCount": 0, "KeyPairSet": []any{}}, nil
						}
						return map[string]any{"TotalCount": 1, "KeyPairSet": []any{map[string]any{
							"KeyId": "skey-fixture", "KeyName": "misaka_" + sha(key.Marshal())[:18], "ProjectId": 0, "PublicKey": string(ssh.MarshalAuthorizedKey(key)),
						}}}, nil
					case "ImportKeyPair":
						writes[c.action]++
						imported = true
						if loseResponse {
							return nil, errors.New("lost mutation response")
						}
						return map[string]any{"KeyId": "skey-fixture"}, nil
					case "DescribeSecurityGroups":
						if created {
							groupReads++
						}
						if groupReads < 3 {
							return map[string]any{"TotalCount": 0, "SecurityGroupSet": []any{}}, nil
						}
						return map[string]any{"TotalCount": 1, "SecurityGroupSet": []any{map[string]any{
							"SecurityGroupId": "sg-fixture", "SecurityGroupName": groupName(), "SecurityGroupDesc": groupDescription, "ProjectId": "0",
						}}}, nil
					case "CreateSecurityGroup":
						writes[c.action]++
						created = true
						if loseResponse {
							return nil, errors.New("lost mutation response")
						}
						return map[string]any{"SecurityGroup": map[string]any{"SecurityGroupId": "sg-fixture"}}, nil
					case "DescribeSecurityGroupPolicies":
						policyReads++
						if policyReads < 3 {
							return nil, &apiError{code: "ResourceNotFound"}
						}
						for direction := range pendingReads {
							pendingReads[direction]++
							if pendingReads[direction] >= 3 {
								visible[direction] = true
							}
						}
						ingress, egress := expectedPolicies()
						if !visible["Ingress"] {
							ingress = nil
						}
						if !visible["Egress"] {
							egress = nil
						}
						return map[string]any{"SecurityGroupPolicySet": map[string]any{"Version": "1", "Ingress": ingress, "Egress": egress}}, nil
					case "CreateSecurityGroupPolicies":
						for direction, value := range c.body["SecurityGroupPolicySet"].(map[string]any) {
							writes[direction]++
							pendingReads[direction] = 0
							if direction == "Egress" {
								row := value.([]any)[0].(map[string]any)
								if row["Protocol"] != "ALL" || row["Port"] != nil {
									t.Fatal("ALL rule must omit mutually exclusive Port")
								}
							}
						}
						if loseResponse {
							return nil, errors.New("lost mutation response")
						}
						return map[string]any{"RequestId": "test-request"}, nil
					default:
						t.Fatalf("unexpected API %s", c.action)
						return nil, nil
					}
				}
				start := time.Now()
				out, err := prepare(context.Background(), api, fixtureTemplate(), string(ssh.MarshalAuthorizedKey(key)))
				if err != nil || out.KeyID != "skey-fixture" || out.SecurityGroupID != "sg-fixture" {
					t.Fatalf("eventually visible preparation: %+v %v", out, err)
				}
				if time.Since(start) < 10*time.Second {
					t.Fatal("did not wait for delayed visibility")
				}
				for _, action := range []string{"ImportKeyPair", "CreateSecurityGroup", "Ingress", "Egress"} {
					if writes[action] != 1 {
						t.Fatalf("%s written %d times", action, writes[action])
					}
				}
			})
		})
	}
}

func TestReadinessTimeoutCancellationAndConflictDoNotMutate(t *testing.T) {
	for _, mode := range []string{"timeout", "cancelled", "wrong-id", "permission"} {
		t.Run(mode, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				if mode == "cancelled" {
					cancel()
				}
				reads := 0
				start := time.Now()
				_, err := awaitPreparedID(ctx, func(context.Context) (string, error) {
					reads++
					if mode == "wrong-id" {
						return "sg-other", nil
					}
					if mode == "permission" {
						return "", &apiError{code: "UnauthorizedOperation"}
					}
					return "", nil
				}, "sg-fixture", nil)
				if err == nil {
					t.Fatal("unready resource accepted")
				}
				if mode == "timeout" && (time.Since(start) != 30*time.Second || reads < 2 || reads > 31) {
					t.Fatalf("unbounded wait: %v %d", time.Since(start), reads)
				}
				if mode != "timeout" && time.Since(start) != 0 {
					t.Fatal("terminal failure was retried")
				}
				if mode == "cancelled" && reads != 0 {
					t.Fatal("cancelled operation made request")
				}
			})
		})
	}
}

func TestPendingGroupRulesTimeoutOrDriftNeverRepeatWrite(t *testing.T) {
	for _, mode := range []string{"timeout", "drift", "permission", "rejected"} {
		t.Run(mode, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				writes := 0
				api := &fakeAPI{t: t, respond: func(c callRecord) (any, error) {
					if c.action == "CreateSecurityGroupPolicies" {
						writes++
						if mode == "rejected" {
							return nil, &apiError{code: "UnauthorizedOperation"}
						}
						return map[string]any{"RequestId": "test-request"}, nil
					}
					if c.action != "DescribeSecurityGroupPolicies" {
						t.Fatalf("unexpected API %s", c.action)
					}
					if writes > 0 && mode == "permission" {
						return nil, &apiError{code: "UnauthorizedOperation"}
					}
					ingress := []policy{}
					if writes > 0 && mode == "drift" {
						ingress = []policy{{Protocol: "ALL", Action: "ACCEPT", CidrBlock: "0.0.0.0/0"}}
					}
					return map[string]any{"SecurityGroupPolicySet": map[string]any{"Version": "1", "Ingress": ingress, "Egress": []policy{}}}, nil
				}}
				start := time.Now()
				if err := reconcilePolicies(context.Background(), api, fixtureTemplate(), "sg-fixture", true); err == nil {
					t.Fatal("unfinished or changed policy accepted")
				}
				if writes != 1 {
					t.Fatalf("policy mutation repeated: %d", writes)
				}
				if mode != "timeout" && time.Since(start) != 0 {
					t.Fatal("terminal failure waited instead of stopping")
				}
			})
		})
	}
}

func TestKnownNetworkMissingIsPendingNeverRecreated(t *testing.T) {
	for _, kind := range []string{"vpc", "subnet"} {
		t.Run(kind, func(t *testing.T) {
			h := newNetworkHarness(t)
			in := fixtureInput()
			in.NetworkKind = kind
			if kind == "subnet" {
				h.vpcs = []networkVpc{ownedVpc()}
			}
			found, err := lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
			if err != nil || found.Found || found.VpcID != in.VpcID || (kind == "subnet" && found.SubnetID != in.SubnetID) {
				t.Fatalf("pending network lost identity: %+v %v", found, err)
			}
			created := createNetwork(context.Background(), h.api, fixtureTemplate(), in)
			if created.State != "unknown" || networkMutations(h.api) != 0 {
				t.Fatal("known invisible network was recreated")
			}
			h.vpcs = []networkVpc{ownedVpc()}
			h.subnets = []networkSubnet{ownedSubnet(fixtureTemplate(), in.SubnetID, "10.8.0.0/24")}
			found, err = lookupNetwork(context.Background(), h.api, fixtureTemplate(), in)
			if err != nil || !found.Found {
				t.Fatalf("eventually visible network not recovered: %+v %v", found, err)
			}
		})
	}
}

func TestSubnetCannotCreateWhileParentVpcNotVisible(t *testing.T) {
	h := newNetworkHarness(t)
	in := fixtureInput()
	in.NetworkKind, in.SubnetID, in.SubnetCIDR = "subnet", "", "10.8.0.0/24"
	out := createNetwork(context.Background(), h.api, fixtureTemplate(), in)
	if out.State != "rejected" || networkMutations(h.api) != 0 || strings.Contains(out.Error, "sensitive") {
		t.Fatalf("subnet created before VPC readiness: %+v", out)
	}
}
