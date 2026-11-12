package control

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"strings"

	"golang.org/x/crypto/ssh"
)

// CloudSSHKey is sent only through the local helper response. LastOrder stores
// the private key in the platform's secure store; only PublicKey is intended
// for import into a cloud provider. This login-key fingerprint does not verify
// a server's SSH host key.
type CloudSSHKey struct {
	PrivateKey  string `json:"private_key"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint"`
}

// GenerateCloudSSHKey creates an independent RSA-2048 login identity, the
// common key format supported by all three initial cloud providers. Nothing is
// written to disk and no machine-specific comment is added to the public key.
func GenerateCloudSSHKey() (CloudSSHKey, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return CloudSSHKey{}, err
	}
	public, err := ssh.NewPublicKey(&key.PublicKey)
	if err != nil {
		return CloudSSHKey{}, err
	}
	return CloudSSHKey{
		PrivateKey: string(pem.EncodeToMemory(&pem.Block{
			Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key),
		})),
		PublicKey:   strings.TrimSpace(string(ssh.MarshalAuthorizedKey(public))),
		Fingerprint: ssh.FingerprintSHA256(public),
	}, nil
}

func cloudSSHKeyResponse(generate func() (CloudSSHKey, error)) Response {
	key, err := generate()
	if err != nil {
		// Never expose the source error or a partially generated identity.
		return Response{Error: "无法生成本机 SSH 登录密钥，请稍后重试"}
	}
	return Response{OK: true, Result: key}
}
