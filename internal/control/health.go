package control

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"golang.org/x/crypto/ssh"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

func validRuntimeProbe(output string) bool {
	var frame struct {
		Type string `json:"type"`
		OK   bool   `json:"ok"`
		Data struct {
			Version     string `json:"version"`
			Ready       bool   `json:"ready"`
			Protocol    int    `json:"protocol"`
			BiliVersion string `json:"bili_version"`
		} `json:"data"`
	}
	d := json.NewDecoder(strings.NewReader(output))
	if d.Decode(&frame) != nil {
		return false
	}
	var extra any
	return d.Decode(&extra) == io.EOF && frame.Type == "result" && frame.OK && frame.Data.Ready && frame.Data.Protocol == 1 && frame.Data.Version == Version && frame.Data.BiliVersion == BiliVersion
}

func deploymentTLS(identity Identity, expectedCert []byte, name string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(identity.ClientCert, identity.ClientKey)
	if err != nil {
		return nil, errors.New("无法载入健康检查客户端身份")
	}
	ca, err := os.ReadFile(identity.CACert)
	if err != nil {
		return nil, errors.New("无法载入健康检查 CA")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("健康检查 CA 无效")
	}
	block, _ := pem.Decode(expectedCert)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("待部署服务证书无效")
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{cert}, ServerName: name, VerifyConnection: func(state tls.ConnectionState) error {
		// Pin the freshly issued leaf as well as validating its CA and hostname.
		// An older service still occupying the port must not pass deployment.
		if len(state.PeerCertificates) == 0 || !bytes.Equal(state.PeerCertificates[0].Raw, block.Bytes) {
			return errors.New("部署服务证书不匹配")
		}
		return nil
	}}, nil
}

func verifyDeployment(parent context.Context, client *ssh.Client, identity Identity, cert []byte, name string, port int) error {
	return awaitHealthy(parent, identity, cert, name, 30*time.Second, func(ctx context.Context) (net.Conn, error) {
		return client.DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	})
}

// reachable reports whether this device reaches the new service at endpoint
// directly, as LastOrder will. The tunnelled check cannot see a firewall or
// security group that blocks the gRPC port.
func reachable(parent context.Context, identity Identity, cert []byte, name, endpoint string) bool {
	return awaitHealthy(parent, identity, cert, name, 10*time.Second, func(ctx context.Context) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", endpoint)
	}) == nil
}

// awaitHealthy polls GetStatus over dial until the freshly issued service
// reports this version with a ready runtime, or window elapses.
func awaitHealthy(parent context.Context, identity Identity, cert []byte, name string, window time.Duration, dial func(context.Context) (net.Conn, error)) error {
	tlsConfig, err := deploymentTLS(identity, cert, name)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(parent, window)
	defer cancel()
	conn, err := grpc.NewClient("passthrough:///sisters-health", grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(64*1024*1024)), grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
		return dial(ctx)
	}))
	if err != nil {
		return errors.New("无法创建部署健康检查")
	}
	defer conn.Close()
	rpc := pb.NewSistersClient(conn)
	for {
		callCtx, callCancel := context.WithTimeout(ctx, 6*time.Second)
		state, callErr := rpc.GetStatus(callCtx, &pb.Empty{})
		callCancel()
		if callErr == nil && state.Version == Version && state.BiliVersion == BiliVersion && state.RuntimeReady {
			return nil
		}
		select {
		case <-ctx.Done():
			return errors.New("部署服务健康检查未通过")
		case <-time.After(500 * time.Millisecond):
		}
	}
}
