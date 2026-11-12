import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../generated/misaka/v1/sisters.pbgrpc.dart';
import 'models.dart';

abstract class StateStore {
  Future<SavedState> load();
  Future<void> save(SavedState state);
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String value);
  Future<void> deleteSecret(String key);
  Future<String> directory();

  /// Deletes imported key and certificate copies whose paths [keep] omits.
  Future<void> pruneCredentials(Set<String> keep);
}

class LocalStore implements StateStore {
  LocalStore({this.protect = restrictPermissions});
  final Future<void> Function(String path, String mode) protect;
  static const stateFilename = 'state-v2.json';
  static const secretNamespace = 'v2.';
  // Preserve credentials on storage errors; do not silently reset Android keys.
  final FlutterSecureStorage secure = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    aOptions: AndroidOptions(resetOnError: false),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );
  @override
  Future<String> directory() async {
    final d = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'MisakaNetwork'),
    );
    await d.create(recursive: true);
    await protect(d.path, '700');
    return d.path;
  }

  @override
  Future<SavedState> load() async {
    final f = File(p.join(await directory(), stateFilename));
    if (!await f.exists()) return SavedState();
    try {
      return SavedState.decode(await f.readAsString());
    } catch (_) {
      throw const UserError('本地配置无法读取。原文件已保留，请修复 state-v2.json 后重新打开。');
    }
  }

  @override
  Future<void> save(SavedState state) async {
    final target = p.join(await directory(), stateFilename);
    await File('$target.tmp').writeAsString(state.encode(), flush: true);
    await protect('$target.tmp', '600');
    await File('$target.tmp').rename(target);
  }

  @override
  Future<String?> readSecret(String key) =>
      secure.read(key: '$secretNamespace$key');
  @override
  Future<void> writeSecret(String key, String value) =>
      secure.write(key: '$secretNamespace$key', value: value);
  @override
  Future<void> deleteSecret(String key) async {
    final storedKey = '$secretNamespace$key';
    // The Darwin plugin also queries synchronizable items during deletion and
    // can report an entitlement error when the login-Keychain item is absent.
    // A successful read of absence makes repeated cleanup safely idempotent;
    // actual read or delete failures still propagate to the caller.
    if (await secure.read(key: storedKey) == null) return;
    await secure.delete(key: storedKey);
  }

  @override
  Future<void> pruneCredentials(Set<String> keep) async {
    final credentials = Directory(p.join(await directory(), 'credentials'));
    if (!await credentials.exists()) return;
    final kept = keep.map(p.canonicalize).toSet();
    await for (final entry in credentials.list(followLinks: false)) {
      if (entry is File && !kept.contains(p.canonicalize(entry.path))) {
        await entry.delete();
      }
    }
  }
}

abstract class AgentGateway {
  Future<AgentStatus> status(Machine machine);
  Future<TaskStatus> submit(Machine machine, TaskRequest task);
  Future<TaskStatus> cancel(Machine machine, String id);
}

class MutualTlsCredentials extends ChannelCredentials {
  MutualTlsCredentials(this.ca, this.cert, this.key, String name)
    : super.secure(authority: name);
  final List<int> ca, cert, key;
  @override
  SecurityContext get securityContext =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(ca)
        ..useCertificateChainBytes(cert)
        ..usePrivateKeyBytes(key)
        ..setAlpnProtocols(['h2'], false);
}

String describeGrpcFailure(GrpcError error) {
  if (error.code == StatusCode.alreadyExists) {
    return '此任务已使用另一份配置或登录凭据提交到该 Sisters，原任务未更新。'
        '请新建任务后分发；若原任务仍在运行，请先查看状态。';
  }
  // Remote error details may contain account data; only expose the status code.
  return 'Sisters 请求失败（${error.codeName}）：连接或任务不可用，请检查机器状态。';
}

/// Opens a mutual-TLS channel to [m] using its CA, certificate and key files.
Future<ClientChannel> openSistersChannel(Machine m) async {
  final certs = await Future.wait([
    File(m.caCert).readAsBytes(),
    File(m.clientCert).readAsBytes(),
    File(m.clientKey).readAsBytes(),
  ]);
  return ClientChannel(
    m.host,
    port: m.port,
    options: ChannelOptions(
      credentials: MutualTlsCredentials(
        certs[0],
        certs[1],
        certs[2],
        m.serverName.isEmpty ? m.host : m.serverName,
      ),
      // Bounds the TCP connect; each call's deadline bounds the rest.
      // (connectionTimeout is how long a connection may be reused.)
      connectTimeout: const Duration(seconds: 8),
    ),
  );
}

