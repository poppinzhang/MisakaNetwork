package aliyun

import (
	"encoding/json"
	"errors"
)

type responseFailureKind uint8

const (
	responseReadFailure responseFailureKind = iota
	responseTooLarge
	responseHTTPStatus
	responseFieldType
)

const (
	responseReadReason       = "阿里云响应读取失败，操作结果可能未知，请查询确认"
	responseTooLargeReason   = "阿里云响应超过大小限制，操作结果可能未知，请查询确认"
	responseHTTPReason       = "阿里云 HTTP 响应状态异常，操作结果可能未知，请查询确认"
	responseFieldReason      = "阿里云响应字段格式异常，操作结果可能未知，请查询确认"
	groupResponseReadReason  = "阿里云安全组规则查询响应读取失败，操作结果可能未知，请查询确认"
	groupResponseSizeReason  = "阿里云安全组规则查询响应超过大小限制，操作结果可能未知，请查询确认"
	groupResponseHTTPReason  = "阿里云安全组规则查询 HTTP 响应状态异常，操作结果可能未知，请查询确认"
	groupResponseFieldReason = "阿里云安全组规则查询响应字段格式异常，操作结果可能未知，请查询确认"
	groupPriorityTypeReason  = "阿里云安全组规则优先级字段格式异常，操作结果可能未知，请查询确认"
	groupRuleListTypeReason  = "阿里云安全组规则列表字段格式异常，操作结果可能未知，请查询确认"
	groupPageTokenTypeReason = "阿里云安全组分页标记字段格式异常，操作结果可能未知，请查询确认"
	groupOwnershipTypeReason = "阿里云安全组归属字段格式异常，操作结果可能未知，请查询确认"
	groupRuleTypeReason      = "阿里云安全组规则内容字段格式异常，操作结果可能未知，请查询确认"
)

// A separate fixed catalog lets the preparation boundary retain these reasons
// without accepting arbitrary prefixes, API names, JSON paths or error text.
var safeResponseReasons = map[string]bool{
	responseReadReason: true, responseTooLargeReason: true,
	responseHTTPReason: true, responseFieldReason: true,
	groupResponseReadReason: true, groupResponseSizeReason: true,
	groupResponseHTTPReason: true, groupResponseFieldReason: true,
	groupPriorityTypeReason: true, groupRuleListTypeReason: true,
	groupPageTokenTypeReason: true, groupOwnershipTypeReason: true,
	groupRuleTypeReason: true,
}

// responseError is a display-only classification. Never return the raw cause:
// JSON type errors can contain response values or provider-controlled paths.
// These failures do not prove rejection, and must not acquire retry semantics.
func responseError(action string, kind responseFailureKind, cause error) error {
	if action == "DescribeSecurityGroupAttribute" {
		switch kind {
		case responseReadFailure:
			return errors.New(groupResponseReadReason)
		case responseTooLarge:
			return errors.New(groupResponseSizeReason)
		case responseHTTPStatus:
			return errors.New(groupResponseHTTPReason)
		case responseFieldType:
			return errors.New(securityGroupFieldReason(cause))
		}
	}
	switch kind {
	case responseReadFailure:
		return errors.New(responseReadReason)
	case responseTooLarge:
		return errors.New(responseTooLargeReason)
	case responseHTTPStatus:
		return errors.New(responseHTTPReason)
	default:
		return errors.New(responseFieldReason)
	}
}

func securityGroupFieldReason(cause error) string {
	var field *json.UnmarshalTypeError
	if !errors.As(cause, &field) {
		return groupResponseFieldReason
	}
	switch field.Field {
	case "Priority", "Permissions.Permission.Priority":
		return groupPriorityTypeReason
	case "Permissions", "Permissions.Permission":
		return groupRuleListTypeReason
	case "NextToken":
		return groupPageTokenTypeReason
	case "SecurityGroupId", "VpcId", "SecurityGroupName", "Description", "InnerAccessPolicy":
		return groupOwnershipTypeReason
	}
	// The custom permission decoder can return a bare field name or include
	// its embedded fields alias. The enclosing decoder can prefix either with
	// the complete path. Match only these fixed forms of known rule fields.
	for _, name := range []string{
		"SecurityGroupRuleId", "Direction", "IpProtocol", "PortRange", "SourceCidrIp", "DestCidrIp",
		"Ipv6SourceCidrIp", "Ipv6DestCidrIp", "SourceGroupId", "DestGroupId", "SourcePrefixListId",
		"DestPrefixListId", "SourcePortRange", "PortRangeListId", "Policy", "NicType",
	} {
		if field.Field == name || field.Field == "Permissions.Permission."+name || field.Field == "fields."+name || field.Field == "Permissions.Permission.fields."+name {
			return groupRuleTypeReason
		}
	}
	return groupResponseFieldReason
}
