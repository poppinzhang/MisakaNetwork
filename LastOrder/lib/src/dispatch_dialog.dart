import 'dart:async';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../generated/misaka/v1/sisters.pb.dart';
import 'controller.dart';
import 'machine_workload.dart';
import 'models.dart';
import 'theme.dart';

const _riskMessage =
    '同一台服务器承担多个抢票任务，容易触发购票网站的风控，可能影响这些任务的执行。建议返回选择空闲服务器，或等待已有任务结束。';

class DispatchDialog extends StatefulWidget {
  const DispatchDialog({
    super.key,
    required this.controller,
    required this.task,
    required this.startDescription,
  });

  final AppController controller;
  final TicketTask task;
  final String startDescription;

  @override
  State<DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends State<DispatchDialog> {
  final _chosen = <String>{};
  bool _busy = false, _refreshing = false;
  String? _error;
  AppController get c => widget.controller;
  bool get _isCurrent => mounted && ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isCurrent) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  TicketTask get _task =>
      c.state.tasks.where((t) => t.id == widget.task.id).firstOrNull ??
      widget.task;

  bool _blocked(Machine machine) => c.isDispatchBlocked(_task, machine.id);

  List<Machine> get _selected => c.state.machines
      .where((m) => _chosen.contains(m.id) && !_blocked(m) && _available(m))
      .toList();

  bool _available(Machine machine) =>
      machine.canConnect && !c.isDeploying(machine.id);

  MachineWorkload _workload(Machine machine) => MachineWorkload.fromState(
    machineId: machine.id,
    localTasks: c.state.tasks,
    status: c.statuses[machine.id],
    connectionFailed: c.connectionErrors.containsKey(machine.id),
  );

  Set<(String, String?)> _risks(Machine machine, MachineWorkload workload) => {
    for (final task in workload.tasks)
      if (!_task.ownsExecution(machine.id, task.id)) (machine.id, task.id),
    if (workload.statusUnknown || workload.stale) (machine.id, null),
  };

  Future<void> _refresh({bool submit = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _refreshing = true;
      _error = null;
    });
    try {
      // Await an in-flight poll too: the final check must use its result.
      await c.refresh();
      if (!mounted) return;
      setState(() => _refreshing = false);
      if (!_isCurrent || !submit) return;
      final confirmedRisks = <(String, String?)>{};
      while (_isCurrent) {
        if (_selected.isEmpty) return;
        final risky = <Machine, MachineWorkload>{};
        for (final machine in _selected) {
          final workload = _workload(machine);
          if (_risks(machine, workload).difference(confirmedRisks).isNotEmpty) {
            risky[machine] = workload;
          }
        }
        if (risky.isEmpty) break;
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('多任务风险'),
            content: SizedBox(
              width: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(_riskMessage),
                  if (risky.values.any((w) => w.statusUnknown || w.stale)) ...[
                    const SizedBox(height: 12),
                    const Text('部分服务器的负载状态未确认，无法排除多任务风险。'),
                  ],
                  const SizedBox(height: 16),
                  for (final entry in risky.entries) ...[
                    Text(
                      entry.key.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    _WorkloadDetails(workload: entry.value),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回选择'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('仍然分发'),
              ),
            ],
          ),
        );
        if (!_isCurrent || proceed != true) return;
        for (final entry in risky.entries) {
          confirmedRisks.addAll(_risks(entry.key, entry.value));
        }
        // Polling may discover additional tasks while confirmation is open.
        // Only the risks actually shown above have been acknowledged.
      }
      if (mounted && _isCurrent) {
        Navigator.pop(context, _selected.map((m) => m.id).toList());
      }
    } catch (error) {
      if (mounted) setState(() => _error = readableError(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _refreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      scrollable: true,
      title: Text('分发「${widget.task.name}」'),
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '提交后将执行真实抢票任务。相同任务可分发到多台机器，请留意重复订单并及时支付。'
              '上次执行确认结束后可重新分发，重新分发会启动新一轮执行；已下单时请先核对订单。',
            ),
            const SizedBox(height: 12),
            Text(
              widget.startDescription,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (_refreshing) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('正在刷新服务器负载…'),
            ],
            if (_error != null)
              Text(_error!, style: TextStyle(color: colors.error)),
            if (c.state.machines.isEmpty) const Text('请先添加 Sisters 服务器。'),
            for (final machine in c.state.machines) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                key: ValueKey('dispatch-machine-${machine.id}'),
                contentPadding: EdgeInsets.zero,
                value: selected.any((m) => m.id == machine.id),
                onChanged: _busy || _blocked(machine) || !_available(machine)
                    ? null
                    : (value) => setState(() {
                        if (value == true) {
                          _chosen.add(machine.id);
                        } else {
                          _chosen.remove(machine.id);
                        }
                      }),
                title: Text(machine.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _blocked(machine)
                          ? '${machine.host}:${machine.port} · 执行未结束或结果待确认'
                          : '${machine.host}:${machine.port}',
                    ),
                    if (!_blocked(machine) &&
                        _task.latestDispatch(machine.id) != null)
                      const Text('上次执行已结束，可重新分发。'),
                    const SizedBox(height: 6),
                    if (!_available(machine))
                      const Text('部署尚未完成，暂不可分发任务。')
                    else
                      _WorkloadDetails(workload: _workload(machine)),
                    if (selected.any((m) => m.id == machine.id) &&
                        _risks(machine, _workload(machine)).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              LucideIcons.triangleAlert,
                              size: 18,
                              color: colors.warning,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '多任务风险：追加任务容易触发购票网站的风控。',
                                style: TextStyle(color: colors.warning),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _refresh(),
          child: const Text('刷新负载'),
        ),
        FilledButton(
          onPressed: _busy || selected.isEmpty
              ? null
              : () => _refresh(submit: true),
          child: Text('提交到 ${selected.length} 台机器'),
        ),
      ],
    );
  }
}

class _WorkloadDetails extends StatelessWidget {
  const _WorkloadDetails({required this.workload});
  final MachineWorkload workload;

  @override
  Widget build(BuildContext context) {
    final uncertain = workload.statusUnknown || workload.stale;
    final warning = TextStyle(color: Theme.of(context).colorScheme.warning);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (workload.stale)
          Text('连接失败，负载未更新；请刷新后核对。', style: warning)
        else if (workload.statusUnknown)
          Text('尚未获取服务器状态，负载未知。', style: warning),
        if (workload.tasks.isEmpty)
          Text(uncertain ? '暂无可确认的任务记录，不能确定服务器空闲。' : '当前负载：0 个任务')
        else ...[
          Text('${uncertain ? '最近已知负载' : '当前负载'}：${workload.tasks.length} 个任务'),
          for (final task in workload.tasks)
            Text('${task.name} · ${_stateLabel(task.state)}'),
        ],
      ],
    );
  }

  String _stateLabel(TaskState? state) => switch (state) {
    TaskState.TASK_STATE_RUNNING => '执行中（含等待开售）',
    TaskState.TASK_STATE_QUEUED => '排队中',
    _ => '状态待确认',
  };
}
