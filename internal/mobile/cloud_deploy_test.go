package mobile

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestMobileCloudDeploymentPrivateKeyNeverCreatesKeyFile(t *testing.T) {
	root := t.TempDir()
	payload, err := json.Marshal(control.Request{
		Action: "deploy", Host: "192.0.2.1", Username: "root",
		PrivateKey: "invalid-sensitive-key", PKIDirectory: filepath.Join(root, "pki"),
	})
	if err != nil {
		t.Fatal(err)
	}
	result := Handle(payload, root)
	var response control.Response
	if json.Unmarshal(result, &response) != nil || response.Error != "SSH 私钥格式或口令无效" || bytes.Contains(result, []byte("sensitive")) {
		t.Fatal("mobile did not safely route the in-memory key to deployment")
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatal("in-memory cloud key was written to storage")
	}
}
