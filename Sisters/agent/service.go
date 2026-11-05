package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const maxEvents = 64
const maxPayloadBytes = 1024 * 1024

type task struct {
	status      *pb.TaskStatus
	fingerprint [32]byte
	payload     []byte
	cancel      context.CancelFunc
}

// Service keeps only bounded in-memory task history. Cookie payloads are never
// written to disk or included in status, events or error messages.
type Service struct {
	pb.UnimplementedSistersServer
	mu          sync.Mutex
	cond        *sync.Cond
	config      Config
	runner      runner
	ctx         context.Context
	cancel      context.CancelFunc
	closed      bool
	tasks       map[string]*task
	order       []string
	queue       []*task
	workers     sync.WaitGroup
	started     int64
	probeMu     sync.Mutex
	probeAt     time.Time
	ready       bool
	biliVersion string
}

func New(c Config) (*Service, error) {
	if err := c.normalize(); err != nil {
		return nil, err
	}
	return newService(c, executableRunner{path: c.Runtime}), nil
}

func newService(c Config, r runner) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{config: c, runner: r, ctx: ctx, cancel: cancel, tasks: map[string]*task{}, started: time.Now().UnixMilli()}
	s.cond = sync.NewCond(&s.mu)
	for i := 0; i < c.MaxConcurrency; i++ {
		s.workers.Add(1)
		go s.worker()
	}
	return s
}

// Close cancels queued work and terminates all active runtime process groups.
func (s *Service) Close() {
	s.mu.Lock()
	if !s.closed {
		s.closed = true
		s.cancel()
		for _, t := range s.tasks {
			if !terminal(t.status.State) {
				s.update(t, pb.TaskState_TASK_STATE_CANCELLED, "服务停止，任务已取消")
			}
			if t.cancel != nil {
				t.cancel()
			}
			if t.status.State == pb.TaskState_TASK_STATE_CANCELLED && t.cancel == nil {
				clear(t.payload)
				t.payload = nil
			}
		}
		s.queue = nil
		s.cond.Broadcast()
	}
	s.mu.Unlock()
	s.workers.Wait()
}

func (s *Service) readiness(ctx context.Context) (bool, string) {
	s.probeMu.Lock()
	defer s.probeMu.Unlock()
	if time.Since(s.probeAt) < 2*time.Second {
		return s.ready, s.biliVersion
	}
	version, err := s.runner.probe(ctx)
	s.ready = err == nil
	s.biliVersion = version
	s.probeAt = time.Now()
	return s.ready, s.biliVersion
}

func (s *Service) GetStatus(ctx context.Context, _ *pb.Empty) (*pb.AgentStatus, error) {
	ready, version := s.readiness(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, status.Error(codes.Unavailable, "agent is shutting down")
	}
	out := &pb.AgentStatus{Version: Version, BiliVersion: version, Platform: runtime.GOOS + "/" + runtime.GOARCH, StartedUnixMs: s.started, MaxConcurrency: int32(s.config.MaxConcurrency), RuntimeReady: ready, SupportsTimeStart: true}
	for _, id := range s.order {
		out.Tasks = append(out.Tasks, snapshot(s.tasks[id]))
	}
	return out, nil
}

var taskID = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)

// timeStartLayout is a Beijing-time wall clock; the runtime applies UTC+8.
const timeStartLayout = "2006-01-02T15:04:05"

type runOptions struct {
	TimeStart string `json:"time_start"`
}
type runParams struct {
	Cookies json.RawMessage `json:"cookies"`
	Config  json.RawMessage `json:"config"`
	Options *runOptions     `json:"runtime_options,omitempty"`
}

