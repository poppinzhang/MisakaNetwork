package control

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const Version = "0.2.3"
const BiliVersion = "2.15.18"

type Identity struct {
	CACert     string `json:"ca_cert"`
	ClientCert string `json:"client_cert"`
	ClientKey  string `json:"client_key"`
}

func serial() *big.Int {
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		panic(err)
	}
	return n
}
func keyPEM(k *ecdsa.PrivateKey) ([]byte, error) {
	b, e := x509.MarshalPKCS8PrivateKey(k)
	if e != nil {
		return nil, e
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: b}), nil
}
func certPEM(template, parent *x509.Certificate, key *ecdsa.PrivateKey, signer any) ([]byte, error) {
	b, e := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, signer)
	if e != nil {
		return nil, e
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: b}), nil
}
func readCA(dir string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	pair, e := tls.LoadX509KeyPair(filepath.Join(dir, "ca.pem"), filepath.Join(dir, "ca.key"))
	if e != nil {
		return nil, nil, errors.New("无法读取控制端 CA，请检查证书目录")
	}
	cert, e := x509.ParseCertificate(pair.Certificate[0])
	if e != nil {
		return nil, nil, e
	}
	key, ok := pair.PrivateKey.(*ecdsa.PrivateKey)
	if !ok || !cert.IsCA || time.Until(cert.NotAfter) < 24*time.Hour {
		return nil, nil, errors.New("控制端 CA 无效或即将到期")
	}
	return cert, key, nil
}
func InitPKI(dir string) (Identity, error) {
	out := Identity{filepath.Join(dir, "ca.pem"), filepath.Join(dir, "client.pem"), filepath.Join(dir, "client.key")}
	if dir == "" || !filepath.IsAbs(dir) {
		return out, errors.New("证书目录必须为绝对路径")
	}
	if e := os.MkdirAll(dir, 0700); e != nil {
		return out, e
	}
	if e := ProtectPath(dir); e != nil {
		return out, e
	}
	names := []string{"ca.pem", "ca.key", "client.pem", "client.key"}
	count := 0
	for _, name := range names {
		if info, e := os.Lstat(filepath.Join(dir, name)); e == nil {
			if !info.Mode().IsRegular() {
				return out, errors.New("证书目录不能包含符号链接或非普通文件")
			}
			count++
		} else if !os.IsNotExist(e) {
			return out, e
		}
	}
	if count > 0 {
		if count != len(names) {
			return out, errors.New("证书目录不完整；请恢复完整证书，不会覆盖已有密钥")
		}
		ca, _, e := readCA(dir)
		if e != nil {
			return out, e
		}
		pair, e := tls.LoadX509KeyPair(out.ClientCert, out.ClientKey)
		if e != nil {
			return out, errors.New("客户端证书无效")
		}
		cert, e := x509.ParseCertificate(pair.Certificate[0])
		if e != nil {
			return out, e
		}
		roots := x509.NewCertPool()
		roots.AddCert(ca)
		if _, e = cert.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); e != nil {
			return out, errors.New("客户端证书过期或与 CA 不匹配")
		}
		for _, name := range names {
			if e = ProtectPath(filepath.Join(dir, name)); e != nil {
				return out, e
			}
		}
		return out, nil
	}
	key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		return out, e
	}
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "MisakaNetwork control CA"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(5, 0, 0), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
	cp, e := certPEM(ca, ca, key, key)
	if e != nil {
		return out, e
	}
	kp, e := keyPEM(key)
	if e != nil {
		return out, e
	}
	client, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		return out, e
	}
	ct := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "LastOrder"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(1, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	cc, e := certPEM(ct, ca, client, key)
	if e != nil {
		return out, e
	}
	ck, e := keyPEM(client)
	if e != nil {
		return out, e
	}
	for i, b := range [][]byte{cp, kp, cc, ck} {
		f, e := os.OpenFile(filepath.Join(dir, names[i]), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return out, e
		}
		_, e = f.Write(b)
		ce := f.Close()
		if e != nil {
			return out, e
		}
		if ce != nil {
			return out, ce
		}
		if e = ProtectPath(filepath.Join(dir, names[i])); e != nil {
			return out, e
		}
	}
	return out, nil
}
func ServerIdentity(dir, host string) (cert, key, ca []byte, err error) {
	parent, signer, e := readCA(dir)
	if e != nil {
		return nil, nil, nil, e
	}
	k, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		return nil, nil, nil, e
	}
	now := time.Now()
	t := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "Sisters"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(1, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	if ip := net.ParseIP(host); ip != nil {
		t.IPAddresses = []net.IP{ip}
	} else {
		t.DNSNames = []string{host}
	}
	cert, e = certPEM(t, parent, k, signer)
	if e != nil {
		return nil, nil, nil, e
	}
	key, e = keyPEM(k)
	if e != nil {
		return nil, nil, nil, e
	}
	ca, e = os.ReadFile(filepath.Join(dir, "ca.pem"))
	return cert, key, ca, e
}
