package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/windows/svc"
)

func TestWindowsMinimumVersion(t *testing.T) {
	for _, tc := range []struct {
		major   uint32
		arch    string
		allowed bool
	}{
		{6, "amd64", false}, {10, "amd64", true}, {11, "amd64", true}, {10, "386", false}, {10, "arm64", false},
	} {
		if (checkWindowsVersion(tc.major, tc.arch) == nil) != tc.allowed {
			t.Errorf("version %d architecture %s", tc.major, tc.arch)
		}
	}
}

func TestServiceTempDirectory(t *testing.T) {
	t.Setenv("TEMP", os.Getenv("TEMP"))
	t.Setenv("TMP", os.Getenv("TMP"))
	dir := t.TempDir()
	if err := configureServiceTemp(filepath.Join(dir, "missing")); err == nil {
		t.Fatal("missing temporary directory accepted")
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := configureServiceTemp(file); err == nil {
		t.Fatal("regular file accepted as temporary directory")
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := configureServiceTemp(dir); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("TEMP") != dir || os.Getenv("TMP") != dir {
		t.Fatal("temporary directory not inherited by runtime")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("temporary directory probe left a file")
	}
}

func nextServiceState(t *testing.T, changes <-chan svc.Status, wanted svc.State) svc.Status {
	t.Helper()
	select {
	case status := <-changes:
		if status.State != wanted {
			t.Fatalf("state %v want %v", status.State, wanted)
		}
		return status
	case <-time.After(3 * time.Second):
		t.Fatal("service state timed out")
	}
	return svc.Status{}
}

func TestServiceControlsCancelRuntimeAndWaitForExit(t *testing.T) {
	for _, command := range []svc.Cmd{svc.Stop, svc.Shutdown} {
		t.Run(map[svc.Cmd]string{svc.Stop: "stop", svc.Shutdown: "shutdown"}[command], func(t *testing.T) {
			requests := make(chan svc.ChangeRequest)
			changes := make(chan svc.Status, 10)
			allowReady := make(chan struct{})
			cancelled := make(chan struct{})
			allowExit := make(chan struct{})
			handler := &sistersService{parent: context.Background(), result: make(chan error, 1), serve: func(ctx context.Context, ready func()) error {
				<-allowReady
				ready()
				<-ctx.Done()
				close(cancelled)
				<-allowExit
				return nil
			}}
			done := make(chan uint32, 1)
			go func() {
				specific, code := handler.Execute(nil, requests, changes)
				if specific {
					code = 99
				}
				done <- code
			}()
			nextServiceState(t, changes, svc.StartPending)
			select {
			case <-changes:
				t.Fatal("service reported Running before listener ready")
			default:
			}
			close(allowReady)
			running := nextServiceState(t, changes, svc.Running)
			if running.Accepts != svc.AcceptStop|svc.AcceptShutdown {
				t.Fatal("service stop controls missing")
			}
			requests <- svc.ChangeRequest{Cmd: svc.Interrogate}
			nextServiceState(t, changes, svc.Running)
			requests <- svc.ChangeRequest{Cmd: command}
			nextServiceState(t, changes, svc.StopPending)
			select {
			case <-cancelled:
			case <-time.After(3 * time.Second):
				t.Fatal("service did not cancel runtime")
			}
			select {
			case <-done:
				t.Fatal("service exited before runtime stopped")
			default:
			}
			close(allowExit)
			select {
			case code := <-done:
				if code != 0 {
					t.Fatalf("exit %d", code)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("service did not exit")
			}
			if err := <-handler.result; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestServiceStartupFailureNeverReportsRunning(t *testing.T) {
	changes := make(chan svc.Status, 10)
	handler := &sistersService{parent: context.Background(), result: make(chan error, 1), serve: func(context.Context, func()) error { return errors.New("startup failed") }}
	specific, code := handler.Execute(nil, make(chan svc.ChangeRequest), changes)
	if !specific || code == 0 {
		t.Fatal("startup failure reported success")
	}
	nextServiceState(t, changes, svc.StartPending)
	select {
	case status := <-changes:
		t.Fatalf("unexpected status after failure: %v", status.State)
	default:
	}
	if err := <-handler.result; err == nil {
		t.Fatal("startup error was lost")
	}
}

func TestServiceParentCancellationDuringStartup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	changes := make(chan svc.Status, 10)
	handler := &sistersService{parent: ctx, result: make(chan error, 1), serve: func(ctx context.Context, ready func()) error { <-ctx.Done(); ready(); return nil }}
	done := make(chan uint32, 1)
	go func() { _, code := handler.Execute(nil, make(chan svc.ChangeRequest), changes); done <- code }()
	nextServiceState(t, changes, svc.StartPending)
	cancel()
	nextServiceState(t, changes, svc.StopPending)
	select {
	case code := <-done:
		if code != 0 {
			t.Fatal("cancelled service failed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("startup cancellation hung")
	}
	select {
	case status := <-changes:
		if status.State == svc.Running {
			t.Fatal("cancelled startup reported Running")
		}
	default:
	}
}

func TestServiceCancellationCompetesWithReadyAndExit(t *testing.T) {
	// Exercise both an already-cancelled parent and a cancellation immediately
	// followed by readiness and exit. In either case all three select branches
	// may be runnable; their selection order must not affect SCM state.
	for _, cancelBeforeStart := range []bool{false, true} {
		for iteration := 0; iteration < 500; iteration++ {
			ctx, cancel := context.WithCancel(context.Background())
			if cancelBeforeStart {
				cancel()
			}
			changes := make(chan svc.Status, 10)
			handler := &sistersService{
				parent: ctx,
				result: make(chan error, 1),
				serve: func(_ context.Context, funcReady func()) error {
					cancel()
					funcReady()
					return nil
				},
			}
			specific, code := handler.Execute(nil, make(chan svc.ChangeRequest), changes)
			cancel()
			if specific || code != 0 {
				t.Fatalf("cancel before start %v, iteration %d: service failed with %d", cancelBeforeStart, iteration, code)
			}
			if err := <-handler.result; err != nil {
				t.Fatal(err)
			}
			close(changes)
			var states []svc.State
			for status := range changes {
				states = append(states, status.State)
			}
			if len(states) != 2 || states[0] != svc.StartPending || states[1] != svc.StopPending {
				t.Fatalf("cancel before start %v, iteration %d: unexpected SCM states %v", cancelBeforeStart, iteration, states)
			}
		}
	}
}