class GrpcGateway implements AgentGateway {
  GrpcGateway({this.open = openSistersChannel});
  final Future<ClientChannel> Function(Machine) open;

  /// One channel per connection setting: polling reuses its HTTP/2 connection
  /// instead of a TLS handshake every five seconds, and no channel is shut
  /// down while connecting, which grpc-dart would leak. An unused channel
  /// drops its connection after grpc's idle timeout.
  final _channels = <String, Future<ClientChannel>>{};

  Future<T> _call<T>(Machine m, Future<T> Function(SistersClient c) fn) async {
    final key = jsonEncode([
      m.host,
      m.port,
      m.serverName,
      m.caCert,
      m.clientCert,
      m.clientKey,
    ]);
    final opening = _channels[key] ??= open(m);
    try {
      return await fn(
        SistersClient(
          await opening,
          options: CallOptions(timeout: const Duration(seconds: 12)),
        ),
      );
    } on FileSystemException {
      // Unreadable files are read again on the next call, not cached.
      if (identical(_channels[key], opening)) _channels.remove(key);
      throw const UserError('无法读取 mTLS 证书或私钥，请检查配置。');
    } on GrpcError catch (e) {
      throw UserError(describeGrpcFailure(e));
    } on TlsException {
      throw const UserError('TLS 验证失败，请检查证书、主机名和系统时间。');
    }
  }

  @override
  Future<AgentStatus> status(Machine m) =>
      _call(m, (c) => c.getStatus(Empty()));
  @override
  Future<TaskStatus> submit(Machine m, TaskRequest task) =>
      _call(m, (c) => c.submitTask(task));
  @override
  Future<TaskStatus> cancel(Machine m, String id) =>
      _call(m, (c) => c.cancelTask(TaskId(id: id)));
}

abstract class RuntimeBridge {
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> params);
}

String desktopResourcesDirectory(String executable, String operatingSystem) {
  final paths = p.Context(
    style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
  );
  return paths.normalize(
    operatingSystem == 'windows'
        ? paths.join(paths.dirname(executable), 'resources')
        : paths.join(paths.dirname(executable), '..', 'Resources'),
  );
}

String get resourcesDirectory => desktopResourcesDirectory(
  Platform.resolvedExecutable,
  Platform.operatingSystem,
);
String get _executableSuffix => Platform.isWindows ? '.exe' : '';

/// Android embeds Python and Go as libraries; it cannot execute desktop helpers.
class EmbeddedServices {
  const EmbeddedServices({
    this.channel = const MethodChannel('misaka/embedded'),
  });
  final MethodChannel channel;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    try {
      final response = await channel
          .invokeMethod<String>(method, jsonEncode(request))
          .timeout(timeout);
      if (response == null || utf8.encode(response).length > 8 * 1024 * 1024) {
        throw const UserError('内置服务返回无效响应。');
      }
      final decoded = jsonDecode(response);
      if (decoded is! Map<String, dynamic> ||
          (method == 'runtime' && decoded['type'] != 'result')) {
        throw const UserError('内置服务返回无效响应。');
      }
      return decodeServiceResponse(decoded, bridge: method == 'runtime');
    } on TimeoutException {
      throw const UserError('内置服务请求超时。部署可能仍在执行，请先检查机器状态再重试。');
    } on PlatformException {
      throw const UserError('内置服务执行失败，请检查应用安装与网络连接。');
    } on MissingPluginException {
      throw const UserError('内置服务未安装，请使用完整的 LastOrder 安装包。');
    } on FormatException {
      throw const UserError('内置服务返回无效响应。');
    }
  }

  Future<String> resources() async {
    try {
      final result = await channel
          .invokeMethod<String>('resources')
          .timeout(const Duration(minutes: 5));
      if (result == null || !p.isAbsolute(result)) {
        throw const UserError('内置部署包无法准备，请重新安装完整应用。');
      }
      return result;
    } on PlatformException {
      throw const UserError('内置部署包无法准备，请检查存储空间并重新安装完整应用。');
    } on MissingPluginException {
      throw const UserError('内置部署包未安装，请使用完整的 LastOrder 安装包。');
    } on TimeoutException {
      throw const UserError('内置部署包准备超时，请稍后重试。');
    }
  }
}

