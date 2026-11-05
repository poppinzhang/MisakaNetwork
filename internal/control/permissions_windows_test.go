package control

import (
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func assertPrivateDACL(t *testing.T, name string, protected bool) {
	t.Helper()
	descriptor, err := windows.GetNamedSecurityInfo(name, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	flags, _, err := descriptor.Control()
	if err != nil || (protected && flags&windows.SE_DACL_PROTECTED == 0) {
		t.Fatalf("DACL not protected: %v", err)
	}
	acl, _, err := descriptor.DACL()
	if err != nil || acl == nil || acl.AceCount != 2 {
		t.Fatalf("unexpected private DACL: %v", err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{user.User.Sid.String(): false, "S-1-5-18": false}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			t.Fatal(err)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		const fileAllAccess = windows.STANDARD_RIGHTS_REQUIRED | windows.SYNCHRONIZE | 0x1ff
		if _, ok := allowed[sid]; !ok || ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Mask != fileAllAccess {
			t.Fatal("DACL grants unexpected access")
		}
		allowed[sid] = true
	}
	for _, present := range allowed {
		if !present {
			t.Fatal("private DACL missing expected account")
		}
	}
}

func TestWindowsPrivateDACLAndInheritance(t *testing.T) {
	dir := t.TempDir()
	if err := ProtectPath(dir); err != nil {
		t.Fatal(err)
	}
	assertPrivateDACL(t, dir, true)
	file := filepath.Join(dir, "credential")
	if err := os.WriteFile(file, []byte("test only"), 0600); err != nil {
		t.Fatal(err)
	}
	// The parent must protect newly created files before the first write.
	assertPrivateDACL(t, file, false)
	if err := ProtectPath(file); err != nil {
		t.Fatal(err)
	}
	assertPrivateDACL(t, file, true)
	pki := filepath.Join(dir, "pki")
	identity, err := InitPKI(pki)
	if err != nil {
		t.Fatal(err)
	}
	assertPrivateDACL(t, pki, true)
	for _, name := range []string{identity.CACert, identity.ClientCert, identity.ClientKey, filepath.Join(pki, "ca.key")} {
		assertPrivateDACL(t, name, true)
	}
}
