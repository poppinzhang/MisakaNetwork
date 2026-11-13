package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
	"google.golang.org/protobuf/proto"
)

const testPaymentCode = "weixin://wxpay/bizpayurl?pr=synthetic_token"

func TestPaymentValidation(t *testing.T) {
	for _, id := range []string{"", "0", "01", "-1", "+1", "1.0", "1\n", " 1", "１", strings.Repeat("1", 81)} {
		if got := orderPayment(result{Status: "succeeded", OrderID: id, PaymentCodeURL: testPaymentCode}, 123); got != nil {
			t.Errorf("invalid order id %q accepted", id)
		}
	}
	for _, status := range []string{"", "completed", "running", "cancelled", "failed"} {
		if orderPayment(result{Status: status, OrderID: "12", PaymentCodeURL: testPaymentCode}, 123) != nil {
			t.Errorf("unconfirmed status %q exposed payment", status)
		}
	}
	valid := []string{testPaymentCode, "https://qr.alipay.com/synthetic_TOKEN-12", "weixin://wxpay/bizpayurl?pr=" + strings.Repeat("a", 512), "https://qr.alipay.com/" + strings.Repeat("b", 512)}
	invalid := []string{
		"", "https://show.bilibili.com/platform/orderDetail.html?order_id=12",
		"http://qr.alipay.com/token", "https://qr.alipay.com.evil.test/token", "https://evil.test/qr.alipay.com/token",
		"https://user@qr.alipay.com/token", "https://qr.alipay.com:443/token", "https://qr.alipay.com/token#fragment",
		"https://qr.alipay.com/token?redirect=https://evil.test", "https://qr.alipay.com/../token", "https://qr.alipay.com/%74oken",
		"https://qr.alipay.com/token/", "HTTPS://qr.alipay.com/token", "https://QR.ALIPAY.COM/token", "https://qr.alipay.com/token\n",
		"weixin://wxpay/bizpayurl?pr=", "weixin://wxpay/bizpayurl?pr=token&redirect=evil", "weixin://wxpay/bizpayurl?pr=token&pr=other",
		"weixin://wxpay/bizpayurl?pr=token#fragment", "weixin://wxpay/bizpayurl?pr=%74oken", "weixin://wxpay/bizpayurl?pr=token\n",
		"weixin://wxpay/bizpayurl?pr=" + strings.Repeat("a", 513), "https://qr.alipay.com/" + strings.Repeat("b", 513),
		"weixin://user@wxpay/bizpayurl?pr=token", "weixin://wxpay:80/bizpayurl?pr=token", "weixin://wxpay/bizpayurl?pr=中文",
		"javascript:alert(1)", "file:///private/example", strings.Repeat("a", 2049),
	}
	for _, status := range []string{"succeeded", "duplicate_order"} {
		for _, code := range append(valid, invalid...) {
			got := orderPayment(result{Status: status, OrderID: "12", OrderDetailURL: "https://evil.test", PaymentCodeURL: code}, 123)
			if got == nil || got.OrderId != "12" || got.OrderDetailUrl != "https://show.bilibili.com/platform/orderDetail.html?order_id=12" || got.CapturedUnixMs != 123 {
				t.Fatalf("order fallback lost: %+v", got)
			}
			want := ""
			for _, value := range valid {
				if value == code {
					want = code
				}
			}
			if got.PaymentCodeUrl != want {
				t.Errorf("payment code %q: got %q", code, got.PaymentCodeUrl)
			}
		}
	}
	if orderPayment(result{Status: "succeeded", OrderID: strings.Repeat("1", 80)}, 123) == nil {
		t.Fatal("maximum-length order id rejected")
	}
}

func TestPaymentResultRetainedWithoutLeakingToEvents(t *testing.T) {
	for _, status := range []string{"succeeded", "duplicate_order"} {
		t.Run(status, func(t *testing.T) {
			s := testService(t, &fakeRunner{output: result{Status: status, OrderID: "12", OrderDetailURL: "https://evil.test/private", PaymentCodeURL: testPaymentCode}}, 1, 2, 3)
			if _, err := s.SubmitTask(context.Background(), request("paid")); err != nil {
				t.Fatal(err)
			}
			got := waitState(t, s, "paid", pb.TaskState_TASK_STATE_SUCCEEDED)
			if got.Payment == nil || got.Payment.PaymentCodeUrl != testPaymentCode || got.Payment.CapturedUnixMs <= 0 {
				t.Fatalf("payment missing: %v", got.Payment)
			}
			original := proto.Clone(got.Payment).(*pb.OrderPayment)
			events, _ := json.Marshal(got.Events)
			for _, secret := range []string{testPaymentCode, "synthetic_token", "https://", "private-cookie-value", "account-private-value"} {
				if strings.Contains(got.Message+string(events), secret) {
					t.Fatalf("payment or credentials leaked to messages: %q", secret)
				}
			}
			got.Payment.PaymentCodeUrl = "mutated"
			got.Payment.OrderId = "mutated"
			agent, err := s.GetStatus(context.Background(), &pb.Empty{})
			if err != nil || !proto.Equal(agent.Tasks[0].Payment, original) {
				t.Fatalf("status mutation or polling changed payment: %v", err)
			}
			cancelled, err := s.CancelTask(context.Background(), &pb.TaskId{Id: "paid"})
			if err != nil || cancelled.State != pb.TaskState_TASK_STATE_SUCCEEDED || !proto.Equal(cancelled.Payment, original) {
				t.Fatalf("cancel changed finished order: %v", err)
			}
			agent.Tasks[0].Payment.CapturedUnixMs = 0
			retry, err := s.SubmitTask(context.Background(), request("paid"))
			if err != nil || !proto.Equal(retry.Payment, original) {
				t.Fatalf("idempotent retry changed payment: %v", err)
			}
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.tasks["paid"].payload != nil {
				t.Fatal("payment retention retained task credentials")
			}
		})
	}
}