func validateRequest(req *pb.TaskRequest) ([]byte, [32]byte, error) {
	if req == nil || !taskID.MatchString(req.Id) {
		return nil, [32]byte{}, errors.New("invalid task id")
	}
	if !utf8.ValidString(req.Name) || strings.TrimSpace(req.Name) == "" || utf8.RuneCountInString(req.Name) > 200 || strings.ContainsFunc(req.Name, unicode.IsControl) {
		return nil, [32]byte{}, errors.New("task name must contain 1 to 200 characters without control characters")
	}
	if len(req.CookieJson) > maxPayloadBytes || len(req.ConfigJson) > maxPayloadBytes {
		return nil, [32]byte{}, errors.New("task payload exceeds size limit")
	}
	cookie := strings.TrimSpace(req.CookieJson)
	config := strings.TrimSpace(req.ConfigJson)
	if len(cookie) < 2 || (cookie[0] != '{' && cookie[0] != '[') || !json.Valid([]byte(cookie)) {
		return nil, [32]byte{}, errors.New("cookies must be a JSON object or array")
	}
	if len(config) < 2 || config[0] != '{' || !json.Valid([]byte(config)) {
		return nil, [32]byte{}, errors.New("config must be a JSON object")
	}
	params := runParams{Cookies: json.RawMessage(cookie), Config: json.RawMessage(config)}
	if req.TimeStart != "" {
		// Parse alone also accepts fractional seconds, which the runtime rejects.
		if _, err := time.Parse(timeStartLayout, req.TimeStart); err != nil || len(req.TimeStart) != len(timeStartLayout) {
			return nil, [32]byte{}, errors.New("time_start must be YYYY-MM-DDTHH:MM:SS in Beijing time")
		}
		params.Options = &runOptions{TimeStart: req.TimeStart}
	}
	payload, err := json.Marshal(struct {
		Op     string    `json:"op"`
		Params runParams `json:"params"`
	}{Op: "run", Params: params})
	if err != nil {
		return nil, [32]byte{}, errors.New("invalid task payload")
	}
	h := sha256.New()
	h.Write([]byte(req.Name))
	h.Write([]byte{0})
	h.Write(payload)
	var fingerprint [32]byte
	copy(fingerprint[:], h.Sum(nil))
	return append(payload, '\n'), fingerprint, nil
}

func (s *Service) SubmitTask(ctx context.Context, req *pb.TaskRequest) (*pb.TaskStatus, error) {
	payload, fingerprint, err := validateRequest(req)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	retained := false
	defer func() {
		if !retained {
			clear(payload)
		}
	}()
	// Existing task retries must work even if the runtime is currently offline.
	s.mu.Lock()
	if old := s.tasks[req.Id]; old != nil {
		defer s.mu.Unlock()
		if old.fingerprint != fingerprint {
			return nil, status.Error(codes.AlreadyExists, "task id already has a different payload")
		}
		return snapshot(old), nil
	}
	s.mu.Unlock()
	ready, _ := s.readiness(ctx)
	if !ready {
		return nil, status.Error(codes.FailedPrecondition, "runtime is not ready")
	}
	if ctx.Err() != nil {
		return nil, status.FromContextError(ctx.Err()).Err()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, status.Error(codes.Unavailable, "agent is shutting down")
	}
	// Another request may have registered this id while readiness was checked.
	if old := s.tasks[req.Id]; old != nil {
		if old.fingerprint != fingerprint {
			return nil, status.Error(codes.AlreadyExists, "task id already has a different payload")
		}
		return snapshot(old), nil
	}
	if len(s.queue) >= s.config.QueueCapacity {
		return nil, status.Error(codes.ResourceExhausted, "task queue is full")
	}
	if len(s.tasks) >= s.config.HistoryCapacity {
		removed := false
		for i, id := range s.order {
			if terminal(s.tasks[id].status.State) && s.tasks[id].cancel == nil {
				delete(s.tasks, id)
				s.order = append(s.order[:i], s.order[i+1:]...)
				removed = true
				break
			}
		}
		if !removed {
			return nil, status.Error(codes.ResourceExhausted, "task history is full")
		}
	}
	t := &task{status: &pb.TaskStatus{Id: req.Id, Name: req.Name}, fingerprint: fingerprint, payload: payload}
	s.update(t, pb.TaskState_TASK_STATE_QUEUED, "任务已进入队列")
	s.tasks[req.Id] = t
	s.order = append(s.order, req.Id)
	s.queue = append(s.queue, t)
	retained = true
	s.cond.Signal()
	return snapshot(t), nil
}

