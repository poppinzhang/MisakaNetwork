package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

func tlsFixture(t *testing.T) (Config, *tls.Config) {
	t.Helper()
	dir := t.TempDir()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	caPath := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caPath, caPEM, 0600); err != nil {
		t.Fatal(err)
	}
	issue := func(name string, serial int64, usage x509.ExtKeyUsage) (tls.Certificate, string, string) {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		cert := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name}, DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}}
		der, err := x509.CreateCertificate(rand.Reader, cert, ca, pub, key)
		if err != nil {
			t.Fatal(err)
		}
		keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
		if err != nil {
			t.Fatal(err)
		}
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
		certPath, keyPath := filepath.Join(dir, name+".pem"), filepath.Join(dir, name+".key")
		if err := os.WriteFile(certPath, certPEM, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
			t.Fatal(err)
		}
		pair, err := tls.X509KeyPair(certPEM, keyPEM)
		if err != nil {
			t.Fatal(err)
		}
		return pair, certPath, keyPath
	}
	_, certPath, keyPath := issue("server", 2, x509.ExtKeyUsageServerAuth)
	client, _, _ := issue("client", 3, x509.ExtKeyUsageClientAuth)
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	return Config{Listen: "127.0.0.1:0", Cert: certPath, Key: keyPath, CA: caPath, Runtime: "unused", MaxConcurrency: 1, QueueCapacity: 1, HistoryCapacity: 2}, &tls.Config{MinVersion: tls.VersionTLS12, ServerName: "localhost", RootCAs: pool, Certificates: []tls.Certificate{client}}
}

func TestGRPCRequiresMutualTLS(t *testing.T) {
	c, clientTLS := tlsFixture(t)
	serverTLS, err := ServerTLS(c)
	if err != nil {
		t.Fatal(err)
	}
	if serverTLS.MinVersion < tls.VersionTLS12 || serverTLS.ClientAuth != tls.RequireAndVerifyClientCert {
		t.Fatal("weak TLS configuration")
	}
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer lis.Close()
	s := testService(t, &fakeRunner{output: result{Status: "succeeded"}}, 1, 2, 3)
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(serverTLS)))
	defer server.Stop()
	pb.RegisterSistersServer(server, s)
	go server.Serve(lis)
	call := func(creds credentials.TransportCredentials) (*pb.AgentStatus, error) {
		conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(creds))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 700*time.Millisecond)
		defer cancel()
		return pb.NewSistersClient(conn).GetStatus(ctx, &pb.Empty{})
	}
	got, err := call(credentials.NewTLS(clientTLS))
	if err != nil || got.Version != Version {
		t.Fatalf("authenticated call: %v %v", got, err)
	}
	missing := clientTLS.Clone()
	missing.Certificates = nil
	if _, err := call(credentials.NewTLS(missing)); err == nil {
		t.Fatal("client without certificate was accepted")
	}
	_, untrusted := tlsFixture(t)
	wrong := clientTLS.Clone()
	wrong.Certificates = untrusted.Certificates
	if _, err := call(credentials.NewTLS(wrong)); err == nil {
		t.Fatal("untrusted client certificate was accepted")
	}
	if _, err := call(insecure.NewCredentials()); err == nil {
		t.Fatal("plaintext client was accepted")
	}
}

func TestConfigAndTLSFailuresAreSanitized(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"cert":"server.pem","key":"server.key","ca":"ca.pem","runtime":"runtime"}`)
	c, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.MaxConcurrency != 2 || c.Cert != filepath.Join(dir, "server.pem") || c.Listen != "127.0.0.1:7443" {
		t.Fatalf("defaults or relative paths wrong: %+v", c)
	}
	if _, err := ServerTLS(c); err == nil || strings.Contains(err.Error(), dir) {
		t.Fatalf("unsafe TLS error: %v", err)
	}
	for _, body := range []string{`{"private-field":"private-value"}`, `null`, `{} {}`, `{"cert":"c","key":"k","ca":"a","runtime":"r","max_concurrency":-1}`, `{"cert":"c","key":"k","ca":"a","runtime":"r","queue_capacity":10,"history_capacity":1}`} {
		write(body)
		if _, err := LoadConfig(path); err == nil || strings.Contains(err.Error(), "private-value") {
			t.Fatalf("invalid config not rejected safely: %v", err)
		}
	}
	valid, _ := tlsFixture(t)
	valid.CA = filepath.Join(dir, "ca.pem")
	os.WriteFile(valid.CA, []byte("invalid private data"), 0600)
	if _, err := ServerTLS(valid); err == nil {
		t.Fatal("invalid CA accepted")
	}
}

func TestServeShutdown(t *testing.T) {
	c, _ := tlsFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Serve(ctx, c); err != nil {
		t.Fatalf("clean shutdown: %v", err)
	}
}
