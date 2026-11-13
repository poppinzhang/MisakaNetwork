package aliyun

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTemplateAcceptsAdministratorOSAndSSHUsername(t *testing.T) {
	for _, os := range []string{"Ubuntu 26.04 LTS", "Debian 13", "Fedora 42", "Custom Linux"} {
		for _, username := range []string{"root", "ubuntu", "ecs-user", "custom_user", "_sisters"} {
			template := fixture()
			template.OS, template.SSHUsername = os, username
			data, err := json.Marshal(template)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := parseTemplate(data)
			if err != nil || parsed.OS != os || parsed.SSHUsername != username {
				t.Fatalf("OS/username not preserved: %q %q %v", os, username, err)
			}
		}
	}
}

func TestTemplateRequiresSafeSSHUsernameAndOSDisplayName(t *testing.T) {
	for _, username := range []string{"", " root", "root ", "Root", "root;command", "root\n", "a/b", "-root", strings.Repeat("a", 33)} {
		template := fixture()
		template.SSHUsername = username
		if template.Validate() == nil {
			t.Errorf("invalid SSH username accepted: %q", username)
		}
	}
	for _, os := range []string{"", " ", " Linux", "Linux ", "Linux\n", strings.Repeat("a", 129)} {
		template := fixture()
		template.OS = os
		if template.Validate() == nil {
			t.Errorf("invalid OS display name accepted: %q", os)
		}
	}
	template := fixture()
	data, _ := json.Marshal(template)
	var fields map[string]any
	json.Unmarshal(data, &fields)
	delete(fields, "sshUsername")
	data, _ = json.Marshal(fields)
	if _, err := parseTemplate(data); err == nil {
		t.Fatal("missing SSH username accepted")
	}
}