Map<String, dynamic> decodeServiceResponse(
  Map<String, dynamic> response, {
  bool bridge = false,
  int exitCode = 0,
}) {
  if (response['ok'] == true) {
    if (exitCode != 0) throw UserError('运行时异常退出（退出码 $exitCode），操作未确认成功。');
    final value =
        response[bridge ? 'data' : 'result'] ??
        (bridge ? null : <String, dynamic>{});
    if (value is! Map<String, dynamic>) {
      throw const UserError('内置服务返回无效响应。');
    }
    return value;
  }
  if (!bridge &&
      response['fingerprint'] is String &&
      (response['fingerprint'] as String).startsWith('SHA256:')) {
    return {'fingerprint': response['fingerprint'], 'needs_confirmation': true};
  }
  final error = response['error'];
  throw UserError(
    error is Map
        ? (error['message'] ?? '运行时请求失败').toString()
        : (error ?? '运行时请求失败').toString(),
  );
}

Future<String> deploymentBundlesDirectory() async => p.join(
  Platform.isAndroid
      ? await const EmbeddedServices().resources()
      : resourcesDirectory,
  'bundles',
);

class _ChildProcess {
  _ChildProcess(this.process) {
    exitCode = process.exitCode.then((code) {
      exited = true;
      return code;
    });
  }

  final Process process;
  late final Future<int> exitCode;
  bool exited = false;
  final cancelled = Completer<void>();
  Future<void>? _termination;

  Future<void> stop() {
    if (!cancelled.isCompleted) {
      cancelled.completeError(const UserError('运行时请求已取消。'));
    }
    return terminate();
  }

  Future<void> terminate() => _termination ??= _terminate();

  Future<void> _terminate() async {
    // Never use a completed process's PID: Windows may already have reused it.
    if (exited) return;
    if (Platform.isWindows) {
      Process? killer;
      var killerExited = false;
      StreamSubscription<List<int>>? killerOutput;
      StreamSubscription<List<int>>? killerErrors;
      try {
        final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        killer = await Process.start(
          p.windows.join(windows, 'System32', 'taskkill.exe'),
          ['/PID', '${process.pid}', '/T', '/F'],
        );
        killerOutput = killer.stdout.listen((_) {}, onError: (Object _) {});
        killerErrors = killer.stderr.listen((_) {}, onError: (Object _) {});
        await killer.exitCode
            .then((_) {
              killerExited = true;
            })
            .timeout(const Duration(seconds: 3));
      } on ProcessException {
        // The runner's kill-on-close job remains a final safety net.
      } on TimeoutException {
        // Fall back to the Dart process handle below.
      } finally {
        if (!killerExited) killer?.kill(ProcessSignal.sigkill);
        if (killer != null) {
          unawaited(killer.stdin.close().catchError((Object _) {}));
        }
        await killerOutput?.cancel();
        await killerErrors?.cancel();
      }
    }
    if (!exited) process.kill(ProcessSignal.sigkill);
    try {
      await exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Cleanup must remain bounded even if the operating system refuses kill.
    }
  }
}

final _childProcesses = <_ChildProcess>{};
int get activeChildProcessCount => _childProcesses.length;
Future<void> terminateAllChildProcesses() =>
    Future.wait(_childProcesses.toList().map((child) => child.stop()));

