package main

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/MisakaNetwork/MisakaNetwork/Sisters/agent"
	"golang.org/x/sys/windows/svc"
)

const windowsServiceName = "MisakaSisters"

func runService(ctx context.Context, c agent.Config, tempDir string) error {
	if err := configureServiceTemp(tempDir); err != nil {
		return err
	}
	isService, err := svc.IsWindowsService()
	if err != nil || !isService {
		return errors.New("service mode must be started by Windows Service Control Manager")
	}
	handler := &sistersService{
		parent: ctx,
		serve: func(ctx context.Context, ready func()) error {
			return agent.ServeWithReady(ctx, c, ready)
		},
		result: make(chan error, 1),
	}
	if err := svc.Run(windowsServiceName, handler); err != nil {
		return errors.New("cannot connect Sisters to Windows Service Control Manager")
	}
	return <-handler.result
}

func configureServiceTemp(dir string) error {
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return errors.New("service temporary directory unavailable")
	}
	f, err := os.CreateTemp(dir, "sisters-write-check-")
	if err != nil {
		return errors.New("service temporary directory is not writable")
	}
	name := f.Name()
	closeErr := f.Close()
	removeErr := os.Remove(name)
	if closeErr != nil || removeErr != nil {
		return errors.New("cannot verify service temporary directory")
	}
	if os.Setenv("TEMP", dir) != nil || os.Setenv("TMP", dir) != nil {
		return errors.New("cannot configure service temporary directory")
	}
	return nil
}

type sistersService struct {
	parent context.Context
	serve  func(context.Context, func()) error
	result chan error
}

func (s *sistersService) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	err := s.execute(requests, changes)
	s.result <- err
	if err != nil {
		return true, 1
	}
	return false, 0
}

func (s *sistersService) execute(requests <-chan svc.ChangeRequest, changes chan<- svc.Status) error {
	ctx, cancel := context.WithCancel(s.parent)
	defer cancel()
	state := svc.Status{State: svc.StartPending, CheckPoint: 1, WaitHint: 10000}
	changes <- state
	ready := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() { done <- s.serve(ctx, func() { ready <- struct{}{} }) }()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	parentDone := ctx.Done()
	stopping := false
	stop := func() {
		if stopping {
			return
		}
		stopping = true
		parentDone = nil
		cancel()
		state = svc.Status{State: svc.StopPending, CheckPoint: 1, WaitHint: 10000}
		changes <- state
	}
	for {
		select {
		case err := <-done:
			if ctx.Err() != nil {
				stop()
			}
			if err != nil {
				return err
			}
			if !stopping && ctx.Err() == nil {
				return errors.New("Sisters service stopped unexpectedly")
			}
			return nil
		case <-parentDone:
			stop()
		case <-ready:
			ready = nil
			if ctx.Err() != nil {
				stop()
			}
			if !stopping {
				state = svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
				changes <- state
			}
		case request, ok := <-requests:
			if !ok {
				requests = nil
				stop()
				continue
			}
			switch request.Cmd {
			case svc.Stop, svc.Shutdown:
				stop()
			case svc.Interrogate:
				changes <- state
			}
		case <-ticker.C:
			if state.State == svc.StartPending || state.State == svc.StopPending {
				state.CheckPoint++
				changes <- state
			}
		}
	}
}
