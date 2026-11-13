import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../generated/misaka/v1/sisters.pbgrpc.dart';
import 'models.dart';
import 'services.dart';
import 'cloud_controller.dart';
import 'cloud_models.dart';

enum DeploymentPhase { deploying, failed, succeeded }

class MachineDeployment {
  const MachineDeployment({
    this.phase = DeploymentPhase.deploying,
    this.percent = 0,
    this.stage = '准备部署',
    this.fingerprint = '',
    this.error,
  });
  final DeploymentPhase phase;
  final int percent;
  final String stage, fingerprint;
  final String? error;
  bool get active => phase == DeploymentPhase.deploying;
}

class _DeploymentJob {
  _DeploymentJob(
    this.machine,
    this.request,
    this.importedFiles, {
    this.cloudId,
  });
  Machine machine;
  final Map<String, dynamic> request;
  final List<String> importedFiles;
  final String? cloudId;
}

/// Compare addresses independently of SSH/gRPC ports. Canonicalize literal
/// IPv6, IPv4-mapped IPv6, and the spelling of hostnames without DNS requests.
String deploymentHostKey(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  final address = InternetAddress.tryParse(value);
  if (address != null) {
    final bytes = address.rawAddress;
    if (bytes.length == 16 &&
        bytes.take(10).every((b) => b == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return bytes.skip(12).join('.');
    }
    return bytes.join('.');
  }
  return value.endsWith('.') ? value.substring(0, value.length - 1) : value;
}

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.gateway,
    required this.runtime,
    required this.helper,
    Future<List<CloudTemplate>> Function()? cloudTemplateLoader,
  }) {
    cloud = CloudController(
      store: store,
      helper: helper,
      templateLoader: cloudTemplateLoader,
    )..addListener(_cloudChanged);
  }
  final StateStore store;
  late final CloudController cloud;
  final AgentGateway gateway;
  final RuntimeBridge runtime;
  final DeploymentHelper helper;
  SavedState state = SavedState();
  final Map<String, AgentStatus> statuses = {};
  final Map<String, String> connectionErrors = {};
  final Map<String, DateTime> lastSeen = {};
  bool initialized = false, polling = false, disposed = false;

  /// Deployments in flight. Quitting kills the helper, which can leave the
  /// remote half switched without a rollback.
  int deploying = 0;
  final Map<String, MachineDeployment> deployments = {};
  final Map<String, _DeploymentJob> _deploymentJobs = {};
  final Map<String, int> _deploymentRevisions = {};
  final Set<String> _cloudDeploymentStarts = {};
  Future<void>? _pkiInitialization;
  Future<void> _credentialPrune = Future<void>.value();
  int _credentialImportHolds = 0;
  String? startupError;
  Timer? _timer, _accountTimer;
  final Set<String> checkingAccounts = {};
  final Map<String, String> accountMessages = {};
  final Map<String, int> _credentialRevisions = {},
      _checkSequences = {},
      _activeChecks = {};
  final Map<String, Future<void>> _accountOperations = {};
  Future<void> _stateOperation = Future<void>.value();
  Future<void>? _refreshOperation;
  final Set<(String, String)> _dispatching = {};

  static bool _terminal(TaskState state) =>
      state == TaskState.TASK_STATE_SUCCEEDED ||
      state == TaskState.TASK_STATE_FAILED ||
      state == TaskState.TASK_STATE_CANCELLED;

  bool _unfinishedDispatch(TicketTask task, String machineId) {
    final dispatch = task.latestDispatch(machineId);
    if (dispatch?.finished == true) return false;
    final remote = statuses[machineId]?.tasks
        .where((t) => t.id == (dispatch?.executionId ?? task.id))
        .firstOrNull;
    if (remote != null) return !_terminal(remote.state);
    return dispatch != null;
  }

  bool isDispatchBlocked(TicketTask task, String machineId) =>
      _dispatching.contains((task.id, machineId)) ||
      _unfinishedDispatch(
        state.tasks.where((t) => t.id == task.id).firstOrNull ?? task,
        machineId,
      );

  int activeDispatchCount(TicketTask task) {
    final current =
        state.tasks.where((t) => t.id == task.id).firstOrNull ?? task;
    return {
      ...current.dispatchedTo,
      ...state.machines.map((m) => m.id),
      for (final (taskId, machineId) in _dispatching)
        if (taskId == task.id) machineId,
    }.where((id) => isDispatchBlocked(current, id)).length;
  }

  bool canClearExecution(TaskStatus status) => _terminal(status.state);

  bool isExecutionCleared(String machineId, TaskStatus status) =>
      canClearExecution(status) &&
      state.isExecutionCleared(machineId, status.id, status.state.name);

  Future<void> clearExecution(Machine machine, TaskStatus snapshot) async {
    final executionId = snapshot.id;
    final expectedState = snapshot.state;
    if (!_terminal(expectedState)) {
      throw const UserError('只能清除已结束的执行记录。');
    }
    await _save(() {
      if (!state.machines.any((m) => m.id == machine.id)) {
        throw const UserError('机器已被移除，请刷新任务监控。');
      }
      final current = statuses[machine.id]?.tasks
          .where((t) => t.id == executionId)
          .firstOrNull;
      if (current == null || current.state != expectedState) {
        throw const UserError('执行状态已更新，请核对最新结果后再清除。');
      }
      return _withClearedExecutions([
        ClearedExecution(
          machineId: machine.id,
          executionId: executionId,
          state: expectedState.name,
        ),
      ]);
    });
  }

  Future<int> clearFinishedExecutions() async {
    // Snapshot what the user can see before waiting for any other save.
    final candidates = [
      for (final machine in state.machines)
        for (final execution in statuses[machine.id]?.tasks ?? <TaskStatus>[])
          if (canClearExecution(execution) &&
              !isExecutionCleared(machine.id, execution))
            ClearedExecution(
              machineId: machine.id,
              executionId: execution.id,
              state: execution.state.name,
            ),
    ];
    if (candidates.isEmpty) return 0;
    var count = 0;
    await _save(() {
      final current = {
        for (final machine in state.machines)
          for (final execution in statuses[machine.id]?.tasks ?? <TaskStatus>[])
            (machine.id, execution.id): execution.state.name,
      };
      final unchanged = {
        for (final record in candidates)
          if (current[(record.machineId, record.executionId)] == record.state &&
              !state.isExecutionCleared(
                record.machineId,
                record.executionId,
                record.state,
              ))
            (record.machineId, record.executionId): record,
      };
      count = unchanged.length;
      return _withClearedExecutions(unchanged.values.toList());
    });
    return count;
  }

  SavedState _withClearedExecutions(List<ClearedExecution> records) {
    final keys = {
      for (final record in records) (record.machineId, record.executionId),
    };
    return _next(
      // Keep dispatch acknowledgements even if an earlier poll could not save.
      // Clearing cards must never reopen their old execution IDs.
      tasks: [
        for (final task in state.tasks)
          task.withDispatches([
            for (final record in records)
              if (task.ownsExecution(record.machineId, record.executionId))
                TaskDispatch(
                  machineId: record.machineId,
                  executionId: record.executionId,
                  finished: true,
                ),
          ]),
      ],
      clearedExecutions: [
        for (final record in state.clearedExecutions)
          if (!keys.contains((record.machineId, record.executionId))) record,
        ...records,
      ],
    );
  }

  void _cacheStatus(String machineId, AgentStatus incoming) {
    incoming = AgentStatus.fromBuffer(incoming.writeToBuffer());
    final previous = statuses[machineId];
    // A poll started before cancellation must not resurrect a completed run.
    for (var i = 0; i < incoming.tasks.length; i++) {
      final newer = previous?.tasks
          .where((t) => t.id == incoming.tasks[i].id && _terminal(t.state))
          .firstOrNull;
      if (newer != null &&
          (!_terminal(incoming.tasks[i].state) ||
              (newer.state == TaskState.TASK_STATE_SUCCEEDED &&
                  incoming.tasks[i].state != TaskState.TASK_STATE_SUCCEEDED))) {
        incoming.tasks[i] = newer;
      }
    }
    statuses[machineId] = incoming;
  }

  void _cacheTaskStatus(String machineId, TaskStatus task) {
    final next = AgentStatus.fromBuffer(
      (statuses[machineId] ?? AgentStatus()).writeToBuffer(),
    );
    final index = next.tasks.indexWhere((t) => t.id == task.id);
    if (index < 0) {
      next.tasks.add(task);
    } else {
      next.tasks[index] = task;
    }
    _cacheStatus(machineId, next);
    _notify();
  }

  Future<void> initialize({bool poll = true}) async {
    try {
      state = await store.load();
      initialized = true;
      unawaited(cloud.initialize());
      if (state.machines.any((m) => m.deploymentPending)) {
        await _save(
          () => _next(
            machines: [
              for (final m in state.machines)
                m.deploymentPending
                    ? m.copyWith(
                        deploymentPending: false,
                        deploymentError: '上次部署被中断，远程状态未确认。请检查机器后重新部署。',
                      )
                    : m,
            ],
          ),
          retainOnFailure: true,
        );
      }
      await _pruneCredentials();
      if (poll) {
        _timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
        unawaited(refresh());
        _accountTimer = Timer.periodic(
          const Duration(minutes: 5),
          (_) => checkAccounts(),
        );
        unawaited(checkAccounts());
      }
    } catch (e) {
      startupError = readableError(e);
    }
    _notify();
  }

  void _notify() {
    if (!disposed) notifyListeners();
  }

  void _cloudChanged() {
    for (final machine in state.machines) {
      if (cloudIdForMachine(machine) != null && !cloudMachineUsable(machine)) {
        // Keep last task/order reports for user review, but never display the
        // last successful poll as a currently usable released cloud server.
        lastSeen.remove(machine.id);
        connectionErrors[machine.id] = '关联云服务器不可用、释放中或记录待核实；已暂停连接和任务分发。';
      }
    }
    _notify();
  }

  Future<void> _save(
    SavedState Function() build, {
    bool retainOnFailure = false,
  }) async {
    final previous = _stateOperation;
    final done = Completer<void>();
    _stateOperation = done.future;
    await previous;
    try {
      if (!initialized) throw const UserError('配置尚未加载，无法保存。');
      final next = build();
      try {
        await store.save(next);
      } catch (_) {
        if (retainOnFailure) {
          state = next;
          _notify();
        }
        rethrow;
      }
      state = next;
      _notify();
    } finally {
      done.complete();
    }
  }

  Future<T> _forAccount<T>(String id, Future<T> Function() action) async {
    final previous = _accountOperations[id] ?? Future<void>.value();
    final done = Completer<void>();
    _accountOperations[id] = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(_accountOperations[id], done.future)) {
        _accountOperations.remove(id);
      }
    }
  }

  Account? _account(String id) =>
      state.accounts.where((a) => a.id == id).firstOrNull;
  Account _requireAccount(String id) =>
      _account(id) ?? (throw const UserError('账号已被移除，请重新选择。'));
  TicketTask _requireTask(String id) =>
      state.tasks.where((t) => t.id == id).firstOrNull ??
      (throw const UserError('任务已被删除，请重新选择。'));
  void _bumpRevision(String id) =>
      _credentialRevisions[id] = (_credentialRevisions[id] ?? 0) + 1;
  Future<void> _replaceAccount(Account value, {bool retainOnFailure = false}) =>
      _save(
        () => _next(
          accounts: state.accounts
              .map((a) => a.id == value.id ? value : a)
              .toList(),
        ),
        retainOnFailure: retainOnFailure,
      );

  SavedState _next({
    List<Machine>? machines,
    List<Account>? accounts,
    List<TicketTask>? tasks,
    List<ClearedExecution>? clearedExecutions,
    AppThemeMode? themeMode,
  }) => SavedState(
    machines: machines ?? state.machines,
    accounts: accounts ?? state.accounts,
    tasks: tasks ?? state.tasks,
    clearedExecutions: clearedExecutions ?? state.clearedExecutions,
    themeMode: themeMode ?? state.themeMode,
  );

  Future<void> setThemeMode(AppThemeMode mode) =>
      _save(() => _next(themeMode: mode));

  /// Rejects a name another machine uses. Check it before deploying: a
  /// deployment restarts the remote service and cancels its running tasks.
  void requireUniqueMachineName(String name, {String? id}) {
    if ([
      ...currentMachines,
      ..._deploymentJobs.values.map((job) => job.machine),
    ].any((m) => m.id != id && m.name == name)) {
      throw const UserError('机器名称已存在，请使用不同的名称。');
    }
  }

  void requireUniqueDeploymentHost(String host, {String? id}) {
    final key = deploymentHostKey(host);
    if ([
      ...currentMachines,
      ..._deploymentJobs.values.map((job) => job.machine),
    ].any((m) => m.id != id && deploymentHostKey(m.host) == key)) {
      throw const UserError('该 IP 或主机地址已在机器列表中，请使用原机器的「重新部署」。');
    }
  }

  bool isDeploying(String id) =>
      _deploymentJobs.containsKey(id) || (deployments[id]?.active ?? false);

  void holdCredentialImports() => _credentialImportHolds++;

  void releaseCredentialImports() {
    if (_credentialImportHolds > 0) _credentialImportHolds--;
    if (_credentialImportHolds == 0) unawaited(_pruneCredentials());
  }

  Future<String?> importCredential() async {
    holdCredentialImports();
    try {
      // A previous dialog may already have started pruning. Wait before the
      // picker creates a new file, so that cleanup cannot delete this import.
      await _credentialPrune;
      return await importProtectedFile(store);
    } finally {
      // The surrounding dialog continues to hold the selected file.
      if (_credentialImportHolds > 0) _credentialImportHolds--;
    }
  }

  Future<void> addMachine(Machine machine) async {
    if (cloudIdForMachine(machine) != null) {
      throw const UserError('云服务器连接请通过「部署 Sisters」更新。');
    }
    if (isDeploying(machine.id)) {
      throw const UserError('该机器正在部署，请等待部署结束。');
    }
    requireUniqueMachineName(machine.name, id: machine.id);
    if (machine.host.trim().isEmpty ||
        machine.port < 1 ||
        machine.port > 65535) {
      throw const UserError('请输入有效的主机和端口。');
    }
    if (machine.caCert.isEmpty ||
        machine.clientCert.isEmpty ||
        machine.clientKey.isEmpty) {
      throw const UserError('mTLS 的 CA、客户端证书和私钥均必填。');
    }
    await _save(() {
      if (isDeploying(machine.id)) {
        throw const UserError('该机器正在部署，请等待部署结束。');
      }
      requireUniqueMachineName(machine.name, id: machine.id);
      return _next(
        machines: [...state.machines.where((e) => e.id != machine.id), machine],
      );
    });
    await _pruneCredentials();
    unawaited(refresh());
  }

  Future<void> removeMachine(Machine machine) async {
    if (isDeploying(machine.id)) {
      throw const UserError('该机器正在部署，请等待部署结束后再移除。');
    }
    await _save(() {
      if (isDeploying(machine.id)) {
        throw const UserError('该机器正在部署，请等待部署结束后再移除。');
      }
      return _next(
        machines: state.machines.where((e) => e.id != machine.id).toList(),
        clearedExecutions: state.clearedExecutions
            .where((record) => record.machineId != machine.id)
            .toList(),
      );
    });
    await _pruneCredentials();
    statuses.remove(machine.id);
    connectionErrors.remove(machine.id);
    lastSeen.remove(machine.id);
    deployments.remove(machine.id);
    _notify();
  }

  /// Deletes imported key and certificate copies that no saved machine uses:
  /// a removed machine's files, or an SSH key copy left when the app stopped
  /// during a deployment. Dialogs and background jobs hold imports until their
  /// owner either saves or finishes using them.
  Future<void> _pruneCredentials() async {
    if (_credentialImportHolds > 0 || _deploymentJobs.isNotEmpty) return;
    try {
      final previous = _credentialPrune;
      final operation = previous.then((_) async {
        if (_credentialImportHolds > 0 || _deploymentJobs.isNotEmpty) return;
        await store.pruneCredentials({
          for (final m in state.machines) ...[
            m.caCert,
            m.clientCert,
            m.clientKey,
          ],
        });
      });
      _credentialPrune = operation.catchError((Object _) {});
      await operation;
    } catch (_) {
      // Retried after the next machine change or start; the files stay private.
    }
  }

  Future<void> refresh() {
    final current = _refreshOperation;
    if (current != null) return current;
    if (disposed || !initialized) return Future<void>.value();
    // Publish the shared operation before notifying listeners, which may also
    // request a refresh. Every caller waits for this round's final state.
    final operation = Future<void>.microtask(_refresh);
    _refreshOperation = operation;
    polling = true;
    _notify();
    return operation;
  }

  Future<void> _refresh() async {
    try {
      await Future.wait(
        state.machines
            .where(
              (m) =>
                  m.canConnect && cloudMachineUsable(m) && !isDeploying(m.id),
            )
            .map((m) async {
              try {
                final s = await gateway.status(m);
                if (!state.machines.any((v) => identical(v, m)) ||
                    isDeploying(m.id) ||
                    !cloudMachineUsable(m)) {
                  return;
                }
                _cacheStatus(m.id, s);
                connectionErrors.remove(m.id);
                lastSeen[m.id] = DateTime.now();
              } catch (e) {
                if (state.machines.any((v) => identical(v, m)) &&
                    !isDeploying(m.id) &&
                    cloudMachineUsable(m)) {
                  connectionErrors[m.id] = readableError(e);
                }
              }
            }),
      );
      // Also covers submissions whose response was lost before it was recorded.
      try {
        if (!disposed) await _recordDispatches();
      } catch (_) {
        // Retried on the next poll; dispatch reports its own recording failures.
      }
    } finally {
      polling = false;
      _refreshOperation = null;
      _notify();
    }
  }

  /// Persist terminal acknowledgements separately from the remote history,
  /// which disappears when Sisters restarts or evicts a completed execution.
  Future<void> _recordDispatches() async {
    List<TaskDispatch> updates(TicketTask task) => [
      for (final entry in statuses.entries)
        for (final remote in entry.value.tasks)
          if (task.ownsExecution(entry.key, remote.id) &&
              !task.dispatches.any(
                (d) =>
                    d.machineId == entry.key &&
                    d.executionId == remote.id &&
                    (d.finished || !_terminal(remote.state)),
              ))
            TaskDispatch(
              machineId: entry.key,
              executionId: remote.id,
              finished: _terminal(remote.state),
            ),
    ];
    // Capture acknowledgements now: a different poll may omit the record
    // while this save waits behind another local state operation.
    final observed = {for (final task in state.tasks) task.id: updates(task)};
    if (!observed.values.any((value) => value.isNotEmpty)) return;
    await _save(
      () => _next(
        tasks: [
          for (final t in state.tasks)
            t.withDispatches(observed[t.id] ?? const []),
        ],
      ),
    );
  }

  Future<Account> addAccount(
    String name,
    List<dynamic> cookies, {
    required String uid,
  }) async {
    if (cookies.isEmpty) throw const UserError('登录结果未包含有效 Cookie。');
    if (!Account.isValidUid(uid)) {
      throw const UserError('登录结果缺少可验证的数字账号 UID，请重新登录。');
    }
    final account = Account(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? '哔哩哔哩账号' : name.trim(),
      uid: uid,
      authStatus: AccountAuthStatus.valid,
      lastChecked: DateTime.now(),
    );
    await store.writeSecret('account.${account.id}', jsonEncode(cookies));
    try {
      await _save(() => _next(accounts: [...state.accounts, account]));
    } catch (_) {
      try {
        await _deleteAccountSecret(account.id);
      } catch (_) {
        throw const UserError('账号未能保存，且安全存储中的新增凭据未能清理，请检查安全存储权限。');
      }
      rethrow;
    }
    return account;
  }

  Future<Account> refreshAccount(
    Account account, {
    required String name,
    required List<dynamic> cookies,
    required String uid,
  }) {
    // Block dispatch snapshots immediately, even while this refresh is queued.
    _bumpRevision(account.id);
    return _forAccount(account.id, () async {
      final current = _requireAccount(account.id);
      if (cookies.isEmpty || !Account.isValidUid(uid)) {
        throw const UserError('登录结果缺少有效 Cookie 或可验证的账号 UID，请重新登录。');
      }
      if (current.uid != uid) {
        throw const UserError('本次登录的账号与原账号 UID 不一致，原账号及任务保持不变。请登录原账号。');
      }
      // Also invalidate checks that read the old credential while we were queued.
      _bumpRevision(current.id);
      final oldSecret = await store.readSecret('account.${current.id}');
      final replacement = current.copyWith(
        name: name.trim().isEmpty ? current.name : name.trim(),
        authStatus: AccountAuthStatus.valid,
        lastChecked: DateTime.now(),
      );
      await store.writeSecret('account.${current.id}', jsonEncode(cookies));
      try {
        await _replaceAccount(replacement);
      } catch (_) {
        try {
          if (oldSecret == null ||
              current.authStatus == AccountAuthStatus.expired) {
            await _deleteAccountSecret(current.id);
          } else {
            await store.writeSecret('account.${current.id}', oldSecret);
          }
        } catch (_) {
          accountMessages[current.id] = '重新登录未能保存，且凭据回滚失败，请检查安全存储权限后重新登录。';
          try {
            await _replaceAccount(
              current.copyWith(authStatus: AccountAuthStatus.unknown),
              retainOnFailure: true,
            );
          } catch (_) {}
          throw UserError(accountMessages[current.id]!);
        }
        rethrow;
      }
      accountMessages.remove(current.id);
      _notify();
      return replacement;
    });
  }

  Future<List<dynamic>> cookies(Account account) =>
      _forAccount(account.id, () async {
        final current = _requireAccount(account.id);
        if (current.authStatus != AccountAuthStatus.valid) {
          throw UserError(
            accountMessages[current.id] ??
                (current.authStatus == AccountAuthStatus.expired
                    ? '账号登录已失效，请重新登录后继续。'
                    : '账号状态尚未确认，请先检查登录状态。'),
          );
        }
        final value = await store.readSecret('account.${current.id}');
        if (value == null) throw const UserError('安全存储中没有此账号的 Cookie，请重新登录。');
        try {
          return jsonDecode(value) as List<dynamic>;
        } catch (_) {
          throw const UserError('账号 Cookie 无法读取，请重新登录。');
        }
      });

  Future<void> ensureAccountValid(Account account) async {
    final status = await checkAccount(account);
    if (status != AccountAuthStatus.valid) {
      throw UserError(
        accountMessages[account.id] ??
            (status == AccountAuthStatus.expired
                ? '账号登录已失效，请重新登录后继续。'
                : '暂时无法确认登录状态，请检查网络后重试。'),
      );
    }
  }

  Future<void> checkAccounts() async {
    if (disposed || !initialized) return;
    await Future.wait(
      state.accounts.toList().map((account) async {
        if (checkingAccounts.contains(account.id)) return;
        try {
          await checkAccount(account);
        } catch (e) {
          if (_account(account.id) != null) {
            accountMessages[account.id] = readableError(e);
          }
        }
      }),
    );
    _notify();
  }

  Future<AccountAuthStatus> checkAccount(Account account) async {
    final id = account.id;
    final sequence = (_checkSequences[id] ?? 0) + 1;
    _checkSequences[id] = sequence;
    _activeChecks[id] = (_activeChecks[id] ?? 0) + 1;
    checkingAccounts.add(id);
    _notify();
    try {
      final snapshot = await _forAccount<(List<dynamic>, int)?>(id, () async {
        final current = _account(id);
        if (current == null) return null;
        if (current.authStatus == AccountAuthStatus.expired) {
          await _expireAccount(current);
          return null;
        }
        List<dynamic>? value;
        try {
          final raw = await store.readSecret('account.$id');
          if (raw != null) value = jsonDecode(raw) as List<dynamic>;
        } catch (_) {
          await _markUnknown(current, '无法读取安全存储中的账号凭据，请检查权限后重试；现有凭据未删除。');
          return null;
        }
        if (value == null || value.isEmpty) {
          await _markUnknown(current, '登录凭据不存在，请重新登录。');
          return null;
        }
        return (value, _credentialRevisions[id] ?? 0);
      });
      if (snapshot == null) {
        return _account(id)?.authStatus ?? AccountAuthStatus.unknown;
      }
      final (cookie, revision) = snapshot;
      Map<String, dynamic> response;
      try {
        response = await runtime.call('login_state', {'cookies': cookie});
      } catch (_) {
        response = {
          'status': 'unknown',
          'message': '暂时无法确认登录状态，请检查网络后重试；现有凭据未删除。',
        };
      }
      return await _forAccount(id, () async {
        final current = _account(id);
        if (current == null) return AccountAuthStatus.unknown;
        if (revision != (_credentialRevisions[id] ?? 0) ||
            sequence != _checkSequences[id]) {
          return AccountAuthStatus.unknown;
        }
        if (response['status'] == 'expired' && response['logged_in'] != true) {
          _bumpRevision(id);
          await _expireAccount(current);
          return AccountAuthStatus.expired;
        }
        if (response['status'] == 'valid' && response['logged_in'] == true) {
          final uid = response['uid'];
          if (uid is! String ||
              !Account.isValidUid(uid) ||
              current.uid != uid) {
            await _markUnknown(current, '平台返回的账号身份无法与原账号核对，凭据未删除。请重新登录原账号。');
            return AccountAuthStatus.unknown;
          }
          final next = current.copyWith(
            name: (response['username'] as String? ?? '').trim().isEmpty
                ? current.name
                : response['username'] as String,
            authStatus: AccountAuthStatus.valid,
            lastChecked: DateTime.now(),
          );
          try {
            await _replaceAccount(next);
          } catch (_) {
            await _markUnknown(current, '登录验证成功，但账号状态未能保存，请检查本地存储后重试。');
            return AccountAuthStatus.unknown;
          }
          accountMessages.remove(id);
          _notify();
          return AccountAuthStatus.valid;
        }
        await _markUnknown(current, '暂时无法确认登录状态，请检查网络或稍后重试；现有凭据未删除。');
        return AccountAuthStatus.unknown;
      });
    } finally {
      final remaining = (_activeChecks[id] ?? 1) - 1;
      if (remaining <= 0) {
        _activeChecks.remove(id);
        checkingAccounts.remove(id);
      } else {
        _activeChecks[id] = remaining;
      }
      _notify();
    }
  }

  Future<void> _markUnknown(Account account, String message) async {
    final next = account.copyWith(
      authStatus: account.authStatus == AccountAuthStatus.expired
          ? AccountAuthStatus.expired
          : AccountAuthStatus.unknown,
      lastChecked: DateTime.now(),
    );
    accountMessages[account.id] = message;
    try {
      await _replaceAccount(next, retainOnFailure: true);
    } catch (_) {
      accountMessages[account.id] = '$message 状态也未能保存。';
    }
    _notify();
  }

  Future<void> _expireAccount(Account current) async {
    final id = current.id;
    final expired = current.copyWith(
      authStatus: AccountAuthStatus.expired,
      lastChecked: DateTime.now(),
    );
    var statusSaved = true;
    try {
      await _replaceAccount(expired, retainOnFailure: true);
    } catch (_) {
      statusSaved = false;
    }
    try {
      await _deleteAccountSecret(id);
    } catch (_) {
      accountMessages[id] = '登录已失效，但本地 Cookie 清理未完成。请检查安全存储权限后再次检查；任务已阻止分发。';
      _notify();
      throw UserError(accountMessages[id]!);
    }
    accountMessages[id] = statusSaved
        ? '登录已失效，已清除本地 Cookie；已有任务已保留，请重新登录原账号。'
        : '登录已失效，已清除本地 Cookie，但状态未能保存。请检查本地存储后重新登录原账号。';
    _notify();
    if (!statusSaved) throw UserError(accountMessages[id]!);
  }

  Future<void> _deleteAccountSecret(String id) async {
    await store.deleteSecret('account.$id');
    if (await store.readSecret('account.$id') != null) {
      throw const UserError('安全存储中的 Cookie 未能删除。');
    }
  }

  static dynamic _withoutCookies(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          if (!{
            'cookie',
            'cookies',
            'cookiejson',
          }.contains(entry.key.toString().toLowerCase().replaceAll('_', '')))
            entry.key.toString(): _withoutCookies(entry.value),
      };
    }
    if (value is List) return value.map(_withoutCookies).toList();
    return value;
  }

  Map<String, dynamic> _configWithoutCookies(String value) =>
      Map<String, dynamic>.from(_withoutCookies(jsonDecode(value)) as Map);

  Future<void> removeAccount(Account account) =>
      _forAccount(account.id, () async {
        final current = _requireAccount(account.id);
        if (state.tasks.any((t) => t.accountId == current.id)) {
          throw const UserError('请先删除使用此账号的任务，再移除账号。');
        }
        _bumpRevision(current.id);
        await _deleteAccountSecret(current.id);
        await _save(
          () => _next(
            accounts: state.accounts.where((a) => a.id != current.id).toList(),
          ),
        );
        accountMessages.remove(current.id);
        _notify();
      });

  Future<TicketTask> addTask(
    String name,
    Account account,
    Map<String, dynamic> config, {
    String startAt = '',
    int requestIntervalMs = defaultRequestIntervalMs,
    TaskSummary? summary,
  }) => _forAccount(account.id, () async {
    final current = _requireAccount(account.id);
    if (name.trim().isEmpty) throw const UserError('请填写任务名称。');
    final start = normalizeStartAt(startAt);
    validateRequestIntervalMs(requestIntervalMs);
    if (current.authStatus != AccountAuthStatus.valid) {
      throw const UserError('账号未处于有效登录状态，请先检查或重新登录。');
    }
    final raw = await store.readSecret('account.${current.id}');
    if (raw == null) throw const UserError('登录凭据不存在，请重新登录。');
    final clean = Map<String, dynamic>.from(_withoutCookies(config) as Map);
    final validation = await runtime.call('validate', {
      'config': {...clean, 'cookies': jsonDecode(raw)},
    });
    if (validation['ok'] != true) {
      throw UserError(
        '任务配置无效：${(validation['errors'] as List? ?? []).join('；')}',
      );
    }
    final task = TicketTask(
      id: const Uuid().v4(),
      name: name.trim(),
      accountId: current.id,
      startAt: start,
      requestIntervalMs: requestIntervalMs,
      summary: summary,
    );
    await store.writeSecret('task.${task.id}', jsonEncode(clean));
    try {
      await _save(() => _next(tasks: [...state.tasks, task]));
    } catch (_) {
      await store.deleteSecret('task.${task.id}');
      rethrow;
    }
    return task;
  });

  Future<void> removeTask(TicketTask task) =>
      _forAccount(task.accountId, () async {
        await store.deleteSecret('task.${task.id}');
        if (await store.readSecret('task.${task.id}') != null) {
          throw const UserError('任务配置未能从安全存储删除，请检查权限后重试。');
        }
        await _save(
          () =>
              _next(tasks: state.tasks.where((t) => t.id != task.id).toList()),
        );
      });

  Future<Map<String, String>> dispatch(
    TicketTask task,
    List<Machine> machines,
  ) async {
    if (machines.isEmpty) throw const UserError('请至少选择一台 Sisters。');
    final errors = <String, String>{};
    final saved = _requireTask(task.id);
    final pending = <Machine>[];
    final revisions = {
      for (final machine in machines)
        machine.id: _deploymentRevisions[machine.id] ?? 0,
    };
    for (final machine in machines) {
      final current = state.machines
          .where((m) => m.id == machine.id)
          .firstOrNull;
      if (!cloudMachineUsable(machine)) {
        errors[machine.name] = '关联云服务器不可用或正在释放，请先核对云端状态。';
      } else if (isDeploying(machine.id) ||
          !machine.canConnect ||
          (current != null && !current.canConnect)) {
        errors[machine.name] = '该机器部署尚未完成，请部署成功后再分发任务。';
      } else if (isDispatchBlocked(saved, machine.id)) {
        errors[machine.name] = '此任务在该机器上的执行尚未结束或状态待确认，请刷新状态后再分发。';
      } else {
        // Reserve before any await, including account checks and local saves.
        _dispatching.add((task.id, machine.id));
        pending.add(machine);
      }
    }
    if (pending.isEmpty) return errors;
    _notify();
    try {
      final account = _requireAccount(saved.accountId);
      await ensureAccountValid(account);
      final (cookie, config, revision) = await _forAccount(
        account.id,
        () async {
          final current = _requireAccount(account.id);
          if (current.authStatus != AccountAuthStatus.valid) {
            throw const UserError('账号状态已变化，请重新检查后分发。');
          }
          final revision = _credentialRevisions[account.id] ?? 0;
          final raw = await store.readSecret('account.${account.id}');
          if (raw == null) throw const UserError('登录凭据不存在，请重新登录。');
          final stored = await store.readSecret('task.${task.id}');
          if (stored == null) throw const UserError('安全存储中没有任务配置，请重新创建任务。');
          return (
            jsonDecode(raw) as List<dynamic>,
            jsonEncode(_configWithoutCookies(stored)),
            revision,
          );
        },
      );
      void requireUnchanged() {
        if (revision != (_credentialRevisions[account.id] ?? 0) ||
            _account(account.id)?.authStatus != AccountAuthStatus.valid) {
          throw const UserError('账号凭据或登录状态已变化，本次未继续分发，请重新检查后重试。');
        }
      }

      void requireMachineReady(Machine machine) {
        if (!cloudMachineUsable(machine)) {
          throw const UserError('关联云服务器不可用或正在释放，本次未继续分发。');
        }
        if (revisions[machine.id] != (_deploymentRevisions[machine.id] ?? 0)) {
          throw const UserError('该机器的部署状态已变化，请重新选择后再分发任务。');
        }
        final current = state.machines
            .where((m) => m.id == machine.id)
            .firstOrNull;
        if (isDeploying(machine.id) ||
            !machine.canConnect ||
            (current != null && !current.canConnect)) {
          throw const UserError('该机器部署尚未完成，请部署成功后再分发任务。');
        }
      }

      requireUnchanged();
      await Future.wait(
        pending.map((machine) async {
          String? executionId;
          var reserved = false, sent = false;
          try {
            requireUnchanged();
            requireMachineReady(machine);
            final capabilities = await gateway.status(machine);
            requireUnchanged();
            requireMachineReady(machine);
            _cacheStatus(machine.id, capabilities);
            connectionErrors.remove(machine.id);
            lastSeen[machine.id] = DateTime.now();
            await _recordDispatches();
            // Older agents silently drop unknown request fields.
            if (saved.startAt.isNotEmpty && !capabilities.supportsTimeStart) {
              throw const UserError(
                '该机器上的 Sisters 不支持开售时间，请重新部署后再分发，以免立即开始抢票。',
              );
            }
            if (!capabilities.supportsRequestInterval) {
              throw const UserError('该机器上的 Sisters 不支持抢票请求间隔设置，请重新部署后再分发。');
            }
            await _save(() {
              requireUnchanged();
              requireMachineReady(machine);
              final current = _requireTask(task.id);
              if (_unfinishedDispatch(current, machine.id)) {
                throw const UserError('此任务在该机器上的执行尚未结束或状态待确认，请刷新状态后再分发。');
              }
              // The first execution uses the configuration ID; every later
              // execution has a new ID so Sisters cannot return an old result.
              executionId = current.latestDispatch(machine.id) == null
                  ? current.id
                  : const Uuid().v4();
              return _next(
                tasks: [
                  for (final t in state.tasks)
                    if (t.id == task.id)
                      t.withDispatches([
                        TaskDispatch(
                          machineId: machine.id,
                          executionId: executionId!,
                        ),
                      ])
                    else
                      t,
                ],
              );
            });
            reserved = true;
            requireUnchanged();
            requireMachineReady(machine);
            _requireTask(task.id);
            sent = true;
            final result = await gateway.submit(
              machine,
              TaskRequest(
                id: executionId,
                name: saved.name,
                cookieJson: jsonEncode(cookie),
                configJson: config,
                timeStart: saved.startAt,
                requestIntervalMs: saved.requestIntervalMs,
              ),
            );
            if (result.id != executionId) {
              throw const UserError('Sisters 返回了不匹配的执行记录，请刷新并核对任务状态。');
            }
            requireMachineReady(machine);
            _cacheTaskStatus(machine.id, result);
            await _recordDispatches();
          } catch (e) {
            errors[machine.name] = readableError(e);
            if (reserved && (!sent || e is TaskSubmissionRejected)) {
              // No execution was accepted. A network/response failure is not
              // enough evidence to roll this intent back.
              try {
                await _save(
                  () => _next(
                    tasks: [
                      for (final t in state.tasks)
                        t.id == task.id
                            ? t.withoutDispatch(machine.id, executionId!)
                            : t,
                    ],
                  ),
                );
              } catch (_) {
                errors[machine.name] = '任务未提交，但本地分发记录未能清理，请检查存储后重试。';
              }
            } else if (reserved && sent) {
              errors[machine.name] =
                  '${readableError(e)} 执行结果未确认，请刷新状态核对；不会自动重复提交。';
            }
          }
        }),
      );
      await refresh();
      return errors;
    } finally {
      for (final machine in pending) {
        _dispatching.remove((task.id, machine.id));
      }
      _notify();
    }
  }

  Future<void> cancel(Machine m, String id) async {
    if (!cloudMachineUsable(m)) {
      throw const UserError('关联云服务器不可用或正在释放，请先核对云端状态。');
    }
    final revision = _deploymentRevisions[m.id] ?? 0;
    final result = await gateway.cancel(m, id);
    if (revision != (_deploymentRevisions[m.id] ?? 0) ||
        isDeploying(m.id) ||
        !cloudMachineUsable(m)) {
      return;
    }
    if (result.id != id) {
      throw const UserError('Sisters 返回了不匹配的执行记录，请刷新并核对任务状态。');
    }
    _cacheTaskStatus(m.id, result);
    await _recordDispatches();
    await refresh();
  }

  /// The stable ID binds the cloud resource to its saved Sisters connection,
  /// including failed deployments and restarts, without copying SSH secrets.
  Machine? tencentMachine(String cloudId) => state.machines
      .where((machine) => machine.id == 'tencent-$cloudId')
      .firstOrNull;

  String? cloudIdForMachine(Machine machine) =>
      machine.id.startsWith('tencent-') ? machine.id.substring(8) : null;

  bool isReleasedCloudMachine(Machine machine) {
    final id = cloudIdForMachine(machine);
    return cloud.initialized &&
        id != null &&
        cloud.jobs.any((job) => job.id == id && job.releaseConfirmed);
  }

  // Keep saved machines for monitoring, dispatch history and payment reports;
  // only the active machine list drops API-confirmed released instances.
  List<Machine> get currentMachines => List.unmodifiable(
    state.machines.where((machine) => !isReleasedCloudMachine(machine)),
  );

  bool cloudMachineUsable(Machine machine) {
    final id = cloudIdForMachine(machine);
    if (id == null) return true;
    final resource = cloud.jobs.where((job) => job.id == id).firstOrNull;
    return cloud.initialized &&
        resource != null &&
        resource.isReal &&
        resource.phase == CloudMachinePhase.created &&
        resource.instanceId.isNotEmpty &&
        resource.publicIp.isNotEmpty &&
        deploymentHostKey(resource.publicIp) == deploymentHostKey(machine.host);
  }

  Future<void> startTencentDeployment(String cloudId) async {
    if (!initialized || disposed) throw const UserError('配置尚未加载，无法部署。');
    final resource = await cloud.beginTencentDeployment(cloudId);
    _cloudDeploymentStarts.add(cloudId);
    var transferred = false;
    try {
      final privateKey = await cloud.tencentDeploymentPrivateKey();
      if (disposed) throw const UserError('应用已关闭，部署已中断。');
      final existing = tencentMachine(cloudId);
      if (existing != null &&
          deploymentHostKey(existing.host) !=
              deploymentHostKey(resource.publicIp)) {
        throw const UserError('云服务器公网地址已改变，请先核对并移除旧的 Sisters 连接记录，再重新部署。');
      }
      if (existing != null) {
        final login = existing.deploymentUsername;
        final hasCredentials =
            existing.caCert.isNotEmpty ||
            existing.clientCert.isNotEmpty ||
            existing.clientKey.isNotEmpty;
        final stoppedBeforeLogin =
            !hasCredentials &&
            (existing.deploymentError.startsWith('SSH 认证失败') ||
                existing.deploymentError.startsWith('SSH 认证被拒绝') ||
                existing.deploymentError.startsWith('未确认 SSH 主机指纹'));
        if ((login.isNotEmpty && login != TencentAccessPolicy.sshUsername) ||
            (login.isEmpty && !stoppedBeforeLogin)) {
          throw const UserError(
            '旧连接使用其他或未记录的 SSH 账号，不能直接切换账号部署。请先停止旧账号下的 Sisters、核对任务，再移除本地连接并重新部署；不会自动停止或迁移旧服务。',
          );
        }
      }
      await startDeployment(
        name: existing?.name ?? resource.name,
        host: resource.publicIp,
        port: TencentAccessPolicy.sistersPort,
        existing: existing,
        cloudId: cloudId,
        request: {
          'username': TencentAccessPolicy.sshUsername,
          'port': TencentAccessPolicy.sshPort,
          'private_key': privateKey,
          'enable_linger_with_sudo': true,
        },
      );
      // The background job owns the lease until deployment finishes.
      transferred = true;
    } finally {
      _cloudDeploymentStarts.remove(cloudId);
      if (!transferred) cloud.endTencentDeployment(cloudId);
    }
  }

  /// Persist the visible placeholder before starting any remote work. The
  /// reservation happens before the first await, including concurrent calls
  /// whose local saves have not finished yet.
  Future<void> startDeployment({
    required String name,
    required String host,
    required int port,
    required Map<String, dynamic> request,
    Machine? existing,
    List<String> importedFiles = const [],
    String? cloudId,
  }) async {
    if (!initialized || disposed) throw const UserError('配置尚未加载，无法部署。');
    name = name.trim();
    host = host.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (name.isEmpty || host.isEmpty || port < 1 || port > 65535) {
      throw const UserError('请填写有效的机器名称、主机地址和端口。');
    }
    final id =
        existing?.id ??
        (cloudId == null ? const Uuid().v4() : 'tencent-$cloudId');
    if ((id.startsWith('tencent-') || cloudId != null) &&
        (cloudId == null ||
            id != 'tencent-$cloudId' ||
            !_cloudDeploymentStarts.contains(cloudId))) {
      throw const UserError('请从云服务器卡片使用内置密钥部署 Sisters。');
    }
    if (isDeploying(id)) throw const UserError('该机器正在部署，请等待部署结束。');
    final previous = state.machines.where((m) => m.id == id).firstOrNull;
    if (existing != null && previous == null) {
      throw const UserError('机器已被移除，请重新添加。');
    }
    requireUniqueMachineName(name, id: id);
    requireUniqueDeploymentHost(host, id: id);
    final sshPort = request['port'] ?? 22;
    if (sshPort is! int || sshPort < 1 || sshPort > 65535) {
      throw const UserError('SSH 端口须在 1–65535 之间。');
    }
    if ((request['username'] as String? ?? '').trim().isEmpty ||
        ((request['password'] as String? ?? '').isEmpty &&
            (request['private_key_path'] as String? ?? '').isEmpty &&
            (request['private_key'] as String? ?? '').isEmpty)) {
      throw const UserError('请填写 SSH 用户和密码或私钥。');
    }
    final fingerprint =
        previous != null &&
            deploymentHostKey(previous.host) == deploymentHostKey(host)
        ? previous.fingerprint
        : '';
    final pending = Machine(
      id: id,
      name: name,
      host: host,
      port: port,
      caCert: previous?.caCert ?? '',
      clientCert: previous?.clientCert ?? '',
      clientKey: previous?.clientKey ?? '',
      serverName: host,
      fingerprint: fingerprint,
      deploymentPending: true,
      // Persist only the fixed cloud login policy, never a manually entered
      // SSH account from an ordinary deployment.
      deploymentUsername: cloudId == null
          ? ''
          : TencentAccessPolicy.sshUsername,
    );
    final job = _DeploymentJob(
      pending,
      {
        for (final key in [
          'username',
          'password',
          'private_key_path',
          'private_key',
          'private_key_passphrase',
        ])
          if (request.containsKey(key)) key: request[key],
        if (cloudId != null) 'enable_linger_with_sudo': true,
        'host': host,
        'port': sshPort,
        'grpc_port': port,
        'host_key_fingerprint': fingerprint,
        'server_name': host,
        'remote_directory': '.local/share/misaka',
      },
      List.of(importedFiles),
      cloudId: cloudId,
    );
    _deploymentJobs[id] = job;
    _deploymentRevisions[id] = (_deploymentRevisions[id] ?? 0) + 1;
    deployments[id] = const MachineDeployment();
    deploying++;
    _notify();
    try {
      await _save(() {
        requireUniqueMachineName(name, id: id);
        requireUniqueDeploymentHost(host, id: id);
        final machines = [...state.machines];
        final index = machines.indexWhere((m) => m.id == id);
        if (index < 0) {
          if (existing != null) throw const UserError('机器已被移除，请重新添加。');
          machines.add(pending);
        } else {
          machines[index] = pending;
        }
        return _next(machines: machines);
      });
    } catch (_) {
      _deploymentJobs.remove(id);
      deployments.remove(id);
      deploying--;
      job.request.clear();
      _notify();
      // A rejected start has not taken ownership of the dialog's imports.
      rethrow;
    }
    statuses.remove(id);
    connectionErrors.remove(id);
    lastSeen.remove(id);
    _notify();
    unawaited(_continueDeployment(job));
  }

  Future<void> _continueDeployment(_DeploymentJob job) async {
    final id = job.machine.id;
    try {
      void onProgress(DeploymentProgress progress) {
        if (disposed || !identical(_deploymentJobs[id], job)) return;
        final previous = deployments[id]?.percent ?? 0;
        final percent = progress.percent.clamp(previous, 99);
        deployments[id] = MachineDeployment(
          percent: percent,
          stage: progress.percent >= 100 ? '保存机器连接' : progress.stage,
          fingerprint: job.machine.fingerprint,
        );
        _notify();
      }

      var result = await _invokeDeploy(job.request, onProgress: onProgress);
      if (disposed) {
        await _releaseDeployment(job);
        return;
      }
      if (result['needs_confirmation'] == true) {
        final fingerprint = result['fingerprint'];
        if (job.machine.fingerprint.isNotEmpty ||
            fingerprint is! String ||
            !RegExp(r'^SHA256:[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]$')
                .hasMatch(fingerprint)) {
          throw const UserError('无法验证服务器身份，部署已停止。');
        }
        // Trust on first use: pin the discovered host before authenticating.
        // The helper aborts discovery before authentication; the next call
        // verifies this exact pin and never accepts a replacement automatically.
        final pinned = job.machine.copyWith(fingerprint: fingerprint);
        deployments[id] = MachineDeployment(
          percent: deployments[id]?.percent ?? 0,
          stage: '保存服务器身份',
        );
        _notify();
        try {
          await _save(
            () => _next(
              machines: [
                for (final m in state.machines) m.id == id ? pinned : m,
              ],
            ),
          );
        } catch (_) {
          throw const UserError('服务器身份未能保存，部署已停止。请检查本地存储后重试。');
        }
        job.machine = pinned;
        job.request['host_key_fingerprint'] = fingerprint;
        result = await _invokeDeploy(job.request, onProgress: onProgress);
        if (disposed) {
          await _releaseDeployment(job);
          return;
        }
        if (result['needs_confirmation'] == true) {
          throw const UserError('服务器身份与已保存记录不一致，部署已停止。');
        }
      }
      String credential(String key) {
        final value = result[key];
        if (value is! String || value.isEmpty) {
          throw const UserError('部署返回的连接凭据不完整，请检查机器后重新部署。');
        }
        return value;
      }

      final machine = Machine(
        id: id,
        name: job.machine.name,
        host: job.machine.host,
        port: job.machine.port,
        caCert: credential('ca_cert'),
        clientCert: credential('client_cert'),
        clientKey: credential('client_key'),
        serverName: result['server_name'] as String? ?? job.machine.host,
        fingerprint: job.machine.fingerprint,
        deploymentUsername: job.machine.deploymentUsername,
      );
      try {
        await _save(
          () => _next(
            machines: [
              for (final m in state.machines) m.id == id ? machine : m,
            ],
          ),
        );
      } catch (_) {
        throw const UserError('远程部署已完成，但本地连接未能保存。请检查存储权限后重新部署。');
      }
      deployments[id] = const MachineDeployment(
        phase: DeploymentPhase.succeeded,
        percent: 100,
        stage: '部署完成',
      );
      if (result['reachable'] == false) {
        connectionErrors[id] =
            '本机无法直接连接 ${machine.host}:${machine.port}。请确认防火墙或安全组已放行该 TCP 端口，且地址可从本机访问。';
      }
      await _releaseDeployment(job);
      // Preserve the actionable firewall hint until the next scheduled poll.
      if (result['reachable'] != false) unawaited(refresh());
    } catch (e) {
      if (disposed) {
        await _releaseDeployment(job);
      } else {
        await _failDeployment(job, readableError(e));
      }
    }
  }

  Future<void> _failDeployment(_DeploymentJob job, String message) async {
    final id = job.machine.id;
    final percent = deployments[id]?.percent ?? 0;
    var failure = message;
    try {
      await _save(
        () => _next(
          machines: [
            for (final m in state.machines)
              m.id == id
                  ? m.copyWith(
                      deploymentPending: false,
                      deploymentError: message,
                    )
                  : m,
          ],
        ),
        retainOnFailure: true,
      );
    } catch (_) {
      failure = '$message 本地状态未能保存，重启后请检查机器。';
    }
    deployments[id] = MachineDeployment(
      phase: DeploymentPhase.failed,
      percent: percent,
      stage: '部署失败',
      fingerprint: job.machine.fingerprint,
      error: failure,
    );
    await _releaseDeployment(job);
  }

  Future<void> _releaseDeployment(_DeploymentJob job) async {
    final id = job.machine.id;
    if (!identical(_deploymentJobs[id], job)) return;
    _deploymentJobs.remove(id);
    deploying--;
    job.request.clear();
    if (job.cloudId != null) cloud.endTencentDeployment(job.cloudId!);
    final keep = {
      for (final machine in state.machines) ...[
        machine.caCert,
        machine.clientCert,
        machine.clientKey,
      ],
      for (final active in _deploymentJobs.values) ...active.importedFiles,
    };
    for (final path in job.importedFiles) {
      if (keep.contains(path)) continue;
      try {
        await File(path).delete();
      } on FileSystemException {
        // A later credential prune retries cleanup in the private directory.
      }
    }
    await _pruneCredentials();
    _notify();
  }

  Future<Map<String, dynamic>> _invokeDeploy(
    Map<String, dynamic> fields, {
    void Function(DeploymentProgress)? onProgress,
  }) async {
    if (disposed) throw const UserError('应用已关闭，部署已中断。');
    final directory = await store.directory();
    if (disposed) throw const UserError('应用已关闭，部署已中断。');
    final pki = p.join(directory, 'pki');
    // Desktop helpers are separate processes. Finish initial key generation
    // once before allowing their concurrent Deploy calls to read that PKI.
    final initialization = _pkiInitialization ??= helper
        .call({'action': 'init_pki', 'directory': pki})
        .then<void>((_) {});
    try {
      await initialization;
    } catch (_) {
      if (identical(_pkiInitialization, initialization)) {
        _pkiInitialization = null;
      }
      rethrow;
    }
    if (disposed) throw const UserError('应用已关闭，部署已中断。');
    final bundles = await deploymentBundlesDirectory();
    if (disposed) throw const UserError('应用已关闭，部署已中断。');
    return helper.call({
      'action': 'deploy',
      'pki_directory': pki,
      'bundles_directory': bundles,
      ...fields,
    }, onProgress: onProgress);
  }

  Future<Map<String, dynamic>> deploy(Map<String, dynamic> fields) async {
    deploying++;
    try {
      return await _invokeDeploy(fields);
    } finally {
      deploying--;
    }
  }

  @override
  void dispose() {
    disposed = true;
    cloud.removeListener(_cloudChanged);
    cloud.dispose();
    _timer?.cancel();
    _accountTimer?.cancel();
    for (final job in _deploymentJobs.values.toList()) {
      job.request.clear();
      if (job.cloudId != null) cloud.endTencentDeployment(job.cloudId!);
    }
    super.dispose();
  }
}
