// misaka-smoke verifies a packaged Sisters service with its actual runtime.
// It has no input for tickets or credentials. Its only task contains an empty
// configuration and a synthetic, non-login cookie, so validation must fail
// before the buying engine can contact a ticketing endpoint.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"github.com/MisakaNetwork/MisakaNetwork/internal/control"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

const syntheticCookie = `[{"name":"misaka_smoke_invalid","value":"synthetic-not-an-account"}]`

type report struct {
	Passed      bool     `json:"passed"`
	Version     string   `json:"version,omitempty"`
	BiliVersion string   `json:"bili_version,omitempty"`
	Platform    string   `json:"platform,omitempty"`
	Checks      []string `json:"checks"`
	Error       string   `json:"error,omitempty"`
}

func invalidTask() *pb.TaskRequest {
	return &pb.TaskRequest{Id: "offline-invalid-configuration", Name: "Offline invalid configuration smoke", CookieJson: syntheticCookie, ConfigJson: `{}`}
}

// Keep this guard next to submission: future refactors must not accidentally
// turn an offline packaging check into a real ticket-ordering attempt.
func verifyOfflineRequest(request *pb.TaskRequest) error {
	if request == nil || request.ConfigJson != `{}` || request.CookieJson != syntheticCookie {
		return errors.New("smoke safety invariant violated: only the fixed invalid configuration is allowed")
	}
	return nil
}

func clientTLS(identity control.Identity) (*tls.Config, error) {
	pair, err := tls.LoadX509KeyPair(identity.ClientCert, identity.ClientKey)
	if err != nil {
		return nil, errors.New("cannot load temporary client identity")
	}
	ca, err := os.ReadFile(identity.CACert)
	if err != nil {
		return nil, errors.New("cannot load temporary trust anchor")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("temporary trust anchor is invalid")
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{pair}, ServerName: "127.0.0.1"}, nil
}

func connect(address string, tlsConfig *tls.Config) (*grpc.ClientConn, error) {
	return grpc.NewClient("passthrough:///"+address, grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)))
}

func statusCall(ctx context.Context, client pb.SistersClient) (*pb.AgentStatus, error) {
	call, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	return client.GetStatus(call, &pb.Empty{})
}

func findTask(state *pb.AgentStatus, id string) *pb.TaskStatus {
	for _, task := range state.Tasks {
		if task.Id == id {
			return task
		}
	}
	return nil
}

func terminal(state pb.TaskState) bool {
	return state == pb.TaskState_TASK_STATE_SUCCEEDED || state == pb.TaskState_TASK_STATE_FAILED || state == pb.TaskState_TASK_STATE_CANCELLED
}

func pause(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return errors.New("smoke check timed out or was cancelled")
	case <-time.After(150 * time.Millisecond):
		return nil
	}
}

func executableFile(mode os.FileMode, platform string) bool {
	// Windows reports ordinary .exe files without POSIX executable bits.
	return mode.IsRegular() && (platform == "windows" || mode&0111 != 0)
}