Future<Map<String, dynamic>> runJsonProcess(
  String executable,
  List<String> args,
  Map<String, dynamic> request, {
  bool bridge = false,
  Duration timeout = const Duration(seconds: 90),
}) async {
  Process process;
  try {
    process = await Process.start(executable, args);
  } on ProcessException {
    throw const UserError('内置运行时无法启动，请使用完整的 LastOrder 安装包。');
  }
  final child = _ChildProcess(process);
  _childProcesses.add(child);
  final errors = Completer<void>();
  final errorSubscription = process.stderr.listen(
    (_) {},
    onError: (Object _) {
      if (!errors.isCompleted) errors.complete();
    },
    onDone: () {
      if (!errors.isCompleted) errors.complete();
    },
    cancelOnError: true,
  );
  var received = 0;
  final lines = <String>[];
  final output = Completer<List<String>>();
  final outputSubscription = process.stdout
      .transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            received += chunk.length;
            if (received > 8 * 1024 * 1024) {
              sink.addError(const UserError('运行时响应超过大小限制。'));
            } else {
              sink.add(chunk);
            }
          },
        ),
      )
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        lines.add,
        onError: (Object error, StackTrace stack) {
          if (!output.isCompleted) output.completeError(error, stack);
        },
        onDone: () {
          if (!output.isCompleted) output.complete(lines);
        },
        cancelOnError: true,
      );
  Future<(List<String>, int)> completion() async {
    final lines = await output.future;
    final code = await child.exitCode;
    await errors.future;
    return (lines, code);
  }

  final done = completion();
  Future<void> sendRequest() async {
    process.stdin.writeln(jsonEncode(request));
    await process.stdin.close();
  }

  try {
    // Attach both futures immediately: a blocked stdin is covered by the same
    // deadline, and an early stdout failure cannot become an unhandled error.
    final results = await Future.any<dynamic>([
      Future.wait<dynamic>([sendRequest(), done], eagerError: true),
      child.cancelled.future,
    ]).timeout(timeout);
    final (lines, code) = results[1] as (List<String>, int);
    for (final line in lines.reversed) {
      Map<String, dynamic> j;
      try {
        j = Map<String, dynamic>.from(jsonDecode(line) as Map);
      } catch (_) {
        continue;
      }
      if (bridge && j['type'] != 'result') continue;
      return decodeServiceResponse(j, bridge: bridge, exitCode: code);
    }
    throw UserError('运行时返回无效响应（退出码 $code）。');
  } on TimeoutException {
    throw const UserError('运行时请求超时，请稍后重试。');
  } on FormatException {
    throw const UserError('运行时返回无效响应。');
  } on IOException {
    throw const UserError('运行时通信中断，请重试。');
  } finally {
    await child.terminate();
    await Future.wait([
      outputSubscription.cancel(),
      errorSubscription.cancel(),
    ]);
    // Descendants can keep pipe handles open after their parent exits. Release
    // both subscriptions and settle their futures even in that case.
    if (!output.isCompleted) output.complete(<String>[]);
    if (!errors.isCompleted) errors.complete();
    _childProcesses.remove(child);
  }
}

class LocalRuntime implements RuntimeBridge {
  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> params) =>
      Platform.isAndroid
      ? const EmbeddedServices().call('runtime', {'op': op, 'params': params})
      : runJsonProcess(
          p.join(
            resourcesDirectory,
            'runtime',
            'misaka-runtime$_executableSuffix',
          ),
          [],
          {'op': op, 'params': params},
          bridge: true,
        );
}

class DeploymentProgress {
  const DeploymentProgress({required this.percent, required this.stage});
  final int percent;
  final String stage;

  /// Only known stages cross the helper boundary. Never display arbitrary
  /// helper output, request fields or remote stdout as progress text.
  static DeploymentProgress? decode(Object? value) {
    if (value is! Map || value['percent'] is! int) return null;
    final percent = value['percent'] as int;
    final stage = value['stage'];
    const ranges = <String, (int, int)>{
      '准备部署': (2, 2),
      '连接 SSH': (5, 5),
      '检查系统与安装包': (10, 10),
      '准备安全配置': (15, 15),
      '上传并解压安装包': (20, 75),
      '写入安全配置': (78, 78),
      '检查 Sisters': (82, 82),
      '检查抢票运行时': (86, 86),
      '启动 Sisters': (90, 90),
      '验证安全连接': (94, 94),
      '检查直连状态': (97, 97),
      '部署完成': (100, 100),
    };
    final range = ranges[stage];
    if (stage is! String ||
        range == null ||
        percent < range.$1 ||
        percent > range.$2) {
      return null;
    }
    return DeploymentProgress(percent: percent, stage: stage);
  }
}

abstract class DeploymentHelper {
  Future<Map<String, dynamic>> call(
    Map<String, dynamic> request, {
    void Function(DeploymentProgress)? onProgress,
  });
}

/// Deploy bounds its own stages (stall detection, a staging budget, health
/// check and rollback); this only catches a helper hung beyond them.
Duration helperTimeout(Map<String, dynamic> request) =>
    request['action'] == 'deploy'
    ? const Duration(minutes: 30)
    : const Duration(seconds: 300);

class LocalHelper implements DeploymentHelper {
  @override
  Future<Map<String, dynamic>> call(
    Map<String, dynamic> request, {
    void Function(DeploymentProgress)? onProgress,
  }) => request['action'] == 'deploy' && onProgress != null
      ? trackDeploymentProgress(request, onProgress, _invoke)
      : _invoke(request);

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> request) =>
      Platform.isAndroid
      ? const EmbeddedServices().call(
          'helper',
          request,
          timeout: helperTimeout(request),
        )
      : runJsonProcess(
          p.join(resourcesDirectory, 'misakactl$_executableSuffix'),
          [],
          request,
          timeout: helperTimeout(request),
        );
}