func (s *Service) CancelTask(_ context.Context, req *pb.TaskId) (*pb.TaskStatus, error) {
	if req == nil || !taskID.MatchString(req.Id) {
		return nil, status.Error(codes.InvalidArgument, "invalid task id")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tasks[req.Id]
	if t == nil {
		return nil, status.Error(codes.NotFound, "task not found")
	}
	if terminal(t.status.State) {
		return snapshot(t), nil
	}
	if t.cancel != nil {
		t.cancel()
	} else {
		for i, queued := range s.queue {
			if queued == t {
				s.queue = append(s.queue[:i], s.queue[i+1:]...)
				break
			}
		}
		clear(t.payload)
		t.payload = nil
	}
	s.update(t, pb.TaskState_TASK_STATE_CANCELLED, "任务已取消")
	return snapshot(t), nil
}

func (s *Service) worker() {
	defer s.workers.Done()
	for {
		s.mu.Lock()
		for len(s.queue) == 0 && !s.closed {
			s.cond.Wait()
		}
		if s.closed {
			s.mu.Unlock()
			return
		}
		t := s.queue[0]
		s.queue[0] = nil
		s.queue = s.queue[1:]
		ctx, cancel := context.WithCancel(s.ctx)
		t.cancel = cancel
		s.update(t, pb.TaskState_TASK_STATE_RUNNING, "正在执行抢票任务")
		s.mu.Unlock()
		out, err := s.runner.run(ctx, t.payload, func(p progress) {
			s.mu.Lock()
			defer s.mu.Unlock()
			if !terminal(t.status.State) {
				event, line := progressText(p)
				s.update(t, pb.TaskState_TASK_STATE_RUNNING, event)
				t.status.Message = line
			}
		})
		cancel()
		s.mu.Lock()
		clear(t.payload)
		t.payload = nil
		t.cancel = nil
		if !terminal(t.status.State) {
			switch {
			case err != nil:
				s.update(t, pb.TaskState_TASK_STATE_FAILED, "抢票工具执行失败，请检查运行环境或任务配置")
			case out.Status == "succeeded":
				s.update(t, pb.TaskState_TASK_STATE_SUCCEEDED, "已下单，请到哔哩哔哩订单页确认并支付")
			case out.Status == "duplicate_order":
				s.update(t, pb.TaskState_TASK_STATE_SUCCEEDED, "检测到已有订单，请到哔哩哔哩订单页确认并支付")
			default:
				s.update(t, pb.TaskState_TASK_STATE_FAILED, "抢票工具已结束，但未确认下单成功")
			}
		}
		s.mu.Unlock()
	}
}

func terminal(state pb.TaskState) bool {
	return state == pb.TaskState_TASK_STATE_SUCCEEDED || state == pb.TaskState_TASK_STATE_FAILED || state == pb.TaskState_TASK_STATE_CANCELLED
}
func snapshot(t *task) *pb.TaskStatus { return proto.Clone(t.status).(*pb.TaskStatus) }
func (s *Service) update(t *task, state pb.TaskState, message string) {
	now := time.Now().UnixMilli()
	t.status.State = state
	t.status.Message = message
	t.status.UpdatedUnixMs = now
	level := "info"
	if state == pb.TaskState_TASK_STATE_FAILED {
		level = "error"
	}
	// Coalesce identical consecutive updates to keep useful history available.
	if n := len(t.status.Events); n > 0 && t.status.Events[n-1].Message == message {
		t.status.Events[n-1].TimestampUnixMs = now
		return
	}
	t.status.Events = append(t.status.Events, &pb.TaskEvent{TimestampUnixMs: now, Level: level, Message: message})
	if len(t.status.Events) > maxEvents {
		t.status.Events = append([]*pb.TaskEvent(nil), t.status.Events[len(t.status.Events)-maxEvents:]...)
	}
}
