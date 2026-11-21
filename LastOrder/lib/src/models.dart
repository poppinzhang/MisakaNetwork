import 'dart:convert';

const defaultSistersPort = 20001;

class Machine {
  Machine({
    required this.id,
    required this.name,
    required this.host,
    this.port = defaultSistersPort,
    required this.caCert,
    required this.clientCert,
    required this.clientKey,
    this.serverName = '',
    this.fingerprint = '',
    this.deploymentPending = false,
    this.deploymentError = '',
    this.deploymentUsername = '',
  });
  final String id,
      name,
      host,
      caCert,
      clientCert,
      clientKey,
      serverName,
      fingerprint,
      deploymentError,
      deploymentUsername;
  final int port;
  final bool deploymentPending;

  bool get canConnect =>
      !deploymentPending &&
      deploymentError.isEmpty &&
      caCert.isNotEmpty &&
      clientCert.isNotEmpty &&
      clientKey.isNotEmpty;

  Machine copyWith({
    String? fingerprint,
    bool? deploymentPending,
    String? deploymentError,
  }) => Machine(
    id: id,
    name: name,
    host: host,
    port: port,
    caCert: caCert,
    clientCert: clientCert,
    clientKey: clientKey,
    serverName: serverName,
    fingerprint: fingerprint ?? this.fingerprint,
    deploymentPending: deploymentPending ?? this.deploymentPending,
    deploymentError: deploymentError ?? this.deploymentError,
    deploymentUsername: deploymentUsername,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'caCert': caCert,
    'clientCert': clientCert,
    'clientKey': clientKey,
    'serverName': serverName,
    'fingerprint': fingerprint,
    'deploymentPending': deploymentPending,
    'deploymentError': deploymentError,
    'deploymentUsername': deploymentUsername,
  };
  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
    id: j['id'] as String,
    name: j['name'] as String,
    host: j['host'] as String,
    port: j['port'] as int? ?? defaultSistersPort,
    caCert: j['caCert'] as String,
    clientCert: j['clientCert'] as String,
    clientKey: j['clientKey'] as String,
    serverName: j['serverName'] as String? ?? '',
    fingerprint: j['fingerprint'] as String? ?? '',
    deploymentPending: j['deploymentPending'] as bool? ?? false,
    deploymentError: j['deploymentError'] as String? ?? '',
    deploymentUsername: j['deploymentUsername'] as String? ?? '',
  );
}

enum AccountAuthStatus { valid, expired, unknown }

class Account {
  Account({
    required this.id,
    required this.name,
    required this.uid,
    this.authStatus = AccountAuthStatus.unknown,
    this.lastChecked,
  }) {
    if (!isValidUid(uid)) throw const FormatException('账号 UID 必须为正整数。');
  }
  static bool isValidUid(String uid) => RegExp(r'^[1-9][0-9]*$').hasMatch(uid);
  final String id, name, uid;
  final AccountAuthStatus authStatus;
  final DateTime? lastChecked;
  Account copyWith({
    String? name,
    AccountAuthStatus? authStatus,
    DateTime? lastChecked,
  }) => Account(
    id: id,
    name: name ?? this.name,
    uid: uid,
    authStatus: authStatus ?? this.authStatus,
    lastChecked: lastChecked ?? this.lastChecked,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'uid': uid,
    'authStatus': authStatus.name,
    if (lastChecked != null)
      'lastChecked': lastChecked!.toUtc().toIso8601String(),
  };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    name: j['name'] as String,
    uid: j['uid'] as String,
    authStatus: AccountAuthStatus.values.byName(j['authStatus'] as String),
    lastChecked: j['lastChecked'] == null
        ? null
        : DateTime.parse(j['lastChecked'] as String),
  );
}

/// Normalizes a Beijing-time purchase start such as `2026-11-20 20:00` to the
/// protocol form `2026-11-20T20:00:00`. An empty value starts immediately.
String normalizeStartAt(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$')
      .firstMatch(text);
  if (m != null) {
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
    // DateTime rolls invalid fields over, so only real times survive a round trip.
    final t = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (t.year == parts[0] &&
        t.month == parts[1] &&
        t.day == parts[2] &&
        t.hour == parts[3] &&
        t.minute == parts[4] &&
        t.second == parts[5]) {
      return '${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6] ?? '00'}';
    }
  }
  throw const UserError('开售时间应为北京时间，例如 2026-11-20 20:00:00。');
}

/// Public selection details suitable for ordinary task metadata. Purchase
/// context, buyer details and credentials must stay in secret storage.
class TaskSummary {
  const TaskSummary({
    this.projectId = '',
    this.projectName = '',
    this.screenName = '',
    this.ticketName = '',
    this.selectedDate = '',
    this.quantity = 0,
  });

