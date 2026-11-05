package main

import (
	"testing"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
)

func TestOfflineTaskCannotBeConfiguredWithTicketsOrCredentials(t *testing.T) {
	request := invalidTask()
	if err := verifyOfflineRequest(request); err != nil {
		t.Fatal(err)
	}
	if request.ConfigJson != `{}` || request.CookieJson != syntheticCookie {
		t.Fatal("smoke payload must remain the fixed invalid configuration")
	}
	for _, mutated := range []*pb.TaskRequest{nil, {ConfigJson: `{"project_id":1}`, CookieJson: syntheticCookie}, {ConfigJson: `{}`, CookieJson: `[{"name":"SESSDATA","value":"replacement"}]`}} {
		if verifyOfflineRequest(mutated) == nil {
			t.Fatal("smoke accepted a non-fixed task payload")
		}
	}
}

func TestTerminalStateClassification(t *testing.T) {
	for _, state := range []pb.TaskState{pb.TaskState_TASK_STATE_UNSPECIFIED, pb.TaskState_TASK_STATE_RUNNING, pb.TaskState_TASK_STATE_QUEUED} {
		if terminal(state) {
			t.Fatalf("nonterminal state classified as terminal: %v", state)
		}
	}
	for _, state := range []pb.TaskState{pb.TaskState_TASK_STATE_SUCCEEDED, pb.TaskState_TASK_STATE_FAILED, pb.TaskState_TASK_STATE_CANCELLED} {
		if !terminal(state) {
			t.Fatalf("terminal state not recognized: %v", state)
		}
	}
}
