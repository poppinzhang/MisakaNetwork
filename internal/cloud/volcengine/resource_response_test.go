package volcengine

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func resourceTestKey(t *testing.T) ssh.PublicKey {
	t.Helper()
	r, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	k, err := ssh.NewPublicKey(&r.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func resourceKeyRow(k ssh.PublicKey) map[string]any {
	return map[string]any{
		"KeyPairId": "kp-fixture", "KeyPairName": cloudKeyName(k),
		"FingerPrint": normalizedMD5(ssh.FingerprintLegacyMD5(k)),
		"Tags":        []tag{{managedTag, managedValue}},
	}
}

func preparedResourceRead(action string, k ssh.PublicKey) (any, error) {
	switch action {
	case "DescribeKeyPairs":
		return map[string]any{"KeyPairs": []any{resourceKeyRow(k)}}, nil
	case "DescribeSecurityGroups":
		return map[string]any{"SecurityGroups": []group{validGroup()}}, nil
	default:
		return purchaseRead(action)
	}
}

func TestPrepareEmptyKeysAndGroupsCreateOnceThenReuse(t *testing.T) {
	k := resourceTestKey(t)
	for _, empty := range []struct {
		name string
		rows any
	}{{"null", nil}, {"array", []any{}}} {
		t.Run(empty.name, func(t *testing.T) {
			imports, groups := 0, 0
			a := &fakeAPI{t: t, f: func(action string, q url.Values) (any, error) {
				switch action {
				case "DescribeKeyPairs":
					if imports == 0 {
						return map[string]any{"KeyPairs": empty.rows}, nil
					}
				case "DescribeSecurityGroups":
					if groups == 0 {
						return map[string]any{"SecurityGroups": empty.rows}, nil
					}
				case "ImportKeyPair":
					imports++
					if imports != 1 || q.Get("KeyPairName") != cloudKeyName(k) || q.Get("PublicKey") != strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k))) {
						t.Fatal("unexpected or repeated public key import")
					}
					return resourceKeyRow(k), nil
				case "CreateSecurityGroup":
					groups++
					if groups != 1 || q.Get("VpcId") != "vpc-fixture" || q.Get("SecurityGroupName") != groupName {
						t.Fatal("unexpected or repeated security group creation")
					}
					return map[string]any{"SecurityGroupId": "sg-fixture"}, nil
				}
				value, err := preparedResourceRead(action, k)
				if err != nil {
					t.Fatal("unexpected downstream action", action)
				}
				return value, err
			}}
			in := input()
			in.PublicKey = string(ssh.MarshalAuthorizedKey(k))
			for range 2 {
				got, err := prepare(context.Background(), a, fixture(t), in)
				if err != nil || got.KeyID != cloudKeyName(k) || got.SecurityGroupID != "sg-fixture" {
					t.Fatalf("preparation/reuse failed: %+v, %v", got, err)
				}
			}
			if imports != 1 || groups != 1 {
				t.Fatalf("imports=%d groups=%d", imports, groups)
			}
		})
	}
}

