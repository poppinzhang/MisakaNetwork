package agent

import (
	"context"
	"errors"
	"net"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// Serve runs the mTLS-only API until ctx is cancelled. Runtime readiness can be
// inspected even when the runtime is not installed or its dependencies fail.
func Serve(ctx context.Context, c Config) error {
	return ServeWithReady(ctx, c, nil)
}

// ServeWithReady additionally reports that configuration, TLS and the listener
// are ready. Service hosts must not report Running before this notification.
func ServeWithReady(ctx context.Context, c Config, ready func()) error {
	if err := c.normalize(); err != nil {
		return err
	}
	tlsConfig, err := ServerTLS(c)
	if err != nil {
		return err
	}
	s, err := New(c)
	if err != nil {
		return err
	}
	defer s.Close()
	lis, err := net.Listen("tcp", c.Listen)
	if err != nil {
		return errors.New("cannot listen on configured address")
	}
	defer lis.Close()
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(tlsConfig)), grpc.MaxRecvMsgSize(3*1024*1024), grpc.MaxSendMsgSize(64*1024*1024))
	pb.RegisterSistersServer(server, s)
	if ready != nil {
		ready()
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(lis) }()
	select {
	case err := <-done:
		if err != nil {
			return errors.New("gRPC server stopped unexpectedly")
		}
		return nil
	case <-ctx.Done():
		s.Close()
		stopped := make(chan struct{})
		go func() { server.GracefulStop(); close(stopped) }()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			server.Stop()
		}
		return nil
	}
}
