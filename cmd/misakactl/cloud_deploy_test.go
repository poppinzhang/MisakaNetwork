package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
)

func TestDesktopCloudDeploymentPrivateKeyUsesInputEnvelope(t *testing.T) {
	payload, err := json.Marshal(control.Request{
		Action: "deploy", Host: "192.0.2.1", Username: "root",
		PrivateKey: "invalid-sensitive-key", PKIDirectory: filepath.Join(t.TempDir(), "pki"),
	})
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	code := run(nil, bytes.NewReader(payload), &output)
	var response control.Response
	if code != 1 || json.Unmarshal(output.Bytes(), &response) != nil || response.Error != "SSH 私钥格式或口令无效" || strings.Contains(output.String(), "sensitive") {
		t.Fatal("desktop did not safely route the in-memory key to deployment")
	}
}