func TestPrepareResponseFailuresIdentifyStageAndStopDownstream(t *testing.T) {
	k := resourceTestKey(t)
	incompleteGroup := validGroup()
	incompleteGroup.Permissions = nil
	order := []string{"DescribeImages", "DescribeVpcs", "DescribeKeyPairs", "DescribeSecurityGroups", "DescribeSecurityGroupAttributes"}
	for _, tc := range []struct {
		name, action, stage, reason string
		response                    any
		err                         error
	}{
		{"image-list-missing", "DescribeImages", "镜像检查", "火山引擎查询响应缺少资源列表，请重新查询", map[string]any{}, nil},
		{"vpc-list-missing", "DescribeVpcs", "共享 VPC 复核", "火山引擎查询响应缺少资源列表，请重新查询", map[string]any{}, nil},
		{"null-vpc-list", "DescribeVpcs", "共享 VPC 复核", "共享网络尚未就绪，请稍后查询确认", map[string]any{"Vpcs": nil}, nil},
		{"key-list-missing", "DescribeKeyPairs", "SSH 公钥准备", "火山引擎查询响应缺少资源列表，请重新查询", map[string]any{}, nil},
		{"group-list-missing", "DescribeSecurityGroups", "安全组准备", "火山引擎查询响应缺少资源列表，请重新查询", map[string]any{}, nil},
		{"key-list-malformed", "DescribeKeyPairs", "SSH 公钥准备", "火山引擎查询资源列表格式异常，请重新查询", map[string]any{"KeyPairs": false}, nil},
		{"group-page-incomplete", "DescribeSecurityGroups", "安全组准备", "火山引擎查询分页结果不完整，请重新查询", map[string]any{"SecurityGroups": nil, "NextToken": "next"}, nil},
		{"group-permissions-null", "DescribeSecurityGroupAttributes", "安全组准备", "安全组查询响应不完整", incompleteGroup, nil},
		{"empty-image-list", "DescribeImages", "镜像检查", "模板镜像不存在或无权访问", map[string]any{"Images": []any{}}, nil},
		{"null-image-list", "DescribeImages", "镜像检查", "模板镜像不存在或无权访问", map[string]any{"Images": nil}, nil},
		{"unknown-key-error", "DescribeKeyPairs", "SSH 公钥准备", "云资源准备未完成，请重试查询确认", nil, errors.New("secret-upstream-detail")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
				if action == tc.action {
					return tc.response, tc.err
				}
				value, err := preparedResourceRead(action, k)
				if err != nil {
					t.Fatal("failure authorized a downstream mutation", action)
				}
				return value, err
			}}
			in := input()
			in.PublicKey = string(ssh.MarshalAuthorizedKey(k))
			_, err := prepare(context.Background(), a, fixture(t), in)
			if err == nil || !strings.HasPrefix(err.Error(), tc.stage+"：") || !strings.Contains(err.Error(), tc.reason) || strings.Contains(err.Error(), "secret-upstream-detail") {
				t.Fatalf("wrong preparation diagnostic: %v", err)
			}
			want := order[:slices.Index(order, tc.action)+1]
			if tc.name == "empty-image-list" || tc.name == "null-image-list" {
				// Empty image sources are exhausted before reporting absence;
				// none of these lookups authorizes network or key preparation.
				want = []string{"DescribeImages", "DescribeImages", "DescribeImages", "DescribeImages"}
			}
			if !slices.Equal(a.calls, want) {
				t.Fatalf("continued after failure: %v, want %v", a.calls, want)
			}
		})
	}
	t.Run("public-key-validation", func(t *testing.T) {
		a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
			t.Fatal("invalid key reached the API", action)
			return nil, nil
		}}
		in := input()
		in.PublicKey = "invalid-public-key"
		if _, err := prepare(context.Background(), a, fixture(t), in); err == nil || !strings.HasPrefix(err.Error(), "SSH 公钥检查：") {
			t.Fatalf("wrong public key diagnostic: %v", err)
		}
	})
}

func TestPreparationListResponsesStillFailClosed(t *testing.T) {
	for _, operation := range []struct{ service, action, key string }{
		{"vpc", "DescribeVpcs", "Vpcs"},
		{"vpc", "DescribeSubnets", "Subnets"},
		{"vpc", "DescribeSecurityGroups", "SecurityGroups"},
		{"ecs", "DescribeImages", "Images"},
		{"ecs", "DescribeKeyPairs", "KeyPairs"},
	} {
		for _, tc := range []struct {
			name, reason string
			response     map[string]any
		}{
			{"missing", "火山引擎查询响应缺少资源列表，请重新查询", map[string]any{}},
			{"object", "火山引擎查询资源列表格式异常，请重新查询", map[string]any{operation.key: map[string]any{}}},
			{"string-null", "火山引擎查询资源列表格式异常，请重新查询", map[string]any{operation.key: "null"}},
			{"oversized-list", "火山引擎查询分页结果不完整，请重新查询", map[string]any{operation.key: make([]map[string]any, 101)}},
			{"null-with-next", "火山引擎查询分页结果不完整，请重新查询", map[string]any{operation.key: nil, "NextToken": "next"}},
			{"null-with-malformed-token", "火山引擎查询分页结果不完整，请重新查询", map[string]any{operation.key: nil, "NextToken": false}},
		} {
			t.Run(operation.action+"/"+tc.name, func(t *testing.T) {
				a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
					if action != operation.action {
						t.Fatal("unexpected query", action)
					}
					return tc.response, nil
				}}
				_, err := pages[map[string]any](context.Background(), a, operation.service, "cn-beijing", operation.action, operation.key, params())
				if !errors.Is(err, errNetworkResponse) || err.Error() != tc.reason || len(a.calls) != 1 {
					t.Fatalf("wrong malformed list result: %v, calls=%d", err, len(a.calls))
				}
			})
		}
	}
}

