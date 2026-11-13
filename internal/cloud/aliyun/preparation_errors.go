package aliyun

// Only exact fixed messages may cross the helper boundary with a stage. Keep
// this catalog aligned with Flutter; provider text and URLs may carry secrets.
var safePreparationReasons = map[string]bool{
	"阿里云身份或权限校验失败，请检查 API 密钥及授权":       true,
	"阿里云配额或请求频率受限，请稍后查询结果":             true,
	"阿里云账户余额不足":                        true,
	"阿里云拒绝了资源参数，请检查模板与云端资源":            true,
	"阿里云请求未成功，请在控制台核对操作结果后重试查询":        true,
	"阿里云请求参数无效":                        true,
	"阿里云请求标识生成失败":                      true,
	"阿里云网络请求未完成，操作结果可能未知，请重新查询或到控制台核对": true,
	"阿里云响应异常，操作结果可能未知，请查询确认":           true,
	"阿里云响应缺少有效请求标识或格式异常，请查询确认操作结果":     true,
	"阿里云创建响应矛盾，请查询确认操作结果":              true,
	"阿里云服务响应异常，操作结果可能未知，请查询确认":         true,
	"阿里云 API 凭据格式无效":                   true,
	"阿里云分页查询结果不完整或格式异常，请重新查询":          true,
	"阿里云分页查询结果重复，请重新查询":                true,
	"阿里云分页查询模式异常，请重新查询":                true,
	"阿里云模板无效，请检查模板字段、地域、镜像、网络和按量计费配置":  true,
	"阿里云网络查询结果不完整或格式异常，请重新查询":          true,
	"共享网络尚未可见，请稍后查询确认":                 true,
	"同名共享网络的归属或配置不匹配，请在阿里云控制台核对":       true,
	"共享子网可用地址不足或尚未确认，请在阿里云控制台核对":       true,
	"共享 VPC 内没有可用的子网地址段，请在阿里云控制台核对":    true,
	"共享网络操作记录无效":                       true,
	"SSH 公钥必须是有效的 OpenSSH RSA 公钥":      true,
	"SSH 公钥无效":               true,
	"SSH 公钥必须至少为 RSA 2048 位": true,
	"模板镜像不存在或无权访问":           true,
	"模板镜像必须是可用的 Linux 镜像，架构与系统盘大小必须匹配":        true,
	"模板镜像不允许附带数据盘":                            true,
	"模板镜像必须仅包含一块系统盘，不允许附带数据盘":                 true,
	"模板镜像缺少磁盘映射信息，无法确认单系统盘配置":                 true,
	"模板镜像磁盘类型无法确认，已停止创建":                      true,
	"模板镜像系统盘映射与容量不匹配":                         true,
	"云资源仍在准备中，尚未提交服务器购买；请稍后重试查询确认":            true,
	"云资源与创建响应标识不匹配，请在控制台核对":                   true,
	"同名云资源不唯一，请在控制台核对":                        true,
	"同名云 SSH 密钥内容不匹配，已停止创建":                   true,
	"云 SSH 密钥导入结果异常，请在控制台核对":                  true,
	"同名安全组包含模板以外的规则，请在控制台核对":                  true,
	"同名安全组规则已改变，请在控制台核对":                      true,
	"安全组规则响应不完整或归属不匹配，已停止操作":                  true,
	"安全组分页响应异常，已停止操作":                         true,
	"安全组规则未完成，请重试准备操作":                        true,
	"同名安全组不是本应用的匹配配置，已停止创建":                   true,
	"安全组创建结果异常，请在控制台核对":                       true,
	"阿里云服务域名解析失败，操作结果可能未知，请重新查询或到控制台核对":       true,
	"阿里云网络请求超时，操作结果可能未知，请重新查询或到控制台核对":         true,
	"阿里云 TLS 服务器域名验证失败，操作结果可能未知，请重新查询或到控制台核对": true,
	"阿里云 TLS 服务器证书验证失败，操作结果可能未知，请重新查询或到控制台核对": true,
	"阿里云网络访问被系统权限阻止，操作结果可能未知，请重新查询或到控制台核对":    true,
	"阿里云网络连接被拒绝，操作结果可能未知，请重新查询或到控制台核对":        true,
	"阿里云网络或目标主机不可达，操作结果可能未知，请重新查询或到控制台核对":     true,
	"阿里云网络连接中断，操作结果可能未知，请重新查询或到控制台核对":         true,
	"阿里云网络请求已取消，操作结果可能未知，请重新查询或到控制台核对":        true,
	"云资源准备未完成，请重试查询确认":                        true,
}

type preparationFailure struct {
	stage, reason string
	cause         error
}

func (e *preparationFailure) Error() string { return e.stage + "：" + e.reason }
func (e *preparationFailure) Unwrap() error { return e.cause }

func preparationError(stage string, cause error) error {
	if cause == nil {
		return nil
	}
	switch stage {
	case "SSH 公钥检查", "共享 VPC 复核", "镜像检查", "SSH 公钥准备", "安全组准备":
	default:
		stage = "云资源准备"
	}
	reason := cause.Error()
	if !safePreparationReasons[reason] && !safeResponseReasons[reason] {
		reason = "云资源准备未完成，请重试查询确认"
	}
	return &preparationFailure{stage: stage, reason: reason, cause: cause}
}
