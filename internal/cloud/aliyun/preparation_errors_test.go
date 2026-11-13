package aliyun

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"testing"
)

func TestPreparationErrorExposesOnlyFixedStagesAndReasons(t *testing.T) {
	for reason := range safePreparationReasons {
		cause := errors.New(reason)
		got := preparationError("安全组准备", cause)
		if got.Error() != "安全组准备："+reason || !errors.Is(got, cause) {
			t.Fatal("fixed reason or internal error identity was lost")
		}
	}
	for _, cause := range []error{
		errors.New("sensitive-secret https://private.invalid/request"),
		errors.New("共享网络操作记录无效 sensitive-secret"),
		errors.New("sensitive-secret 共享网络操作记录无效"),
		fmt.Errorf("sensitive-secret: %w", errNetworkResponse),
	} {
		got := preparationError("SSH 公钥准备", cause)
		if got.Error() != "SSH 公钥准备：云资源准备未完成，请重试查询确认" || !errors.Is(got, cause) {
			t.Fatalf("unknown error was exposed or identity lost: %v", got)
		}
	}
	if got := preparationError("sensitive-secret stage", errNetworkNotVisible); got.Error() != "云资源准备："+errNetworkNotVisible.Error() {
		t.Fatalf("untrusted stage was exposed: %v", got)
	}
	if preparationError("镜像检查", nil) != nil {
		t.Fatal("successful preparation acquired an error")
	}
}

func TestPreparationErrorPreservesInternalTypedCause(t *testing.T) {
	cause := &apiError{code: "InvalidParameter.sensitive-secret"}
	got := preparationError("安全组准备", cause)
	var api *apiError
	if got.Error() != "安全组准备：阿里云拒绝了资源参数，请检查模板与云端资源" || !errors.As(got, &api) || api != cause {
		t.Fatalf("safe API category or typed cause lost: %v", got)
	}
	if !errors.Is(preparationError("安全组准备", errPreparationPending), errPreparationPending) {
		t.Fatal("pending preparation identity lost")
	}
}

func TestPreparationFailureIdentifiesStageAndStopsFurtherCalls(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for _, tc := range []struct{ action, stage string }{
		{"DescribeVpcs", "共享 VPC 复核"},
		{"DescribeImages", "镜像检查"},
		{"DescribeKeyPairs", "SSH 公钥准备"},
		{"DescribeSecurityGroups", "安全组准备"},
		{"DescribeSecurityGroupAttribute", "安全组准备"},
	} {
		for _, reason := range []string{
			"阿里云网络请求超时，操作结果可能未知，请重新查询或到控制台核对",
			"阿里云身份或权限校验失败，请检查 API 密钥及授权",
			"sensitive-secret https://private.invalid/request",
		} {
			t.Run(tc.action+"/"+strings.Split(reason, "，")[0], func(t *testing.T) {
				failed := false
				cause := errors.New(reason)
				base := fixtureAPI(t, key, nil)
				api := fake(func(ctx context.Context, service, action, region string, query url.Values, out any) error {
					if failed {
						t.Fatalf("failed preparation continued with %s", action)
					}
					if !strings.HasPrefix(action, "Describe") {
						t.Fatalf("unexpected mutation before read failure: %s", action)
					}
					if action == tc.action {
						failed = true
						return cause
					}
					return base(ctx, service, action, region, query, out)
				})
				got, err := prepare(context.Background(), api, fixture(), input)
				wantReason := reason
				if !safePreparationReasons[reason] {
					wantReason = "云资源准备未完成，请重试查询确认"
				}
				if !failed || got != (Prepared{}) || err == nil || err.Error() != tc.stage+"："+wantReason || !errors.Is(err, cause) {
					t.Fatalf("unexpected stage result: %+v, %v", got, err)
				}
			})
		}
	}
}

func TestPreparationLocalValidationDoesNotCallCloud(t *testing.T) {
	for _, tc := range []struct {
		name, stage string
		change      func(*Input)
	}{
		{"invalid VPC", "共享 VPC 复核", func(in *Input) { in.VpcID = "invalid" }},
		{"invalid public key", "SSH 公钥检查", func(in *Input) { in.PublicKey = "sensitive-secret" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := Input{VpcID: "vpc-fixture"}
			tc.change(&in)
			api := fake(func(context.Context, string, string, string, url.Values, any) error {
				t.Fatal("local validation called cloud")
				return nil
			})
			_, err := prepare(context.Background(), api, fixture(), in)
			if err == nil || !strings.HasPrefix(err.Error(), tc.stage+"：") || strings.Contains(err.Error(), "sensitive") {
				t.Fatalf("incorrect local diagnostic: %v", err)
			}
		})
	}
}