/// Each deployment owns a private directory, including on Android where the
/// helper runs inside JNI. The progress file holds only bounded public stages.
Future<Map<String, dynamic>> trackDeploymentProgress(
  Map<String, dynamic> request,
  void Function(DeploymentProgress) onProgress,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) invoke, {
  Future<void> Function(String, String) protect = restrictPermissions,
}) async {
  final parent = Platform.isAndroid
      ? await getTemporaryDirectory()
      : Directory.systemTemp;
  final directory = await parent.createTemp('misaka-deployment-');
  final file = File(p.join(directory.path, 'progress.json'));
  Timer? timer;
  Future<void>? reading;
  var closed = false;
  var lastPercent = -1;
  var lastStage = '';

  Future<void> read() async {
    try {
      if (!await file.exists() || await file.length() > 1024) return;
      final progress = DeploymentProgress.decode(
        jsonDecode(await file.readAsString()),
      );
      if (closed ||
          progress == null ||
          progress.percent < lastPercent ||
          (progress.percent == lastPercent && progress.stage == lastStage)) {
        return;
      }
      // 100% is released only after a successful terminal response. A helper
      // which crashes after its last snapshot must not briefly appear complete.
      if (progress.percent == 100) return;
      lastPercent = progress.percent;
      lastStage = progress.stage;
      onProgress(progress);
    } on FileSystemException {
      // Atomic replacement can briefly be unavailable on Windows. Retry later.
    } on FormatException {
      // Tolerate missing/partial snapshots from an interrupted helper.
    }
  }

  void poll() {
    if (reading != null || closed) return;
    reading = read().whenComplete(() => reading = null);
  }

  try {
    await protect(directory.path, '700');
    timer = Timer.periodic(const Duration(milliseconds: 200), (_) => poll());
    final result = await invoke({...request, 'progress_path': file.path});
    timer.cancel();
    await reading;
    await read();
    if (result['needs_confirmation'] != true) {
      onProgress(const DeploymentProgress(percent: 100, stage: '部署完成'));
    }
    return result;
  } finally {
    closed = true;
    timer?.cancel();
    await reading;
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A native request may outlive a timeout. It can finish cleanup safely;
      // any leftover file contains only the public progress snapshot.
    }
  }
}

/// The native picker grants sandbox access; keep a private copy for reconnects.
Future<String?> importProtectedFile(StateStore store) async {
  final selected = await openFile();
  if (selected == null) return null;
  final directory = Directory(p.join(await store.directory(), 'credentials'));
  await directory.create(recursive: true);
  await restrictPermissions(directory.path, '700');
  final destination = p.join(directory.path, const Uuid().v4());
  try {
    await File(destination)
        .writeAsBytes(await selected.readAsBytes(), flush: true);
    await restrictPermissions(destination, '600');
    return destination;
  } catch (_) {
    final file = File(destination);
    if (await file.exists()) await file.delete();
    throw const UserError('无法读取或安全保存所选文件，请重新选择。');
  } finally {
    // The Android picker hands over a plaintext copy in the app cache and never
    // deletes it. Desktop pickers return the user's own file, which must stay.
    if (Platform.isAndroid) {
      try {
        await discardPickerCopy(
          selected.path,
          (await getTemporaryDirectory()).path,
        );
      } on Exception {
        // Best effort: the copy stays app-private and the system may clear it.
      }
    }
  }
}

/// Deletes the picker copy at [path] and its emptied folder, but only inside
/// [cacheDirectory]; any other path is the user's own file.
Future<void> discardPickerCopy(String path, String cacheDirectory) async {
  if (!p.isWithin(cacheDirectory, path)) return;
  final file = File(path);
  if (await file.exists()) await file.delete();
  final folder = file.parent;
  if (p.isWithin(cacheDirectory, folder.path) && await folder.list().isEmpty) {
    await folder.delete();
  }
}

Future<void> restrictPermissions(String path, String mode) async {
  if (Platform.isWindows) {
    await LocalHelper().call({'action': 'protect_path', 'directory': path});
  } else if (Platform.isAndroid) {
    try {
      await const MethodChannel('misaka/embedded')
          .invokeMethod<void>('protectFile', {'path': path, 'mode': mode});
    } on PlatformException {
      throw const UserError('无法设置本地文件访问权限。');
    }
  } else if (Platform.isMacOS || Platform.isLinux) {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) throw const UserError('无法设置本地文件访问权限。');
  }
}
