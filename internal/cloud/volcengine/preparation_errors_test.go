package volcengine

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestPreparationErrorExposesOnlyExactFixedReasons(t *testing.T) {
	for reason := range safePreparationReasons {
		got := preparationError("安全组准备", errors.New(reason))
		if got.Error() != "安全组准备："+reason {
			t.Fatal("fixed reason was not preserved")
		}
	}
	for _, cause := range []error{
		errors.New("sensitive-secret https://private.invalid/request"),
		errors.New("安全组查询响应不完整 sensitive-secret"),
		errors.New("sensitive-secret 安全组查询响应不完整"),
		fmt.Errorf("sensitive-secret: %w", errResourceListMissing),
	} {
		got := preparationError("SSH 公钥准备", cause)
		if got.Error() != "SSH 公钥准备：云资源准备未完成，请重试查询确认" || strings.Contains(got.Error(), "sensitive") {
			t.Fatal("unknown error was exposed")
		}
	}
	if preparationError("镜像检查", nil) != nil {
		t.Fatal("successful preparation acquired an error")
	}
}

func TestPreparationErrorKeepsSafeTypedAPIFailure(t *testing.T) {
	got := preparationError("安全组准备", &apiError{code: "InvalidArgument.sensitive-secret"})
	if got.Error() != "安全组准备：火山引擎拒绝了资源参数，请核对模板和云端状态" {
		t.Fatal("API category was not preserved without raw code")
	}
}