func TestPreparationMissingVpcKeepsPendingCause(t *testing.T) {
	key := fixtureKey(t)
	api := fixtureAPI(t, key, func(action string, _ url.Values, out map[string]any) error {
		if action != "DescribeVpcs" {
			t.Fatalf("missing VPC continued preparation: %s", action)
		}
		out["TotalCount"] = 0
		out["Vpcs"] = map[string]any{"Vpc": []any{}}
		return nil
	})
	_, err := prepare(context.Background(), api, fixture(), createInput(key))
	if !errors.Is(err, errNetworkNotVisible) || err.Error() != "共享 VPC 复核："+errNetworkNotVisible.Error() {
		t.Fatalf("pending VPC cause lost: %v", err)
	}
}

func TestPreparationLostMutationResponseRecoversWithoutRepeatingWrite(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for _, tc := range []struct {
		mutation, lookup, container, item string
	}{
		{"ImportKeyPair", "DescribeKeyPairs", "KeyPairs", "KeyPair"},
		{"CreateSecurityGroup", "DescribeSecurityGroups", "SecurityGroups", "SecurityGroup"},
	} {
		t.Run(tc.mutation, func(t *testing.T) {
			writes, lookups := 0, 0
			base := fixtureAPI(t, key, func(action string, _ url.Values, out map[string]any) error {
				if action == tc.lookup {
					lookups++
					if writes == 0 {
						out["TotalCount"] = 0
						out[tc.container] = map[string]any{tc.item: []any{}}
					}
				}
				return nil
			})
			api := fake(func(ctx context.Context, service, action, region string, query url.Values, out any) error {
				if action == tc.mutation {
					writes++
					return errors.New("sensitive-secret lost mutation response")
				}
				if !strings.HasPrefix(action, "Describe") {
					t.Fatalf("unexpected subsequent mutation: %s", action)
				}
				return base(ctx, service, action, region, query, out)
			})
			got, err := prepare(context.Background(), api, fixture(), input)
			if err != nil || got.KeyID != input.KeyID || got.SecurityGroupID != input.SecurityGroupID || writes != 1 || lookups != 2 {
				t.Fatalf("lost response was not recovered once: %+v, %v, writes=%d, lookups=%d", got, err, writes, lookups)
			}
		})
	}
}

func TestPreparationMutationRecoveryFailureKeepsStageWithoutReplay(t *testing.T) {
	key := fixtureKey(t)
	input := createInput(key)
	for _, tc := range []struct {
		mutation, lookup, container, item, stage string
	}{
		{"ImportKeyPair", "DescribeKeyPairs", "KeyPairs", "KeyPair", "SSH 公钥准备"},
		{"CreateSecurityGroup", "DescribeSecurityGroups", "SecurityGroups", "SecurityGroup", "安全组准备"},
	} {
		t.Run(tc.mutation, func(t *testing.T) {
			writes, lookups := 0, 0
			cause := errors.New("阿里云网络连接中断，操作结果可能未知，请重新查询或到控制台核对")
			base := fixtureAPI(t, key, func(action string, _ url.Values, out map[string]any) error {
				if action == tc.lookup {
					lookups++
					if writes > 0 {
						return cause
					}
					out["TotalCount"] = 0
					out[tc.container] = map[string]any{tc.item: []any{}}
				}
				return nil
			})
			api := fake(func(ctx context.Context, service, action, region string, query url.Values, out any) error {
				if action == tc.mutation {
					writes++
					return errors.New("sensitive-secret lost mutation response")
				}
				if !strings.HasPrefix(action, "Describe") || writes > 0 && action != tc.lookup {
					t.Fatalf("unknown result continued with %s", action)
				}
				return base(ctx, service, action, region, query, out)
			})
			got, err := prepare(context.Background(), api, fixture(), input)
			if err == nil || got != (Prepared{}) || err.Error() != tc.stage+"："+cause.Error() || !errors.Is(err, cause) || writes != 1 || lookups != 2 {
				t.Fatalf("unknown result diagnostic/replay: %+v, %v, writes=%d, lookups=%d", got, err, writes, lookups)
			}
		})
	}
}
