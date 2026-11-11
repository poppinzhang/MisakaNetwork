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
  });
  final String id,
      name,
      host,
      caCert,
      clientCert,
      clientKey,
      serverName,
      fingerprint;
  final int port;
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

class TicketTask {
  TicketTask({
    required this.id,
    required this.name,
    required this.accountId,
    this.startAt = '',
    this.dispatchedTo = const [],
  });
  final String id, name, accountId;

  /// Purchase start as Beijing time `YYYY-MM-DDTHH:MM:SS`; empty starts as
  /// soon as a machine accepts the task.
  final String startAt;

  /// Machines that accepted this task. Sisters keeps accepted task IDs only in
  /// memory, so a task is submitted to each machine at most once.
  final List<String> dispatchedTo;
  TicketTask withDispatched(Iterable<String> machineIds) => TicketTask(
    id: id,
    name: name,
    accountId: accountId,
    startAt: startAt,
    dispatchedTo: {...dispatchedTo, ...machineIds}.toList()..sort(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'accountId': accountId,
    'startAt': startAt,
    'dispatchedTo': dispatchedTo,
  };
  factory TicketTask.fromJson(Map<String, dynamic> j) => TicketTask(
    id: j['id'] as String,
    name: j['name'] as String,
    accountId: j['accountId'] as String,
    startAt: j['startAt'] as String? ?? '',
    dispatchedTo: [
      for (final id in j['dispatchedTo'] as List? ?? const []) id as String,
    ],
  );
}

enum AppThemeMode { system, light, dark }

class SavedState {
  static const schemaVersion = 2;
  SavedState({
    List<Machine>? machines,
    List<Account>? accounts,
    List<TicketTask>? tasks,
    this.themeMode = AppThemeMode.system,
  }) : machines = machines ?? [],
       accounts = accounts ?? [],
       tasks = tasks ?? [];
  final List<Machine> machines;
  final List<Account> accounts;
  final List<TicketTask> tasks;
  final AppThemeMode themeMode;
  String encode() => jsonEncode({
    'schema': schemaVersion,
    'theme_mode': themeMode.name,
    'machines': machines.map((e) => e.toJson()).toList(),
    'accounts': accounts.map((e) => e.toJson()).toList(),
    'tasks': tasks.map((e) => e.toJson()).toList(),
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
    );
  }
}

String readableError(Object e) {
  if (e is FormatException) return e.message;
  if (e is UserError) return e.message;
  return '操作失败，请检查连接、证书、运行时或本地存储后重试。';
}

class UserError implements Exception {
  const UserError(this.message);
  final String message;
  @override
  String toString() => message;
}
