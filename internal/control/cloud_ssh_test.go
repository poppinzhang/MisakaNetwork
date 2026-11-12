package control

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestCloudSSHKeyIsUsableRSAIdentity(t *testing.T) {
	response := Handle(Request{Action: "generate_cloud_ssh_key"})
	if !response.OK {
		t.Fatal("key generation failed")
	}
	key, ok := response.Result.(CloudSSHKey)
	if !ok {
		t.Fatal("missing structured key response")
	}
	private, err := ssh.ParseRawPrivateKey([]byte(key.PrivateKey))
	if err != nil {
		t.Fatal("private key is not valid PEM")
	}
	rsaKey, ok := private.(*rsa.PrivateKey)
	if !ok || rsaKey.N.BitLen() != 2048 || rsaKey.Validate() != nil {
		t.Fatal("private key is not a valid RSA-2048 key")
	}
	public, comment, options, rest, err := ssh.ParseAuthorizedKey([]byte(key.PublicKey))
	if err != nil || len(rest) != 0 || comment != "" || len(options) != 0 || public.Type() != ssh.KeyAlgoRSA {
		t.Fatal("public key is not a plain OpenSSH RSA key")
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil || !bytes.Equal(signer.PublicKey().Marshal(), public.Marshal()) {
		t.Fatal("public and private keys do not match")
	}
	message := []byte("LastOrder cloud SSH key verification")
	signature, err := signer.Sign(rand.Reader, message)
	if err != nil || public.Verify(message, signature) != nil {
		t.Fatal("key pair cannot sign and verify")
	}
	if key.Fingerprint != ssh.FingerprintSHA256(public) || !strings.HasPrefix(key.Fingerprint, "SHA256:") {
		t.Fatal("public fingerprint does not match")
	}
}

func TestCloudSSHKeysAreIndependent(t *testing.T) {
	first, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal("first key generation failed")
	}
	second, err := GenerateCloudSSHKey()
	if err != nil {
		t.Fatal("second key generation failed")
	}
	if first.PublicKey == second.PublicKey || first.PrivateKey == second.PrivateKey || first.Fingerprint == second.Fingerprint {
		t.Fatal("key generation reused an identity")
	}
}

func TestCloudSSHKeyFailureDoesNotExposePartialKey(t *testing.T) {
	response := cloudSSHKeyResponse(func() (CloudSSHKey, error) {
		return CloudSSHKey{PrivateKey: "partial-private-key"}, errors.New("sensitive-source-detail")
	})
	data, err := json.Marshal(response)
	if err != nil || response.OK || response.Result != nil || response.Error == "" {
		t.Fatal("generation failure was not reported safely")
	}
	if bytes.Contains(data, []byte("partial-private-key")) || bytes.Contains(data, []byte("sensitive-source-detail")) {
		t.Fatal("generation failure leaked private details")
	}
}
