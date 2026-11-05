import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../generated/misaka/v1/sisters.pbgrpc.dart';
import 'models.dart';
import 'services.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.gateway,
    required this.runtime,
    required this.helper,
  });
  final StateStore store;
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
  String? startupError;
  Timer? _timer, _accountTimer;
  final Set<String> checkingAccounts = {};
  final Map<String, String> accountMessages = {};
  final Map<String, int> _credentialRevisions = {},
      _checkSequences = {},
      _activeChecks = {};
  final Map<String, Future<void>> _accountOperations = {};
  Future<void> _stateOperation = Future<void>.value();
  Future<void> initialize({bool poll = true}) async {
    try {
      state = await store.load();
      initialized = true;
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
  }) => SavedState(
    machines: machines ?? state.machines,
    accounts: accounts ?? state.accounts,
    tasks: tasks ?? state.tasks,
  );

  /// Rejects a name another machine uses. Check it before deploying: a
  /// deployment restarts the remote service and cancels its running tasks.
  void requireUniqueMachineName(String name, {String? id}) {
    if (state.machines.any((m) => m.id != id && m.name == name)) {
      throw const UserError('机器名称已存在，请使用不同的名称。');
    }
  }

  Future<void> addMachine(Machine machine) async {
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
    await _save(
      () => _next(
        machines: [...state.machines.where((e) => e.id != machine.id), machine],
      ),
    );
    await _pruneCredentials();
    unawaited(refresh());
  }

  Future<void> removeMachine(Machine machine) async {
    await _save(
      () => _next(
        machines: state.machines.where((e) => e.id != machine.id).toList(),
      ),
    );
    await _pruneCredentials();
    statuses.remove(machine.id);
    connectionErrors.remove(machine.id);
    lastSeen.remove(machine.id);
    _notify();
  }

  /// Deletes imported key and certificate copies that no saved machine uses:
  /// a removed machine's files, or an SSH key copy left when the app stopped
  /// during a deployment. Machine dialogs are modal, so none is mid-import.
  Future<void> _pruneCredentials() async {
    try {
      await store.pruneCredentials({
        for (final m in state.machines) ...[
          m.caCert,
          m.clientCert,
          m.clientKey,
        ],
      });
    } catch (_) {
      // Retried after the next machine change or start; the files stay private.
    }
  }

  Future<void> refresh() async {
    if (polling || disposed || !initialized) return;
    polling = true;
    _notify();
    await Future.wait(
      state.machines.map((m) async {
        try {
          final s = await gateway.status(m);
          if (!state.machines.any((v) => v.id == m.id)) return;
          statuses[m.id] = s;
          connectionErrors.remove(m.id);
          lastSeen[m.id] = DateTime.now();
        } catch (e) {
          if (state.machines.any((v) => v.id == m.id)) {
            connectionErrors[m.id] = readableError(e);
          }
        }
      }),
    );
    // Also covers submissions whose response was lost before it was recorded.
    final held = <String, Set<String>>{};
    for (final m in state.machines) {
      for (final t in statuses[m.id]?.tasks ?? const <TaskStatus>[]) {
        (held[t.id] ??= {}).add(m.id);
      }
    }
    try {
      if (!disposed) await _recordDispatches(held);
    } catch (_) {
      // Retried on the next poll; dispatch reports its own recording failures.
    }
    polling = false;
    _notify();
  }

  /// Persists the machines known to hold each task, so dispatch never submits
  /// the task to them again.
  Future<void> _recordDispatches(
    Map<String, Set<String>> machinesByTask,
  ) async {
    bool unrecorded(TicketTask t) => (machinesByTask[t.id] ?? const <String>{})
        .any((id) => !t.dispatchedTo.contains(id));
    if (!state.tasks.any(unrecorded)) return;
    await _save(
      () => _next(
        tasks: [
          for (final t in state.tasks)
            unrecorded(t) ? t.withDispatched(machinesByTask[t.id]!) : t,
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
  }) => _forAccount(account.id, () async {
    final current = _requireAccount(account.id);
    if (name.trim().isEmpty) throw const UserError('请填写任务名称。');
    final start = normalizeStartAt(startAt);
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
    // Sisters forgets accepted task IDs when it restarts or evicts history, so
    // resubmitting the same ID could run the task, and place orders, again.
    final saved = _requireTask(task.id);
    final pending = <Machine>[];
    for (final machine in machines) {
      if (saved.dispatchedTo.contains(machine.id)) {
        errors[machine.name] = '此任务已提交到该机器，为避免重复执行不会再次提交。如需重新执行，请新建任务。';
      } else {
        pending.add(machine);
      }
    }
    if (pending.isEmpty) return errors;
    final account = _requireAccount(task.accountId);
    await ensureAccountValid(account);
    final (cookie, config, revision) = await _forAccount(account.id, () async {
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
    });
    void requireUnchanged() {
      if (revision != (_credentialRevisions[account.id] ?? 0) ||
          _account(account.id)?.authStatus != AccountAuthStatus.valid) {
        throw const UserError('账号凭据或登录状态已变化，本次未继续分发，请重新检查后重试。');
      }
    }

    requireUnchanged();
    final accepted = <String>{};
    await Future.wait(
      pending.map((machine) async {
        try {
          requireUnchanged();
          // An older agent would drop time_start and start buying immediately.
          if (saved.startAt.isNotEmpty &&
              !(await gateway.status(machine)).supportsTimeStart) {
            errors[machine.name] = '该机器上的 Sisters 不支持开售时间，请重新部署后再分发，以免立即开始抢票。';
            return;
          }
          requireUnchanged();
          final result = await gateway.submit(
            machine,
            TaskRequest(
              id: task.id,
              name: task.name,
              cookieJson: jsonEncode(cookie),
              configJson: config,
              timeStart: saved.startAt,
            ),
          );
          accepted.add(machine.id);
          if (result.state == TaskState.TASK_STATE_SUCCEEDED ||
              result.state == TaskState.TASK_STATE_FAILED ||
              result.state == TaskState.TASK_STATE_CANCELLED) {
            errors[machine.name] = '此任务已有执行结果，本次未重新执行。请新建任务后重试。';
          }
        } catch (e) {
          errors[machine.name] = readableError(e);
        }
      }),
    );
    try {
      await _recordDispatches({task.id: accepted});
    } catch (_) {
      for (final machine in pending.where((m) => accepted.contains(m.id))) {
        errors[machine.name] = '已提交，但本地分发记录未能保存。Sisters 重启后请勿再次分发此任务，以免重复执行。';
      }
    }
    await refresh();
    return errors;
  }

  Future<void> cancel(Machine m, String id) async {
    await gateway.cancel(m, id);
    await refresh();
  }

  Future<Map<String, dynamic>> deploy(Map<String, dynamic> fields) async {
    deploying++;
    try {
      final directory = await store.directory();
      final pki = p.join(directory, 'pki');
      await helper.call({'action': 'init_pki', 'directory': pki});
      return await helper.call({
        'action': 'deploy',
        'pki_directory': pki,
        'bundles_directory': await deploymentBundlesDirectory(),
        ...fields,
      });
    } finally {
      deploying--;
    }
  }

  @override
  void dispose() {
    disposed = true;
    _timer?.cancel();
    _accountTimer?.cancel();
    super.dispose();
  }
}
