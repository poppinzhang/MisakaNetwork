package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type fakeRunner struct {
	mu                  sync.Mutex
	active, peak, calls int
	started             chan struct{}
	release             chan struct{}
	notReady            bool
	output              result
	err                 error
}

func (r *fakeRunner) probe(context.Context) (string, error) {
	if r.notReady {
		return "", errors.New("unavailable")
	}
	return "2.15.17", nil
}
func (r *fakeRunner) run(ctx context.Context, input []byte, emit func(progress)) (result, error) {
	r.mu.Lock()
	r.active++
	r.calls++
	if r.active > r.peak {
		r.peak = r.active
	}
	r.mu.Unlock()
	defer func() { r.mu.Lock(); r.active--; r.mu.Unlock() }()
	if !json.Valid(input) {
		return result{}, errors.New("invalid input")
	}
	if r.started != nil {
		r.started <- struct{}{}
	}
	for i := 0; i < 100; i++ {
		stage := "ordering"
		if i%2 == 0 {
			stage = "preparing"
		}
		emit(progress{Status: "running", Stage: stage})
	}
	if r.release != nil {
		select {
		case <-ctx.Done():
			return result{}, ctx.Err()
		case <-r.release:
		}
	}
	return r.output, r.err
}

func testService(t *testing.T, r runner, concurrency, queue, history int) *Service {
	t.Helper()
	s := newService(Config{MaxConcurrency: concurrency, QueueCapacity: queue, HistoryCapacity: history}, r)
	t.Cleanup(s.Close)
	return s
}
func request(id string) *pb.TaskRequest {
	return &pb.TaskRequest{Id: id, Name: "测试任务", CookieJson: `[{"name":"SESSDATA","value":"private-cookie-value"}]`, ConfigJson: `{"project_id":42,"private":"account-private-value"}`}
}
func waitState(t *testing.T, s *Service, id string, want pb.TaskState) *pb.TaskStatus {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		got := snapshot(s.tasks[id])
		s.mu.Unlock()
		if got.State == want {
			return got
		}
		time.Sleep(time.Millisecond)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t.Fatalf("task %s: got %s want %s", id, s.tasks[id].status.State, want)
	return nil
}
func waitStart(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("runtime did not start")
	}
}

