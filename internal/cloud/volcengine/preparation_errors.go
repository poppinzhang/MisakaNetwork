package volcengine

// Only exact fixed messages may cross the helper boundary with a stage. Never
// decorate arbitrary provider/transport errors: they may contain credentials or
// request URLs. Keep this catalog aligned with the Flutter preparation reasons.
var safePreparationReasons = map[string]bool{
	"火山引擎身份或权限校验失败，请检查访问密钥及授权":          true,
	"火山引擎配额或请求频率受限，请查询确认后重试":            true,
	"火山引擎账户余额不足":                        true,
	"火山引擎拒绝了资源参数，请核对模板和云端状态":            true,
	"火山引擎请求未成功，请查询确认操作结果":               true,
	"火山引擎请求参数无效":                        true,
	"火山引擎 API 凭据格式无效":                   true,
	"火山引擎网络请求未完成，结果可能未知，请查询核对":          true,
	"火山引擎服务域名解析失败，结果可能未知，请查询核对":         true,
	"火山引擎网络请求超时，结果可能未知，请查询核对":           true,
	"火山引擎 TLS 服务器证书验证失败，结果可能未知，请查询核对":   true,
	"火山引擎 TLS 服务器域名验证失败，结果可能未知，请查询核对":   true,
	"火山引擎网络访问被系统权限阻止，结果可能未知，请查询核对":      true,
	"火山引擎网络连接被拒绝，结果可能未知，请查询核对":          true,
	"火山引擎网络或目标主机不可达，结果可能未知，请查询核对":       true,
	"火山引擎网络连接中断，结果可能未知，请查询核对":           true,
	"火山引擎网络请求已取消，结果可能未知，请查询核对":          true,
	"火山引擎响应异常，请查询确认":                    true,
	"火山引擎响应格式异常，请查询确认":                  true,
	"火山引擎响应相互矛盾，请查询确认":                  true,
	"火山引擎响应字段异常，请查询确认":                  true,
	"火山引擎查询响应缺少资源列表，请重新查询":              true,
	"火山引擎查询资源列表格式异常，请重新查询":              true,
	"火山引擎查询分页结果不完整，请重新查询":               true,
	"火山引擎模板无效，请检查地域、镜像、系统盘与按流量公网 IP 配置": true,
	"模板镜像不存在或无权访问":                      true,
	"模板镜像必须是可用的 Linux 镜像，架构与系统盘须匹配":     true,
	"模板镜像不允许附带数据盘":                      true,
	"SSH 公钥必须是有效的 OpenSSH RSA 公钥":       true,
	"SSH 公钥无效":                    true,
	"SSH 公钥必须至少为 RSA 2048 位":      true,
	"云资源仍在准备中，请稍后重试查询确认":          true,
	"云资源准备未完成，请重试查询确认":            true,
	"云资源准备缺少已确认的 VPC":             true,
	"同名云密钥不唯一，请在控制台核对":            true,
	"同名云密钥的归属或指纹不匹配":              true,
	"SSH 密钥导入响应异常，请在控制台核对":        true,
	"安全组规则与固定策略不匹配，请在控制台核对":       true,
	"安全组归属或配置与项目不匹配":              true,
	"安全组查询响应不完整":                  true,
	"同名安全组不唯一，请在控制台核对":            true,
	"安全组创建结果与查询不符":                true,
	"火山引擎网络查询结果不完整，请重新查询":         true,
	"同名共享网络的归属或配置不匹配，请在火山引擎控制台核对": true,
	"共享网络尚未就绪，请稍后查询确认":            true,
	"共享 VPC 内没有可用的子网地址段":          true,
	"共享子网可用地址不足或未确认":              true,
}

type preparationFailure struct{ stage, reason string }

func (e *preparationFailure) Error() string { return e.stage + "：" + e.reason }

func preparationError(stage string, cause error) error {
	if cause == nil {
		return nil
	}
	reason := cause.Error()
	if !safePreparationReasons[reason] {
		reason = "云资源准备未完成，请重试查询确认"
	}
	return &preparationFailure{stage: stage, reason: reason}
}
