package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
	"golang.org/x/crypto/ssh"
)

func TestCommandGeneratesCloudSSHKey(t *testing.T) {
	var output bytes.Buffer
	if code := run(nil, strings.NewReader(`{"action":"generate_cloud_ssh_key"}`), &output); code != 0 {
		t.Fatal("desktop key generation failed")
	}
	var response struct {
		OK     bool                `json:"ok"`
		Result control.CloudSSHKey `json:"result"`
	}
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || !response.OK {
		t.Fatal("desktop helper did not return one JSON response")
	}
	if _, err := ssh.ParsePrivateKey([]byte(response.Result.PrivateKey)); err != nil {
		t.Fatal("desktop response omitted a usable private key")
	}
}