func TestPaymentFallbackAndUnconfirmedResults(t *testing.T) {
	for _, tc := range []struct {
		name      string
		out       result
		err       error
		state     pb.TaskState
		wantOrder bool
	}{
		{"no_code", result{Status: "succeeded", OrderID: "12"}, nil, pb.TaskState_TASK_STATE_SUCCEEDED, true},
		{"invalid_code", result{Status: "succeeded", OrderID: "12", PaymentCodeURL: "https://evil.test"}, nil, pb.TaskState_TASK_STATE_SUCCEEDED, true},
		{"duplicate_without_id", result{Status: "duplicate_order", PaymentCodeURL: testPaymentCode}, nil, pb.TaskState_TASK_STATE_SUCCEEDED, false},
		{"invalid_id", result{Status: "succeeded", OrderID: "private", PaymentCodeURL: testPaymentCode}, nil, pb.TaskState_TASK_STATE_SUCCEEDED, false},
		{"completed", result{Status: "completed", OrderID: "12", PaymentCodeURL: testPaymentCode}, nil, pb.TaskState_TASK_STATE_FAILED, false},
		{"error", result{Status: "succeeded", OrderID: "12", PaymentCodeURL: testPaymentCode}, errors.New("private error"), pb.TaskState_TASK_STATE_FAILED, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := testService(t, &fakeRunner{output: tc.out, err: tc.err}, 1, 1, 2)
			if _, err := s.SubmitTask(context.Background(), request("task")); err != nil {
				t.Fatal(err)
			}
			got := waitState(t, s, "task", tc.state)
			if (got.Payment != nil) != tc.wantOrder || got.GetPayment().GetPaymentCodeUrl() != "" {
				t.Fatalf("unexpected payment result: %v", got.Payment)
			}
		})
	}
}

type cancellationResultRunner struct {
	started chan struct{}
	release chan struct{}
	out     result
	err     error
}

func (r *cancellationResultRunner) probe(context.Context) (string, error) { return "2.15.18", nil }
func (r *cancellationResultRunner) run(ctx context.Context, _ []byte, emit func(progress)) (result, error) {
	// A success-looking progress update is deliberately insufficient.
	emit(progress{Status: "succeeded", Stage: "ordered"})
	close(r.started)
	<-ctx.Done()
	<-r.release
	return r.out, r.err
}

func TestCancellationRaceKeepsOnlyConfirmedFinalOrder(t *testing.T) {
	for _, tc := range []struct {
		name, status string
		err          error
		want         pb.TaskState
	}{
		{"success", "succeeded", nil, pb.TaskState_TASK_STATE_SUCCEEDED},
		{"duplicate", "duplicate_order", nil, pb.TaskState_TASK_STATE_SUCCEEDED},
		{"error", "succeeded", context.Canceled, pb.TaskState_TASK_STATE_CANCELLED},
		{"unconfirmed", "completed", nil, pb.TaskState_TASK_STATE_CANCELLED},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &cancellationResultRunner{started: make(chan struct{}), release: make(chan struct{}), out: result{Status: tc.status, OrderID: "12", PaymentCodeURL: testPaymentCode}, err: tc.err}
			s := testService(t, r, 1, 1, 2)
			if _, err := s.SubmitTask(context.Background(), request("race")); err != nil {
				t.Fatal(err)
			}
			waitStart(t, r.started)
			before, _ := s.GetStatus(context.Background(), &pb.Empty{})
			if before.Tasks[0].State != pb.TaskState_TASK_STATE_RUNNING || before.Tasks[0].Payment != nil {
				t.Fatal("progress exposed an unconfirmed order")
			}
			cancelled, err := s.CancelTask(context.Background(), &pb.TaskId{Id: "race"})
			if err != nil || cancelled.State != pb.TaskState_TASK_STATE_CANCELLED || cancelled.Payment != nil {
				t.Fatalf("cancellation failed: %v", err)
			}
			close(r.release)
			s.Close() // Wait for the worker to process the late final result.
			got := waitState(t, s, "race", tc.want)
			if (got.Payment != nil) != (tc.want == pb.TaskState_TASK_STATE_SUCCEEDED) {
				t.Fatalf("late result payment mismatch: %v", got.Payment)
			}
		})
	}
}

func TestPaymentExpiresWithBoundedTaskHistory(t *testing.T) {
	s := testService(t, &fakeRunner{output: result{Status: "succeeded", OrderID: "12", PaymentCodeURL: testPaymentCode}}, 1, 1, 1)
	for _, id := range []string{"first", "second"} {
		if _, err := s.SubmitTask(context.Background(), request(id)); err != nil {
			t.Fatal(err)
		}
		waitState(t, s, id, pb.TaskState_TASK_STATE_SUCCEEDED)
	}
	got, err := s.GetStatus(context.Background(), &pb.Empty{})
	if err != nil || len(got.Tasks) != 1 || got.Tasks[0].Id != "second" {
		t.Fatalf("payment outlived bounded history: %v", err)
	}
	if got.Tasks[0].Payment.CapturedUnixMs > time.Now().UnixMilli() {
		t.Fatal("capture time is not a receipt timestamp")
	}
}