func TestQueueConcurrencyIdempotencyCancellation(t *testing.T) {
	r := &fakeRunner{started: make(chan struct{}, 8), release: make(chan struct{}), output: result{Status: "succeeded"}}
	s := testService(t, r, 2, 1, 5)
	for _, id := range []string{"one", "two"} {
		if _, err := s.SubmitTask(context.Background(), request(id)); err != nil {
			t.Fatal(err)
		}
		waitStart(t, r.started)
	}
	queued, err := s.SubmitTask(context.Background(), request("three"))
	if err != nil || queued.State != pb.TaskState_TASK_STATE_QUEUED {
		t.Fatalf("queue: %v %v", queued, err)
	}
	if _, err := s.SubmitTask(context.Background(), request("four")); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("queue bound: %v", err)
	}
	if _, err := s.SubmitTask(context.Background(), request("three")); err != nil {
		t.Fatalf("idempotency: %v", err)
	}
	changed := request("three")
	changed.CookieJson = `{"SESSDATA":"other-secret"}`
	if _, err := s.SubmitTask(context.Background(), changed); status.Code(err) != codes.AlreadyExists {
		t.Fatalf("conflict: %v", err)
	}
	if _, err := s.CancelTask(context.Background(), &pb.TaskId{Id: "three"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SubmitTask(context.Background(), request("four")); err != nil {
		t.Fatalf("cancel did not free queue: %v", err)
	}
	s.CancelTask(context.Background(), &pb.TaskId{Id: "one"})
	waitStart(t, r.started)
	close(r.release)
	waitState(t, s, "one", pb.TaskState_TASK_STATE_CANCELLED)
	waitState(t, s, "two", pb.TaskState_TASK_STATE_SUCCEEDED)
	waitState(t, s, "three", pb.TaskState_TASK_STATE_CANCELLED)
	waitState(t, s, "four", pb.TaskState_TASK_STATE_SUCCEEDED)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.peak != 2 || r.calls != 3 {
		t.Fatalf("peak=%d calls=%d", r.peak, r.calls)
	}
}

func TestStatusRedactionEventBoundAndCopies(t *testing.T) {
	s := testService(t, &fakeRunner{output: result{Status: "succeeded"}}, 1, 2, 3)
	s.SubmitTask(context.Background(), request("safe"))
	got := waitState(t, s, "safe", pb.TaskState_TASK_STATE_SUCCEEDED)
	if len(got.Events) != maxEvents {
		t.Fatalf("events=%d", len(got.Events))
	}
	got.Name = "mutated"
	got.Events[0].Message = "mutated"
	agent, err := s.GetStatus(context.Background(), &pb.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(agent)
	for _, secret := range []string{"private-cookie-value", "account-private-value", "SESSDATA", "mutated"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("status leaked %q", secret)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tasks["safe"].payload != nil {
		t.Fatal("finished task retains payload")
	}
}

func TestUnconfirmedResultIsFailure(t *testing.T) {
	for _, tc := range []struct {
		status string
		err    error
		want   pb.TaskState
	}{{"completed", nil, pb.TaskState_TASK_STATE_FAILED}, {"", nil, pb.TaskState_TASK_STATE_FAILED}, {"succeeded", errors.New("secret runtime error"), pb.TaskState_TASK_STATE_FAILED}, {"duplicate_order", nil, pb.TaskState_TASK_STATE_SUCCEEDED}} {
		t.Run(tc.status+fmt.Sprint(tc.err != nil), func(t *testing.T) {
			s := testService(t, &fakeRunner{output: result{Status: tc.status}, err: tc.err}, 1, 1, 3)
			s.SubmitTask(context.Background(), request("task"))
			got := waitState(t, s, "task", tc.want)
			if strings.Contains(got.Message, "secret") {
				t.Fatal("raw runtime error leaked")
			}
		})
	}
}

func TestValidationReadinessAndHistoryBound(t *testing.T) {
	for _, edit := range []func(*pb.TaskRequest){func(r *pb.TaskRequest) { r.Id = "../../x" }, func(r *pb.TaskRequest) { r.Name = "\n" }, func(r *pb.TaskRequest) { r.CookieJson = "null" }, func(r *pb.TaskRequest) { r.ConfigJson = "[]" }, func(r *pb.TaskRequest) { r.ConfigJson = `{"secret":"unterminated` }, func(r *pb.TaskRequest) { r.CookieJson = strings.Repeat("x", maxPayloadBytes+1) }} {
		r := request("bad")
		edit(r)
		if _, _, err := validateRequest(r); err == nil {
			t.Fatal("invalid request accepted")
		}
	}
	s := testService(t, &fakeRunner{notReady: true}, 1, 1, 2)
	if _, err := s.SubmitTask(context.Background(), request("task")); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("not ready: %v", err)
	}
	ready, _ := s.GetStatus(context.Background(), &pb.Empty{})
	if ready.RuntimeReady {
		t.Fatal("unavailable runtime marked ready")
	}
	s2 := testService(t, &fakeRunner{output: result{Status: "succeeded"}}, 1, 1, 2)
	for i := 0; i < 4; i++ {
		id := fmt.Sprint(i)
		if _, err := s2.SubmitTask(context.Background(), request(id)); err != nil {
			t.Fatal(err)
		}
		waitState(t, s2, id, pb.TaskState_TASK_STATE_SUCCEEDED)
	}
	got, _ := s2.GetStatus(context.Background(), &pb.Empty{})
	if len(got.Tasks) != 2 || got.Tasks[0].Id != "2" {
		t.Fatalf("history not bounded: %v", got.Tasks)
	}
	if _, err := s2.CancelTask(context.Background(), &pb.TaskId{Id: "missing"}); status.Code(err) != codes.NotFound {
		t.Fatalf("missing: %v", err)
	}
}

func TestTimeStartIsValidatedAndBoundToPayload(t *testing.T) {
	for _, value := range []string{"2026-11-20 20:00:00", "2026-11-20T20:00", "20:00", "2026-02-30T20:00:00", "2026-11-20T24:00:00", "2026-11-20T20:00:00.5", "2026-11-20T20:00:00+08:00", " 2026-11-20T20:00:00"} {
		r := request("bad")
		r.TimeStart = value
		if _, _, err := validateRequest(r); err == nil {
			t.Fatalf("invalid time_start %q accepted", value)
		}
	}
	plain, plainFingerprint, err := validateRequest(request("task"))
	if err != nil || strings.Contains(string(plain), "runtime_options") {
		t.Fatalf("payload without time_start: %s %v", plain, err)
	}
	timed := request("task")
	timed.TimeStart = "2026-11-20T20:00:00"
	payload, timedFingerprint, err := validateRequest(timed)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Params struct {
			Options map[string]string `json:"runtime_options"`
		} `json:"params"`
	}
	if json.Unmarshal(payload, &decoded) != nil || decoded.Params.Options["time_start"] != "2026-11-20T20:00:00" {
		t.Fatalf("time_start not forwarded: %s", payload)
	}
	if timedFingerprint == plainFingerprint {
		t.Fatal("time_start is not part of the idempotency fingerprint")
	}
	s := testService(t, &fakeRunner{}, 1, 1, 2)
	if got, _ := s.GetStatus(context.Background(), &pb.Empty{}); !got.SupportsTimeStart {
		t.Fatal("agent does not advertise time_start support")
	}
	if _, err := s.SubmitTask(context.Background(), timed); err != nil {
		t.Fatal(err)
	}
	moved := request("task")
	moved.TimeStart = "2026-11-20T21:00:00"
	if _, err := s.SubmitTask(context.Background(), moved); status.Code(err) != codes.AlreadyExists {
		t.Fatalf("changed time_start reused the task: %v", err)
	}
}

type scriptedRunner struct{ updates []progress }

func (r scriptedRunner) probe(context.Context) (string, error) { return "2.15.17", nil }
func (r scriptedRunner) run(_ context.Context, _ []byte, emit func(progress)) (result, error) {
	for _, p := range r.updates {
		emit(p)
	}
	return result{Status: "succeeded"}, nil
}

func TestCountdownUpdatesStatusLineWithoutEvents(t *testing.T) {
	var updates []progress
	for n := 5; n > 0; n-- {
		seconds := n
		updates = append(updates, progress{Status: "running", Stage: "waiting", CountdownSeconds: &seconds})
	}
	updates = append(updates, progress{Status: "running", Stage: "ordering", AttemptCurrent: 1, AttemptTotal: 20})
	s := testService(t, scriptedRunner{updates}, 1, 1, 2)
	if _, err := s.SubmitTask(context.Background(), request("timed")); err != nil {
		t.Fatal(err)
	}
	got := waitState(t, s, "timed", pb.TaskState_TASK_STATE_SUCCEEDED)
	waiting := 0
	for _, e := range got.Events {
		if e.Message == "等待开票时间" {
			waiting++
		}
	}
	if waiting != 1 {
		t.Fatalf("countdown produced %d waiting events: %v", waiting, got.Events)
	}
}

func TestCloseCancelsQueuedAndRunning(t *testing.T) {
	r := &fakeRunner{started: make(chan struct{}, 2), release: make(chan struct{})}
	s := testService(t, r, 1, 1, 2)
	s.SubmitTask(context.Background(), request("running"))
	waitStart(t, r.started)
	s.SubmitTask(context.Background(), request("queued"))
	s.Close()
	s.Close()
	for _, id := range []string{"running", "queued"} {
		waitState(t, s, id, pb.TaskState_TASK_STATE_CANCELLED)
		if s.tasks[id].payload != nil {
			t.Fatal("shutdown retained secrets")
		}
	}
	if _, err := s.SubmitTask(context.Background(), request("new")); status.Code(err) != codes.Unavailable {
		t.Fatalf("closed service accepted task: %v", err)
	}
}
