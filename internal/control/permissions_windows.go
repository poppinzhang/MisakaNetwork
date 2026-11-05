package control

import (
	"errors"

	"golang.org/x/sys/windows"
)

func protectPath(name string, directory bool) error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return errors.New("无法确定 Windows 当前用户，未保存私有文件")
	}
	inherit := ""
	if directory {
		inherit = "OICI"
	}
	// Only this user and the local system account may access the directory.
	// OI/CI ensures newly created PKI files and imported credentials inherit
	// this restriction before any sensitive bytes are written.
	descriptor, err := windows.SecurityDescriptorFromString(
		"D:P(A;" + inherit + ";FA;;;" + user.User.Sid.String() + ")(A;" + inherit + ";FA;;;SY)")
	if err != nil {
		return errors.New("无法创建 Windows 私有文件权限")
	}
	acl, _, err := descriptor.DACL()
	if err != nil {
		return errors.New("无法读取 Windows 私有文件权限")
	}
	if err = windows.SetNamedSecurityInfo(name, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, acl, nil); err != nil {
		return errors.New("无法限制 Windows 私有文件权限，请使用支持访问控制的本地磁盘")
	}
	return nil
}
