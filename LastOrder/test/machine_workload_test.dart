import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/machine_workload.dart';
import 'package:last_order/src/models.dart';

TicketTask localTask(
  String id, {
  String? name,
  List<String> machines = const ['node'],
  List<TaskDispatch> dispatches = const [],
}) => TicketTask(
  id: id,
  name: name ?? '本地 $id',
  accountId: 'account',
  dispatchedTo: machines,
  dispatches: dispatches,
);

void main() {
  test(
    'workload includes queued and waiting tasks, excluding all terminal states',
    () {
      final workload = MachineWorkload.fromState(
        machineId: 'node',
        localTasks: [],
        status: AgentStatus(
          tasks: [
            TaskStatus(
              id: 'queued',
              name: '排队任务',
              state: TaskState.TASK_STATE_QUEUED,
            ),
            TaskStatus(
              id: 'running',
              name: '执行任务',
              state: TaskState.TASK_STATE_RUNNING,
            ),
            TaskStatus(
              id: 'waiting',
              name: '等待开售任务',
              state: TaskState.TASK_STATE_RUNNING,
              message: '等待开售',
            ),
            TaskStatus(id: 'success', state: TaskState.TASK_STATE_SUCCEEDED),
            TaskStatus(id: 'failed', state: TaskState.TASK_STATE_FAILED),
            TaskStatus(id: 'cancelled', state: TaskState.TASK_STATE_CANCELLED),
          ],
        ),
      );

      expect(workload.tasks.map((task) => task.id), [
        'queued',
        'running',
        'waiting',
      ]);
      expect(workload.hasOtherTasks('new'), isTrue);
      expect(workload.statusUnknown, isFalse);
      expect(workload.stale, isFalse);
    },
  );

  test('remote tasks survive local deletion and unspecified states remain uncertain', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [],
      status: AgentStatus(
        tasks: [
          TaskStatus(
            id: 'remote',
            name: '远端任务',
            state: TaskState.TASK_STATE_RUNNING,
          ),
          TaskStatus(id: 'uncertain'),
        ],
      ),
    );

    expect(workload.tasks.map((task) => task.name), ['远端任务', 'uncertain']);
    expect(workload.tasks.last.state, TaskState.TASK_STATE_UNSPECIFIED);
    expect(workload.hasOtherTasks('remote'), isTrue);
  });

  test('names prefer remote names, then local names, then IDs', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [
        localTask('remote'),
        localTask('local'),
        localTask('id', name: ' '),
      ],
      status: AgentStatus(
        tasks: [
          TaskStatus(
            id: 'remote',
            name: '远端名称',
            state: TaskState.TASK_STATE_QUEUED,
          ),
          TaskStatus(
            id: 'local',
            name: ' ',
            state: TaskState.TASK_STATE_QUEUED,
          ),
          TaskStatus(id: 'id', state: TaskState.TASK_STATE_QUEUED),
        ],
      ),
    );

    expect(workload.tasks.map((task) => task.name), ['远端名称', '本地 local', 'id']);
  });

  test('the same task alone is not a multi-task risk', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [],
      status: AgentStatus(
        tasks: [TaskStatus(id: 'same', state: TaskState.TASK_STATE_RUNNING)],
      ),
    );

    expect(workload.hasOtherTasks('same'), isFalse);
    expect(workload.hasOtherTasks('new'), isTrue);
  });

  test('before first sync, local submissions are shown as unconfirmed', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [
        localTask('submitted'),
        localTask('other-node', machines: ['other']),
        localTask('not-submitted', machines: []),
      ],
    );

    expect(workload.statusUnknown, isTrue);
    expect(workload.stale, isFalse);
    expect(workload.tasks.single.id, 'submitted');
    expect(workload.tasks.single.state, isNull);
    expect(workload.hasOtherTasks('new'), isTrue);
  });

  test('failed sync preserves active tasks and adds missing local submissions only', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [
        localTask('active'),
        localTask('unconfirmed'),
        localTask('success'),
        localTask('failed'),
        localTask('cancelled'),
      ],
      status: AgentStatus(
        tasks: [
          TaskStatus(id: 'active', state: TaskState.TASK_STATE_QUEUED),
          TaskStatus(id: 'success', state: TaskState.TASK_STATE_SUCCEEDED),
          TaskStatus(id: 'failed', state: TaskState.TASK_STATE_FAILED),
          TaskStatus(id: 'cancelled', state: TaskState.TASK_STATE_CANCELLED),
        ],
      ),
      connectionFailed: true,
    );

    expect(workload.statusUnknown, isFalse);
    expect(workload.stale, isTrue);
    expect(workload.tasks.map((task) => task.id), ['active', 'unconfirmed']);
    expect(workload.tasks.first.state, TaskState.TASK_STATE_QUEUED);
    expect(workload.tasks.last.state, isNull);
  });

  test('failed initial sync never reports an unknown machine as idle', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [],
      connectionFailed: true,
    );

    expect(workload.tasks, isEmpty);
    expect(workload.statusUnknown, isTrue);
    expect(workload.stale, isTrue);
  });

  test('fresh empty status retains an unconfirmed submission', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [localTask('historical')],
      status: AgentStatus(),
    );

    expect(workload.tasks.single.id, 'historical');
    expect(workload.tasks.single.state, isNull);
    expect(workload.hasOtherTasks('new'), isTrue);
    expect(workload.statusUnknown, isFalse);
    expect(workload.stale, isFalse);
  });

  test(
    'latest execution IDs retain local names without reviving finished history',
    () {
      final workload = MachineWorkload.fromState(
        machineId: 'node',
        localTasks: [
          localTask(
            'repeated',
            dispatches: [
              const TaskDispatch(
                machineId: 'node',
                executionId: 'repeated',
                finished: true,
              ),
              const TaskDispatch(machineId: 'node', executionId: 'second'),
            ],
          ),
          localTask(
            'finished',
            dispatches: [
              const TaskDispatch(
                machineId: 'node',
                executionId: 'finished',
                finished: true,
              ),
            ],
          ),
        ],
        status: AgentStatus(
          tasks: [
            TaskStatus(id: 'repeated', state: TaskState.TASK_STATE_SUCCEEDED),
            TaskStatus(id: 'second', state: TaskState.TASK_STATE_QUEUED),
          ],
        ),
        connectionFailed: true,
      );

      expect(workload.tasks.length, 1);
      expect(workload.tasks.single.id, 'second');
      expect(workload.tasks.single.name, '本地 repeated');
      expect(workload.tasks.single.state, TaskState.TASK_STATE_QUEUED);
    },
  );

  test('an absent latest execution stays unconfirmed even if an older run finished', () {
    final workload = MachineWorkload.fromState(
      machineId: 'node',
      localTasks: [
        localTask(
          'repeated',
          dispatches: [
            const TaskDispatch(
              machineId: 'node',
              executionId: 'repeated',
              finished: true,
            ),
            const TaskDispatch(machineId: 'node', executionId: 'second'),
          ],
        ),
      ],
      status: AgentStatus(
        tasks: [
          TaskStatus(id: 'repeated', state: TaskState.TASK_STATE_CANCELLED),
        ],
      ),
    );

    expect(workload.tasks.single.id, 'second');
    expect(workload.tasks.single.name, '本地 repeated');
    expect(workload.tasks.single.state, isNull);
  });

  test('persisted completion survives missing history and stale nonterminal reports', () {
    final tasks = [
      localTask(
        'finished',
        dispatches: [
          const TaskDispatch(
            machineId: 'node',
            executionId: 'finished',
            finished: true,
          ),
        ],
      ),
    ];
    for (final status in [
      null,
      AgentStatus(),
      AgentStatus(
        tasks: [
          TaskStatus(id: 'finished', state: TaskState.TASK_STATE_RUNNING),
        ],
      ),
    ]) {
      final workload = MachineWorkload.fromState(
        machineId: 'node',
        localTasks: tasks,
        status: status,
        connectionFailed: true,
      );

      expect(workload.tasks, isEmpty);
    }
  });
}