  /// The event that supplied the options, including linked merchandise tickets.
  final String projectId;
  final String projectName, screenName, ticketName, selectedDate;
  final int quantity;

  factory TaskSummary.fromSelection(
    Map<String, dynamic> purchase,
    int ticketIndex,
    int quantity,
  ) {
    final options = purchase['ticket_options'];
    if (options is! List ||
        ticketIndex < 0 ||
        ticketIndex >= options.length ||
        options[ticketIndex] is! Map) {
      throw const UserError('所选场次或票档无效，请重新读取演出后选择。');
    }
    if (quantity <= 0) throw const UserError('购票数量必须大于零。');
    final ticket = options[ticketIndex] as Map;
    String text(Object? value) {
      if (value == null) return '';
      if (value is String) return value.trim();
      throw const UserError('演出或票档信息格式异常，请重新读取演出后重试。');
    }

    final screen = text(ticket['screen']);
    final description = text(ticket['desc']);
    final source = purchase['project_id'];
    final projectId = source is int ? source.toString() : text(source);
    if (projectId.isNotEmpty && !RegExp(r'^[1-9][0-9]*$').hasMatch(projectId)) {
      throw const UserError('演出编号异常，请重新读取演出后重试。');
    }
    return TaskSummary(
      projectId: projectId,
      projectName: text(purchase['project_name']),
      screenName: screen.isEmpty ? text(ticket['screen_name']) : screen,
      ticketName: description.isEmpty ? text(ticket['display']) : description,
      selectedDate: text(purchase['selected_date']),
      quantity: quantity,
    );
  }

  Map<String, dynamic> toJson() => {
    if (projectId.isNotEmpty) 'projectId': projectId,
    'projectName': projectName,
    'screenName': screenName,
    'ticketName': ticketName,
    'selectedDate': selectedDate,
    'quantity': quantity,
  };

  factory TaskSummary.fromJson(Map<String, dynamic> j) {
    String text(String key) {
      final value = j[key];
      if (value == null) return '';
      if (value is String) return value.trim();
      throw const FormatException('任务摘要格式无效。');
    }

    final quantity = j['quantity'] ?? 0;
    final projectId = text('projectId');
    if (quantity is! int ||
        quantity < 0 ||
        (projectId.isNotEmpty &&
            !RegExp(r'^[1-9][0-9]*$').hasMatch(projectId))) {
      throw const FormatException('任务摘要格式无效。');
    }
    return TaskSummary(
      projectId: projectId,
      projectName: text('projectName'),
      screenName: text('screenName'),
      ticketName: text('ticketName'),
      selectedDate: text('selectedDate'),
      quantity: quantity,
    );
  }
}

// Bilibili buyer `id_type` codes, named as in the preview of the pinned
// biliTickerBuy revision. Display only: buyer records are passed on unchanged.
const _buyerIdTypeNames = {
  0: '身份证',
  1: '护照',
  2: '港澳居民来往内地通行证',
  3: '台湾居民来往大陆通行证',
  4: '外国人永久居留身份证',
};

/// Names a buyer's document type, so buyers who share a name can be told apart.
/// Codes this app does not recognize are shown as unknown rather than guessed.
String buyerIdTypeName(Object? idType) {
  final code = switch (idType) {
    int value => value,
    String value => int.tryParse(value.trim(), radix: 10),
    _ => null,
  };
  return _buyerIdTypeNames[code] ?? '证件类型未知';
}

/// A buyer choice such as `张三（护照）`.
String buyerLabel(Object? buyer, int index) {
  final person = buyer is Map ? buyer : const {};
  final name = person['name'];
  final shown = name is String && name.trim().isNotEmpty
      ? name.trim()
      : '购票人 ${index + 1}';
  return '$shown（${buyerIdTypeName(person['id_type'])}）';
}

/// Characters the platform may use to hide part of a value, as in
/// `138****1234`.
final maskedValue = RegExp(r'[*＊•●·…]|[xX]{3,}');

/// The contact a checked buyer suggests: the record's trimmed name and phone.
/// Missing values come back empty, as does a partly hidden phone, since no one
/// can be reached on it; the user types those instead.
({String name, String tel}) buyerContact(Object? buyer) {
  final person = buyer is Map ? buyer : const {};
  String text(Object? value) => value is String ? value.trim() : '';
  final tel = text(person['tel']);
  return (
    name: text(person['name']),
    tel: maskedValue.hasMatch(tel) ? '' : tel,
  );
}

const defaultRequestIntervalMs = 500;
const minRequestIntervalMs = 100;
const maxRequestIntervalMs = 60000;
const requestIntervalError = '抢票请求间隔应为 100–60000 毫秒的整数。';
const defaultStartDelayMs = 30;
const maxStartDelayMs = 60000;
const startDelayError = '开抢额外延迟应为 0–60000 毫秒的整数。';