func TestPreparationMutationWaitsThroughNullWithoutReplay(t *testing.T) {
	k := resourceTestKey(t)
	for _, kind := range []string{"key", "group"} {
		t.Run(kind, func(t *testing.T) {
			writes, reads := 0, 0
			lookup, mutation, list := "DescribeKeyPairs", "ImportKeyPair", "KeyPairs"
			if kind == "group" {
				lookup, mutation, list = "DescribeSecurityGroups", "CreateSecurityGroup", "SecurityGroups"
			}
			a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
				if action == lookup {
					reads++
					if reads <= 2 {
						return map[string]any{list: nil}, nil
					}
					return preparedResourceRead(action, k)
				}
				if action == mutation {
					writes++
					// The mutation reached the cloud, but its reply was lost.
					return nil, errors.New("response-lost")
				}
				if action == "DescribeSecurityGroupAttributes" {
					return validGroup(), nil
				}
				t.Fatal("unexpected action while awaiting visibility", action)
				return nil, nil
			}}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var err error
			if kind == "key" {
				_, err = ensureKey(ctx, a, "cn-beijing", k)
			} else {
				_, err = ensureGroup(ctx, a, fixture(t), "vpc-fixture")
			}
			if err != nil || writes != 1 || reads != 3 {
				t.Fatalf("visibility recovery: writes=%d reads=%d err=%v", writes, reads, err)
			}
		})
	}
}

func TestPreparationNullAfterMutationHonorsCancellation(t *testing.T) {
	k := resourceTestKey(t)
	for _, kind := range []string{"key", "group"} {
		for _, loseResponse := range []bool{false, true} {
			name := kind + "/confirmed-write"
			if loseResponse {
				name = kind + "/lost-response"
			}
			t.Run(name, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				writes, reads := 0, 0
				lookup, mutation, list := "DescribeKeyPairs", "ImportKeyPair", "KeyPairs"
				if kind == "group" {
					lookup, mutation, list = "DescribeSecurityGroups", "CreateSecurityGroup", "SecurityGroups"
				}
				a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
					if action == lookup {
						reads++
						if writes > 0 {
							cancel()
						}
						return map[string]any{list: nil}, nil
					}
					if action == mutation {
						writes++
						if loseResponse {
							return nil, errors.New("response-lost")
						}
						if kind == "key" {
							return resourceKeyRow(k), nil
						}
						return map[string]any{"SecurityGroupId": "sg-fixture"}, nil
					}
					t.Fatal("cancellation continued preparation", action)
					return nil, nil
				}}
				var err error
				if kind == "key" {
					_, err = ensureKey(ctx, a, "cn-beijing", k)
				} else {
					_, err = ensureGroup(ctx, a, fixture(t), "vpc-fixture")
				}
				if !errors.Is(err, errPreparationPending) || writes != 1 || reads != 2 {
					t.Fatalf("cancelled visibility wait: writes=%d reads=%d err=%v", writes, reads, err)
				}
			})
		}
	}
}

func TestCreatingSecurityGroupWaitsForPermissionsWithoutMutations(t *testing.T) {
	attributeReads := 0
	a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
		switch action {
		case "DescribeSecurityGroups":
			g := validGroup()
			g.Status, g.Permissions = "Creating", nil
			return map[string]any{"SecurityGroups": []group{g}}, nil
		case "DescribeSecurityGroupAttributes":
			attributeReads++
			g := validGroup()
			if attributeReads == 1 {
				g.Status, g.Permissions = "Creating", nil
			}
			return g, nil
		default:
			t.Fatal("waiting for a creating group triggered a mutation", action)
			return nil, nil
		}
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	id, err := ensureGroup(ctx, a, fixture(t), "vpc-fixture")
	if err != nil || id != "sg-fixture" || attributeReads != 2 {
		t.Fatalf("creating group was not recovered: id=%s reads=%d err=%v", id, attributeReads, err)
	}
}

func TestSecurityGroupIncompleteReadyOrUnknownStatusNeverAuthorizes(t *testing.T) {
	for _, status := range []string{"Available", "", "Pending", "Failed"} {
		t.Run(status, func(t *testing.T) {
			attributeReads := 0
			a := &fakeAPI{t: t, f: func(action string, _ url.Values) (any, error) {
				switch action {
				case "DescribeSecurityGroups":
					return map[string]any{"SecurityGroups": []group{validGroup()}}, nil
				case "DescribeSecurityGroupAttributes":
					attributeReads++
					g := validGroup()
					g.Status = status
					if status == "Available" {
						g.Permissions = nil
					}
					return g, nil
				default:
					t.Fatal("incomplete group triggered a mutation", action)
					return nil, nil
				}
			}}
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			_, err := ensureGroup(ctx, a, fixture(t), "vpc-fixture")
			if err == nil || err.Error() != "安全组查询响应不完整" || attributeReads != 1 {
				t.Fatalf("incomplete group not rejected: reads=%d err=%v", attributeReads, err)
			}
		})
	}
}
