import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'cloud_models.dart';
import 'models.dart';
import 'services.dart';

/// Local UI preview only. This class never sends cloud API requests or invokes
/// SSH deployment. Cloud jobs intentionally do not enter SavedState.machines.
class CloudController extends ChangeNotifier {
  CloudController({
    required this.store,
    required this.helper,
    this.stageDuration = const Duration(seconds: 3),
    this.releaseDuration = const Duration(seconds: 2),
  });
  static const workspaceKey = 'cloud.preview.v1';
  static const sshIdentityKey = 'cloud.ssh-identity.v1';
  final StateStore store;
  final DeploymentHelper helper;
  final Duration stageDuration, releaseDuration;
  bool initialized = false, _disposed = false;
  String? startupError, keyError;
  String sshPublicKey = '', sshFingerprint = '';
  bool get sshReady => sshPublicKey.isNotEmpty && sshFingerprint.isNotEmpty;
  final Map<CloudProvider, _StoredCredential> _credentials = {};
  List<CloudMachine> _jobs = [];
  final Map<String, Timer> _timers = {};
  Future<void> _operation = Future<void>.value();
  Future<void>? _initialization, _keyInitialization;

  Map<CloudProvider, CloudCredential> get credentials => Map.unmodifiable({
    for (final entry in _credentials.entries) entry.key: entry.value.summary,
  });
  List<CloudMachine> get jobs => List.unmodifiable(_jobs);
  CloudCredential? credentialFor(CloudProvider provider) =>
      _credentials[provider]?.summary;

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    if (_initialization != null) return _initialization!;
    startupError = null;
    return _initialization ??= _initialize().whenComplete(() {
      if (!initialized) _initialization = null;
    });
  }

  Future<void> _initialize() async {
    try {
      final stored = await store.readSecret(workspaceKey);
      if (_disposed) return;
      if (stored != null) {
        final value = jsonDecode(stored) as Map<String, dynamic>;
        if (value['version'] != 1) throw const FormatException();
        final credentials = {
          for (final item in value['credentials'] as List)
            CloudProvider.values.byName(
              item['provider'] as String,
            ): _StoredCredential.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
        };
        final jobs = [
          for (final item in value['jobs'] as List)
            CloudMachine.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
        _credentials.clear();
        _credentials.addAll(credentials);
        _jobs = jobs;
      }
      if (_jobs.any((job) => job.active)) {
        final interrupted = [
          for (final job in _jobs)
            job.active
                ? job.copyWith(
                    phase: CloudMachinePhase.interrupted,
                    error: '上次交互预览已中断，没有创建或释放真实云资源。可删除此记录后重新预览。',
                  )
                : job,
        ];
        await _persist(_credentials, interrupted);
        if (_disposed) return;
        _jobs = interrupted;
      }
      initialized = true;
    } catch (_) {
      // Do not overwrite an unreadable secure record on a later edit.
      initialized = false;
      startupError = '公有云信息无法读取或保存，请检查系统安全存储后重新打开应用。';
    }
    _notify();
    if (!_disposed) await ensureSshIdentity();
  }

  Future<void> ensureSshIdentity() {
    if (_disposed) return Future<void>.value();
    return _keyInitialization ??= _ensureKey().whenComplete(
      () => _keyInitialization = null,
    );
  }

  Future<void> _ensureKey() async {
    if (sshReady) return;
    keyError = null;
    _notify();
    try {
      final existing = await store.readSecret(sshIdentityKey);
      if (_disposed) return;
      Map<String, dynamic> identity;
      if (existing != null) {
        identity = Map<String, dynamic>.from(jsonDecode(existing) as Map);
        _validateKey(identity);
      } else {
        identity = await helper.call({'action': 'generate_cloud_ssh_key'});
        if (_disposed) return;
        _validateKey(identity);
        // Keep the complete identity in one atomic system-secret item. Never
        // place private key bytes in normal state, filenames, or error text.
        await store.writeSecret(
          sshIdentityKey,
          jsonEncode({
            'private_key': identity['private_key'],
            'public_key': identity['public_key'],
            'fingerprint': identity['fingerprint'],
          }),
        );
      }
      if (_disposed) return;
      sshPublicKey = identity['public_key'] as String;
      sshFingerprint = identity['fingerprint'] as String;
    } catch (_) {
      keyError = 'SSH 登录密钥尚未就绪，请检查内嵌辅助程序与系统安全存储后重试。';
    }
    _notify();
  }

  void _validateKey(Map<String, dynamic> identity) {
    final private = identity['private_key'];
    final public = identity['public_key'];
    final fingerprint = identity['fingerprint'];
    if (private is! String ||
        !private.startsWith('-----BEGIN ') ||
        public is! String ||
        !public.startsWith('ssh-rsa ') ||
        fingerprint is! String ||
        !fingerprint.startsWith('SHA256:')) {
      throw const FormatException();
    }
  }

  static String? validateCredentialValue(String value, String label) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '请填写 $label。';
    if (normalized.length > 2048) return '$label 最多填写 2048 个字符。';
    if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(normalized)) {
      return '$label 不能包含空白或控制字符。';
    }
    if (normalized.contains('://') ||
        normalized.contains('-----') ||
        normalized.startsWith('ssh-')) {
      return '请填写云 API 的 $label，不是网址或 SSH 密钥。';
    }
    return null;
  }

  Future<void> saveCredential(
    CloudProvider provider, {
    required String alias,
    required String accessKeyId,
    required String accessKeySecret,
  }) => _serialize(() async {
    _requireInitialized();
    if (alias.trim().isEmpty) throw const UserError('请填写凭证名称。');
    if (alias.trim().length > 40) throw const UserError('凭证名称最多填写 40 个字符。');
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(alias)) {
      throw const UserError('凭证名称不能包含控制字符。');
    }
    for (final check in [
      validateCredentialValue(accessKeyId, provider.credentialIdLabel),
      validateCredentialValue(accessKeySecret, provider.credentialSecretLabel),
    ]) {
      if (check != null) throw UserError(check);
    }
    final next = Map<CloudProvider, _StoredCredential>.of(_credentials);
    next[provider] = _StoredCredential(
      provider: provider,
      alias: alias.trim(),
      accessKeyId: accessKeyId.trim(),
      accessKeySecret: accessKeySecret.trim(),
      checkedAt: DateTime.now().toUtc(),
    );
    await _persist(next, _jobs);
    _credentials.clear();
    _credentials.addAll(next);
    _notify();
  });

  Future<void> removeCredential(CloudProvider provider) => _serialize(() async {
    _requireInitialized();
    final next = Map<CloudProvider, _StoredCredential>.of(_credentials)
      ..remove(provider);
    await _persist(next, _jobs);
    _credentials.clear();
    _credentials.addAll(next);
    _notify();
  });

  Future<CloudMachine> startPreviewCreation(
    CloudProvider provider,
    CloudTemplate template, {
    CloudPreviewOutcome outcome = CloudPreviewOutcome.success,
  }) => _serialize(() async {
    _requireInitialized();
    if (credentialFor(provider) == null) {
      throw const UserError('请先保存该云厂商的凭证并完成格式检查。');
    }
    if (!sshReady) throw const UserError('请先在公有云凭证页面完成 SSH 登录密钥准备。');
    final supported = CloudTemplate.forProvider(provider);
    if (!supported.any((candidate) => candidate.id == template.id)) {
      throw const UserError('配置模板不属于当前云厂商，请重新选择。');
    }
    var sequence = 1;
    String name() =>
        '${provider.displayName} · ${template.name} ${sequence.toString().padLeft(2, '0')}';
    while (_jobs.any((job) => job.name == name())) {
      sequence++;
    }
    final job = CloudMachine(
      id: const Uuid().v4(),
      name: name(),
      provider: provider,
      template: template,
      phase: CloudMachinePhase.creating,
    );
    final next = [..._jobs, job];
    await _persist(_credentials, next);
    _jobs = next;
    _notify();
    _schedule(job.id, stageDuration, () async {
      if (outcome == CloudPreviewOutcome.createFailure) {
        await _transition(
          job.id,
          CloudMachinePhase.createFailed,
          error: '创建失败（演示）：当前配置暂时无可用库存。可删除此记录，再选择其他配置。',
        );
      } else {
        await _transition(job.id, CloudMachinePhase.deploying);
        if (_jobs.any(
          (value) =>
              value.id == job.id && value.phase == CloudMachinePhase.deploying,
        )) {
          _schedule(
            job.id,
            stageDuration,
            () => _transition(
              job.id,
              outcome == CloudPreviewOutcome.deployFailure
                  ? CloudMachinePhase.deployFailed
                  : CloudMachinePhase.ready,
              error: outcome == CloudPreviewOutcome.deployFailure
                  ? '部署失败（演示）：SSH 连接超时。可演示释放云服务器或删除此预览记录。'
                  : '',
            ),
          );
        }
      }
    });
    return job;
  });

  Future<void> requestPreviewRelease(String id) => _serialize(() async {
    _requireInitialized();
    final job = _requireJob(id);
    if (job.active ||
        job.phase == CloudMachinePhase.released ||
        job.phase == CloudMachinePhase.createFailed) {
      throw const UserError('当前预览状态不能释放，请等待流程结束或删除失败记录。');
    }
    final next = [
      for (final item in _jobs)
        item.id == id
            ? item.copyWith(phase: CloudMachinePhase.releasing, error: '')
            : item,
    ];
    await _persist(_credentials, next);
    _jobs = next;
    _notify();
    _schedule(
      id,
      releaseDuration,
      () => _transition(id, CloudMachinePhase.released),
    );
  });

  Future<void> removeMachine(String id) => _serialize(() async {
    _requireInitialized();
    _requireJob(id);
    final next = _jobs.where((job) => job.id != id).toList();
    await _persist(_credentials, next);
    _timers.remove(id)?.cancel();
    _jobs = next;
    _notify();
  });

  Future<void> _transition(
    String id,
    CloudMachinePhase phase, {
    String error = '',
  }) => _serialize(() async {
    if (_disposed || !_jobs.any((job) => job.id == id)) return;
    final next = [
      for (final job in _jobs)
        job.id == id ? job.copyWith(phase: phase, error: error) : job,
    ];
    await _persist(_credentials, next);
    _jobs = next;
    _notify();
  });

  void _schedule(String id, Duration duration, Future<void> Function() action) {
    if (_disposed) return;
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(duration, () async {
      _timers.remove(id);
      try {
        await action();
      } catch (_) {
        if (_disposed) return;
        // Memory records show the persistence failure immediately. A restart
        // finds the previous active record and marks it interrupted.
        _jobs = [
          for (final job in _jobs)
            job.id == id
                ? job.copyWith(
                    phase: CloudMachinePhase.interrupted,
                    error: '无法保存预览进度，请检查系统安全存储。没有操作真实云资源。',
                  )
                : job,
        ];
        _notify();
      }
    });
  }

  Future<void> _persist(
    Map<CloudProvider, _StoredCredential> credentials,
    List<CloudMachine> jobs,
  ) async {
    if (_disposed) throw const UserError('公有云页面已关闭，请重新打开。');
    try {
      await store.writeSecret(
        workspaceKey,
        jsonEncode({
          'version': 1,
          'credentials': [
            for (final value in credentials.values) value.toJson(),
          ],
          'jobs': [for (final job in jobs) job.toJson()],
        }),
      );
    } catch (_) {
      throw const UserError('公有云信息无法保存，请检查系统安全存储后重试。');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _operation;
    final done = Completer<void>();
    _operation = done.future;
    await previous;
    try {
      if (_disposed) throw const UserError('公有云页面已关闭，请重新打开。');
      return await action();
    } finally {
      done.complete();
    }
  }

  CloudMachine _requireJob(String id) =>
      _jobs.where((job) => job.id == id).firstOrNull ??
      (throw const UserError('此预览记录已被删除。'));
  void _requireInitialized() {
    if (!initialized) throw const UserError('公有云信息尚未就绪，请重新打开应用。');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}

class _StoredCredential {
  const _StoredCredential({
    required this.provider,
    required this.alias,
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.checkedAt,
  });
  final CloudProvider provider;
  final String alias, accessKeyId, accessKeySecret;
  final DateTime checkedAt;
  CloudCredential get summary => CloudCredential(
    provider: provider,
    alias: alias,
    maskedId: accessKeyId.length > 8
        ? '${accessKeyId.substring(0, 4)}••••${accessKeyId.substring(accessKeyId.length - 4)}'
        : '••••••••',
    checkedAt: checkedAt,
  );
  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'alias': alias,
    'accessKeyId': accessKeyId,
    'accessKeySecret': accessKeySecret,
    'checkedAt': checkedAt.toIso8601String(),
  };
  factory _StoredCredential.fromJson(Map<String, dynamic> value) {
    final provider = CloudProvider.values.byName(value['provider'] as String);
    final id = value['accessKeyId'] as String;
    final secret = value['accessKeySecret'] as String;
    if (CloudController.validateCredentialValue(
              id,
              provider.credentialIdLabel,
            ) !=
            null ||
        CloudController.validateCredentialValue(
              secret,
              provider.credentialSecretLabel,
            ) !=
            null) {
      throw const FormatException();
    }
    return _StoredCredential(
      provider: provider,
      alias: value['alias'] as String,
      accessKeyId: id,
      accessKeySecret: secret,
      checkedAt: DateTime.parse(value['checkedAt'] as String),
    );
  }
}