int validateRequestIntervalMs(int value) {
  if (value < minRequestIntervalMs || value > maxRequestIntervalMs) {
    throw const UserError(requestIntervalError);
  }
  return value;
}

int _parseMilliseconds(String value, String error) {
  final text = value.trim();
  final parsed = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
  if (parsed == null) throw UserError(error);
  return parsed;
}

int parseRequestIntervalMs(String value) =>
    validateRequestIntervalMs(_parseMilliseconds(value, requestIntervalError));

int validateStartDelayMs(int value) {
  if (value < 0 || value > maxStartDelayMs) {
    throw const UserError(startDelayError);
  }
  return value;
}

int parseStartDelayMs(String value) =>
    validateStartDelayMs(_parseMilliseconds(value, startDelayError));

int _storedRequestIntervalMs(Object? value) {
  // Tasks saved before the interval field existed used a fixed 1000 ms.
  if (value == null) return 1000;
  if (value is! int ||
      value < minRequestIntervalMs ||
      value > maxRequestIntervalMs) {
    throw const FormatException(requestIntervalError);
  }
  return value;
}

/// A durable submission intent. Only an acknowledged terminal state releases
/// it; a missing remote record is not evidence that execution finished.
class TaskDispatch {
  const TaskDispatch({
    required this.machineId,
    required this.executionId,
    this.finished = false,
  });
  final String machineId, executionId;
  final bool finished;

  Map<String, dynamic> toJson() => {
    'machineId': machineId,
    'executionId': executionId,
    'finished': finished,
  };

  factory TaskDispatch.fromJson(Map<String, dynamic> j) => TaskDispatch(
    machineId: j['machineId'] as String,
    executionId: j['executionId'] as String,
    finished: j['finished'] as bool? ?? false,
  );
}

class TicketTask {
  TicketTask({
    required this.id,
    required this.name,
    required this.accountId,
    this.startAt = '',
    this.startDelayMs = defaultStartDelayMs,
    this.requestIntervalMs = defaultRequestIntervalMs,
    this.configRevision = 0,
    List<String> dispatchedTo = const [],
    List<TaskDispatch> dispatches = const [],
    this.summary,
  }) : dispatches = List.unmodifiable([
         for (final machineId in dispatchedTo)
           if (!dispatches.any((d) => d.machineId == machineId))
             TaskDispatch(machineId: machineId, executionId: id),
         ...dispatches,
       ]) {
    validateRequestIntervalMs(requestIntervalMs);
    validateStartDelayMs(startDelayMs);
    if (configRevision < 0) throw const FormatException('任务配置修订号无效。');
  }
  final String id, name, accountId;

  /// Purchase start as Beijing time `YYYY-MM-DDTHH:MM:SS`; empty starts as
  /// soon as a machine accepts the task.
  final String startAt;
  final int startDelayMs;
  final int requestIntervalMs;
  final int configRevision;

  // Keep the previous secret readable until the new metadata commits atomically.
  String get configKey => configRevision.isEven ? 'task.$id' : 'task.$id.alt';
  String get inactiveConfigKey =>
      configRevision.isEven ? 'task.$id.alt' : 'task.$id';

  final List<TaskDispatch> dispatches;
  List<String> get dispatchedTo =>
      dispatches.map((d) => d.machineId).toSet().toList()..sort();

  TaskDispatch? latestDispatch(String machineId) =>
      dispatches.where((d) => d.machineId == machineId).lastOrNull;

  bool ownsExecution(String machineId, String executionId) =>
      executionId == id ||
      dispatches.any(
        (d) => d.machineId == machineId && d.executionId == executionId,
      );

  final TaskSummary? summary;
  TicketTask withDispatched(Iterable<String> machineIds) => withDispatches([
    for (final machineId in machineIds)
      if (latestDispatch(machineId) == null)
        TaskDispatch(machineId: machineId, executionId: id),
  ]);

  TicketTask withDispatches(Iterable<TaskDispatch> updates) {
    final next = [...dispatches];
    for (final update in updates) {
      final index = next.indexWhere(
        (d) =>
            d.machineId == update.machineId &&
            d.executionId == update.executionId,
      );
      if (index < 0) {
        next.add(update);
      } else if (update.finished) {
        next[index] = update;
      }
    }
    return _withDispatches(next);
  }

  TicketTask withoutDispatch(String machineId, String executionId) =>
      _withDispatches([
        for (final d in dispatches)
          if (d.machineId != machineId || d.executionId != executionId) d,
      ]);

