package mobile

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
	"golang.org/x/crypto/ssh"
)

func TestHandleGeneratesCloudSSHKeyWithoutFiles(t *testing.T) {
	root := t.TempDir()
	var response struct {
		OK     bool                `json:"ok"`
		Result control.CloudSSHKey `json:"result"`
	}
	if err := json.Unmarshal(Handle([]byte(`{"action":"generate_cloud_ssh_key"}`), root), &response); err != nil || !response.OK {
		t.Fatal("mobile key generation failed")
	}
	if _, err := ssh.ParsePrivateKey([]byte(response.Result.PrivateKey)); err != nil {
		t.Fatal("mobile response omitted a usable private key")
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatal("mobile key generation wrote a file")
	}
}