func smoke(ctx context.Context, sisters, runtimeBinary, expectedPlatform string) (out report, resultErr error) {
	out.Checks = []string{}
	sisters, err := filepath.Abs(sisters)
	if err != nil {
		return out, errors.New("invalid Sisters executable path")
	}
	runtimeBinary, err = filepath.Abs(runtimeBinary)
	if err != nil {
		return out, errors.New("invalid runtime executable path")
	}
	for _, binary := range []string{sisters, runtimeBinary} {
		info, err := os.Stat(binary)
		if err != nil || !executableFile(info.Mode(), runtime.GOOS) {
			return out, errors.New("a required executable is missing or not executable")
		}
	}
	directory, err := os.MkdirTemp("", "misaka-smoke-")
	if err != nil {
		return out, errors.New("cannot create temporary smoke directory")
	}
	defer os.RemoveAll(directory)
	identity, err := control.InitPKI(filepath.Join(directory, "pki"))
	if err != nil {
		return out, errors.New("temporary identity creation failed")
	}
	cert, key, ca, err := control.ServerIdentity(filepath.Join(directory, "pki"), "127.0.0.1")
	if err != nil {
		return out, errors.New("temporary server identity creation failed")
	}
	for name, content := range map[string][]byte{"server.pem": cert, "server.key": key, "ca.pem": ca} {
		if err := os.WriteFile(filepath.Join(directory, name), content, 0600); err != nil {
			return out, errors.New("cannot prepare temporary server identity")
		}
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return out, errors.New("cannot reserve a loopback test port")
	}
	address := listener.Addr().String()
	listener.Close()
	config := map[string]any{"listen": address, "cert": "server.pem", "key": "server.key", "ca": "ca.pem", "runtime": runtimeBinary, "max_concurrency": 1, "queue_capacity": 4, "history_capacity": 16}
	encoded, err := json.Marshal(config)
	if err != nil || os.WriteFile(filepath.Join(directory, "agent.json"), encoded, 0600) != nil {
		return out, errors.New("cannot prepare temporary service configuration")
	}
	process := exec.Command(sisters, "serve", "--config", filepath.Join(directory, "agent.json"))
	process.Stdout, process.Stderr = io.Discard, io.Discard
	process.Dir = directory
	if err := process.Start(); err != nil {
		return out, errors.New("packaged Sisters could not start")
	}
	processDone := make(chan error, 1)
	go func() { processDone <- process.Wait() }()
	defer func() {
		// Windows cannot send os.Interrupt to another process. Its per-runtime
		// Job Objects close when Sisters exits and terminate any runtime tree.
		// Unix lets Sisters cancel its process groups gracefully first.
		if runtime.GOOS == "windows" {
			_ = process.Process.Kill()
		} else {
			_ = process.Process.Signal(os.Interrupt)
		}
		select {
		case <-processDone:
		case <-time.After(5 * time.Second):
			_ = process.Process.Kill()
			<-processDone
		}
	}()
	configTLS, err := clientTLS(identity)
	if err != nil {
		return out, err
	}
	connection, err := connect(address, configTLS)
	if err != nil {
		return out, errors.New("cannot construct authenticated test client")
	}
	defer connection.Close()
	client := pb.NewSistersClient(connection)
	for {
		state, callErr := statusCall(ctx, client)
		if callErr == nil && state.RuntimeReady {
			if state.Version != control.Version || state.BiliVersion != control.BiliVersion {
				return out, errors.New("packaged service and runtime versions do not match the release")
			}
			if expectedPlatform != "" && state.Platform != expectedPlatform {
				return out, errors.New("packaged Sisters reports an unexpected target platform")
			}
			out.Version, out.BiliVersion, out.Platform = state.Version, state.BiliVersion, state.Platform
			out.Checks = append(out.Checks, "mutual_tls_and_actual_runtime_readiness")
			break
		}
		if err := pause(ctx); err != nil {
			return out, errors.New("packaged service did not become ready before the deadline")
		}
	}

	// Trusting the CA alone must not grant access without a client certificate.
	unauthenticated := configTLS.Clone()
	unauthenticated.Certificates = nil
	noIdentity, err := connect(address, unauthenticated)
	if err != nil {
		return out, errors.New("cannot construct missing-identity test client")
	}
	call, cancel := context.WithTimeout(ctx, 2*time.Second)
	_, unauthenticatedError := pb.NewSistersClient(noIdentity).GetStatus(call, &pb.Empty{})
	cancel()
	noIdentity.Close()
	if unauthenticatedError == nil {
		return out, errors.New("service accepted a client without mutual TLS identity")
	}
	out.Checks = append(out.Checks, "missing_client_identity_rejected")

	request := invalidTask()
	if err := verifyOfflineRequest(request); err != nil {
		return out, err
	}
	if _, err := client.SubmitTask(ctx, request); err != nil {
		return out, errors.New("service did not accept the fixed invalid configuration for local validation")
	}
	var completed *pb.TaskStatus
	for completed == nil {
		state, err := statusCall(ctx, client)
		if err != nil {
			return out, errors.New("could not poll the local validation task")
		}
		payload, err := json.Marshal(state)
		if err != nil || strings.Contains(string(payload), "synthetic-not-an-account") || strings.Contains(string(payload), directory) {
			return out, errors.New("status exposed write-only task data or temporary environment details")
		}
		if task := findTask(state, request.Id); task != nil && terminal(task.State) {
			completed = task
			break
		}
		if err := pause(ctx); err != nil {
			return out, errors.New("invalid configuration did not reach a terminal state")
		}
	}
	if completed.State != pb.TaskState_TASK_STATE_FAILED {
		return out, errors.New("invalid configuration was not reported as FAILED")
	}
	out.Checks = append(out.Checks, "invalid_configuration_failed_without_ordering", "status_does_not_expose_cookie_or_paths")
	duplicate, err := client.SubmitTask(ctx, request)
	if err != nil || duplicate.State != completed.State || duplicate.UpdatedUnixMs != completed.UpdatedUnixMs || len(duplicate.Events) != len(completed.Events) {
		return out, errors.New("identical task retry was not idempotent")
	}
	out.Checks = append(out.Checks, "identical_task_retry_is_idempotent")
	changed := invalidTask()
	changed.Name = "Changed offline task label"
	if err := verifyOfflineRequest(changed); err != nil {
		return out, err
	}
	if _, err := client.SubmitTask(ctx, changed); status.Code(err) != codes.AlreadyExists {
		return out, errors.New("conflicting duplicate task id was not rejected")
	}
	out.Checks = append(out.Checks, "conflicting_task_id_rejected")
	unchanged, err := client.CancelTask(ctx, &pb.TaskId{Id: request.Id})
	if err != nil || unchanged.State != completed.State || unchanged.UpdatedUnixMs != completed.UpdatedUnixMs || len(unchanged.Events) != len(completed.Events) {
		return out, errors.New("cancelling a terminal task changed its result")
	}
	if _, err := client.CancelTask(ctx, &pb.TaskId{Id: "never-created-offline-task"}); status.Code(err) != codes.NotFound {
		return out, errors.New("unknown cancellation did not return NotFound")
	}
	out.Checks = append(out.Checks, "terminal_cancellation_has_no_side_effect", "unknown_cancellation_rejected")
	out.Passed = true
	return out, nil
}

func main() {
	flags := flag.NewFlagSet("misaka-smoke", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	sisters := flags.String("sisters", "", "packaged Sisters executable")
	runtimeBinary := flags.String("runtime", "", "packaged runtime executable")
	expected := flags.String("expect-platform", "", "expected GOOS/GOARCH")
	timeout := flags.Duration("timeout", 60*time.Second, "overall offline smoke deadline")
	if flags.Parse(os.Args[1:]) != nil || flags.NArg() != 0 || *sisters == "" || *runtimeBinary == "" || *timeout <= 0 || *timeout > 5*time.Minute {
		fmt.Fprintln(os.Stderr, "Usage: misaka-smoke --sisters <binary> --runtime <binary> [--expect-platform <GOOS/GOARCH>] [--timeout 60s]")
		os.Exit(2)
	}
	parent, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(parent, *timeout)
	defer cancel()
	out, err := smoke(ctx, *sisters, *runtimeBinary, *expected)
	if err != nil {
		out.Error = err.Error()
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
	if err != nil {
		os.Exit(1)
	}
}