  TicketTask _withDispatches(List<TaskDispatch> next) => TicketTask(
    id: id,
    name: name,
    accountId: accountId,
    startAt: startAt,
    startDelayMs: startDelayMs,
    requestIntervalMs: requestIntervalMs,
    configRevision: configRevision,
    dispatches: next,
    summary: summary,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'accountId': accountId,
    'startAt': startAt,
    'startDelayMs': startDelayMs,
    'requestIntervalMs': requestIntervalMs,
    if (configRevision != 0) 'configRevision': configRevision,
    'dispatches': dispatches.map((d) => d.toJson()).toList(),
    if (summary != null) 'summary': summary!.toJson(),
  };
  factory TicketTask.fromJson(Map<String, dynamic> j) => TicketTask(
    id: j['id'] as String,
    name: j['name'] as String,
    accountId: j['accountId'] as String,
    startAt: j['startAt'] as String? ?? '',
    startDelayMs: switch (j['startDelayMs']) {
      null when !j.containsKey('startDelayMs') => defaultStartDelayMs,
      int delay when delay >= 0 && delay <= maxStartDelayMs => delay,
      _ => throw const FormatException(startDelayError),
    },
    requestIntervalMs: _storedRequestIntervalMs(j['requestIntervalMs']),
    configRevision: switch (j['configRevision']) {
      null when !j.containsKey('configRevision') => 0,
      int revision => revision,
      _ => throw const FormatException('任务配置修订号无效。'),
    },
    dispatchedTo: [
      for (final id in j['dispatchedTo'] as List? ?? const []) id as String,
    ],
    dispatches: [
      for (final value in j['dispatches'] as List? ?? const [])
        TaskDispatch.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    summary: j['summary'] == null
        ? null
        : TaskSummary.fromJson(Map<String, dynamic>.from(j['summary'] as Map)),
  );
}

enum AppThemeMode { system, light, dark }

/// A local presentation preference, independent of dispatch bookkeeping.
/// Include the acknowledged outcome so a later confirmed order can reappear.
class ClearedExecution {
  const ClearedExecution({
    required this.machineId,
    required this.executionId,
    required this.state,
  });

  final String machineId, executionId, state;

  Map<String, dynamic> toJson() => {
    'machineId': machineId,
    'executionId': executionId,
    'state': state,
  };

  factory ClearedExecution.fromJson(Map<String, dynamic> j) => ClearedExecution(
    machineId: j['machineId'] as String,
    executionId: j['executionId'] as String,
    state: j['state'] as String,
  );
}

class SavedState {
  static const schemaVersion = 2;
  SavedState({
    List<Machine>? machines,
    List<Account>? accounts,
    List<TicketTask>? tasks,
    List<ClearedExecution>? clearedExecutions,
    this.themeMode = AppThemeMode.system,
  }) : machines = machines ?? [],
       accounts = accounts ?? [],
       tasks = tasks ?? [],
       clearedExecutions = List.unmodifiable(clearedExecutions ?? []);
  final List<Machine> machines;
  final List<Account> accounts;
  final List<TicketTask> tasks;
  final List<ClearedExecution> clearedExecutions;
  late final _clearedExecutionKeys = {
    for (final record in clearedExecutions)
      (record.machineId, record.executionId, record.state),
  };
  bool isExecutionCleared(String machineId, String executionId, String state) =>
      _clearedExecutionKeys.contains((machineId, executionId, state));
  final AppThemeMode themeMode;
  String encode() => jsonEncode({
    'schema': schemaVersion,
    'theme_mode': themeMode.name,
    'machines': machines.map((e) => e.toJson()).toList(),
    'accounts': accounts.map((e) => e.toJson()).toList(),
    'tasks': tasks.map((e) => e.toJson()).toList(),
    'cleared_executions': clearedExecutions.map((e) => e.toJson()).toList(),
  });
  factory SavedState.decode(String data) {
    final j = jsonDecode(data) as Map<String, dynamic>;
    if (j['schema'] != schemaVersion) throw const FormatException('不支持的本地配置版本');
    return SavedState(
      themeMode:
          AppThemeMode.values
              .where((mode) => mode.name == j['theme_mode'])
              .firstOrNull ??
          AppThemeMode.system,
      machines: (j['machines'] as List)
          .map((e) => Machine.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      accounts: (j['accounts'] as List)
          .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      tasks: (j['tasks'] as List)
          .map((e) => TicketTask.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      clearedExecutions: [
        for (final value in j['cleared_executions'] as List? ?? const [])
          ClearedExecution.fromJson(Map<String, dynamic>.from(value as Map)),
      ],
    );
  }
}

String readableError(Object e) {
  if (e is FormatException) return e.message;
  if (e is UserError) return e.message;
  return '操作失败，请检查网络或应用状态后重试。';
}

class UserError implements Exception {
  const UserError(this.message);
  final String message;
  @override
  String toString() => message;
}
