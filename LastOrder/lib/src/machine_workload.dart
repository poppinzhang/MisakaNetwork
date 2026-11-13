import '../generated/misaka/v1/sisters.pb.dart';
import 'models.dart';

/// A task which may still execute on a machine. A missing state means only
/// the local submission record is available, so completion is unconfirmed.
class LoadedTask {
  const LoadedTask({required this.id, required this.name, required this.state});

  final String id, name;
  final TaskState? state;
}

/// The workload shown before dispatch, using remote state whenever available.
/// Confirmed terminal executions never count as work. A submitted execution
/// missing from remote history remains unconfirmed until its outcome is known.
class MachineWorkload {
  MachineWorkload._({
    required List<LoadedTask> tasks,
    required this.statusUnknown,
    required this.stale,
  }) : tasks = List.unmodifiable(tasks);

  factory MachineWorkload.fromState({
    required String machineId,
    required List<TicketTask> localTasks,
    AgentStatus? status,
    bool connectionFailed = false,
  }) {
    final localById = {
      for (final task in localTasks) ...{
        task.id: task,
        for (final dispatch in task.dispatches)
          if (dispatch.machineId == machineId) dispatch.executionId: task,
      },
    };
    final finishedIds = {
      for (final task in localTasks)
        for (final dispatch in task.dispatches)
          if (dispatch.machineId == machineId && dispatch.finished)
            dispatch.executionId,
    };
    final remoteById = {
      for (final task in status?.tasks ?? const <TaskStatus>[]) task.id: task,
    };
    String name(String id, String remoteName) {
      if (remoteName.trim().isNotEmpty) return remoteName.trim();
      final localName = localById[id]?.name.trim() ?? '';
      return localName.isNotEmpty ? localName : id;
    }

    final tasks = <LoadedTask>[
      for (final task in remoteById.values)
        if (!finishedIds.contains(task.id) &&
            task.state != TaskState.TASK_STATE_SUCCEEDED &&
            task.state != TaskState.TASK_STATE_FAILED &&
            task.state != TaskState.TASK_STATE_CANCELLED)
          LoadedTask(
            id: task.id,
            name: name(task.id, task.name),
            state: task.state,
          ),
      for (final task in localTasks)
        if (task.latestDispatch(machineId) case final dispatch?)
          if (!dispatch.finished &&
              !remoteById.containsKey(dispatch.executionId))
            LoadedTask(
              id: dispatch.executionId,
              name: name(dispatch.executionId, ''),
              state: null,
            ),
    ];
    return MachineWorkload._(
      tasks: tasks,
      statusUnknown: status == null,
      stale: connectionFailed,
    );
  }

  final List<LoadedTask> tasks;
  final bool statusUnknown, stale;

  bool hasOtherTasks(String taskId) => tasks.any((task) => task.id != taskId);
}
