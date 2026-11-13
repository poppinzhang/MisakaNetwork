package tencent

import (
	"context"
	"errors"
	"strings"
)

// VerifyCredential only authenticates the supplied key with STS. It does not
// authorize a purchase or establish CVM permissions, quotas, or account balance.
// https://cloud.tencent.com/document/product/1312/66098
func VerifyCredential(ctx context.Context, id, secret string) error {
	for _, value := range []string{id, secret} {
		if value == "" || len(value) > 2048 || strings.ContainsFunc(value, func(r rune) bool { return r < 33 || r > 126 }) {
			return errors.New("云 API 凭据格式无效")
		}
	}
	c := newClient(id, secret)
	defer c.http.CloseIdleConnections()
	return verifyCredential(ctx, c)
}

func verifyCredential(ctx context.Context, api caller) error {
	var identity struct{ AccountId, UserId, Arn, Type string }
	if err := api.call(ctx, "sts", "GetCallerIdentity", "ap-guangzhou", struct{}{}, &identity); err != nil {
		// The resource client's errors include mutation-specific advice. Keep
		// verification failures separate, and never expose an upstream response.
		return errors.New("腾讯云凭证联网验证未通过，请检查密钥、身份查询权限和网络后重试")
	}
	for _, value := range []string{identity.AccountId, identity.UserId, identity.Arn, identity.Type} {
		if strings.TrimSpace(value) == "" || len(value) > 2048 {
			return errors.New("腾讯云身份响应不完整，凭证未通过联网验证")
		}
	}
	return nil
}
