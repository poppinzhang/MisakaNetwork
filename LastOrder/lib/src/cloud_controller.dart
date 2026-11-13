import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'cloud_models.dart';
import 'cloud_templates.dart';
import 'models.dart';
import 'services.dart';

/// Tencent resource operations use the embedded helper. Other providers remain
/// local previews. Cloud resources and linked Sisters deployments have separate
/// lifecycles; deployment leases prevent releasing a node mid-installation.
class CloudController extends ChangeNotifier {
  CloudController({
    required this.store,
    required this.helper,
    this.templateLoader,
    this.cloudPollInterval = const Duration(seconds: 5),
    this.credentialVerificationTimeout = const Duration(seconds: 35),
    this.preparationPollInterval = const Duration(seconds: 2),
    this.preparationPollAttempts = 30,
    this.stageDuration = const Duration(seconds: 3),
    this.releaseDuration = const Duration(seconds: 2),
  });
  static const workspaceKey = 'cloud.preview.v1';
  static const sshIdentityKey = 'cloud.ssh-identity.v1';
  final Future<List<CloudTemplate>> Function()? templateLoader;
  final Duration cloudPollInterval;
  final Duration credentialVerificationTimeout;
  final Duration preparationPollInterval;
  final int preparationPollAttempts;
  final _deploymentLocks = <String>{};
  bool isDeployingTencent(String id) => _deploymentLocks.contains(id);
  List<CloudTemplate> _tencentTemplates = [];
  String? templateError;
  final Set<String> _realBusy = {};
  final Map<String, int> _pollAttempts = {};
  Future<void> _preparation = Future<void>.value();
  final StateStore store;
  final DeploymentHelper helper;
  final Duration stageDuration, releaseDuration;
  bool initialized = false, _disposed = false;
  String? startupError, keyError;
  String sshPublicKey = '', sshFingerprint = '';
  bool get sshReady => sshPublicKey.isNotEmpty && sshFingerprint.isNotEmpty;
  final Map<CloudProvider, _StoredCredential> _credentials = {};
  List<CloudMachine> _jobs = [];
  List<_CloudNetworkRecord> _networks = [];
  final Map<String, Timer> _timers = {};
  Future<void> _operation = Future<void>.value();
  Future<void>? _initialization, _keyInitialization;

  Map<CloudProvider, CloudCredential> get credentials => Map.unmodifiable({
    for (final entry in _credentials.entries) entry.key: entry.value.summary,
  });
  List<CloudMachine> get jobs => List.unmodifiable(_jobs);
  List<CloudMachine> get visibleJobs =>
      List.unmodifiable(_jobs.where((job) => !job.releaseConfirmed));
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
    await _loadTemplates();
    try {
      final stored = await store.readSecret(workspaceKey);
      if (_disposed) return;
      if (stored != null) {
        final value = jsonDecode(stored) as Map<String, dynamic>;
        if (value['version'] != 1) throw const FormatException();
        final credentials = <CloudProvider, _StoredCredential>{};
        for (final item in value['credentials'] as List) {
          final credential = _StoredCredential.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          // Never silently choose one of multiple identities for a provider.
          if (credentials.containsKey(credential.provider)) {
            throw const FormatException();
          }
          credentials[credential.provider] = credential;
        }
        final jobs = [
          for (final item in value['jobs'] as List)
            CloudMachine.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
        for (final job in jobs.where((job) => job.isReal)) {
          final zonePattern = RegExp(
            '^${RegExp.escape(job.region)}-[1-9][0-9]*\$',
          );
          if (job.region != job.template.tencent?['region'] ||
              !zonePattern.hasMatch(job.effectiveZone) ||
              job.unavailableZones.length > 101 ||
              job.unavailableZones.toSet().length !=
                  job.unavailableZones.length ||
              job.unavailableZones.any((zone) => !zonePattern.hasMatch(zone))) {
            throw const FormatException();
          }
        }
        final networks = [
          for (final item in value['networks'] as List? ?? const [])
            _CloudNetworkRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
        ];
        if (networks.map((item) => item.identity).toSet().length !=
            networks.length) {
          throw const FormatException();
        }
        _credentials.clear();
        _credentials.addAll(credentials);
        _jobs = jobs;
        _networks = networks;
      }
      if (_jobs.any((job) => job.active)) {
        final interrupted = [
          for (final job in _jobs)
            job.active
                ? job.copyWith(
                    phase: job.isReal
                        ? (job.phase == CloudMachinePhase.releasing
                              ? CloudMachinePhase.releaseFailed
                              : job.createSubmitted
                              ? CloudMachinePhase.unknown
                              : CloudMachinePhase.createFailed)
                        : CloudMachinePhase.interrupted,
                    error: job.isReal
                        ? '上次云操作已中断，请刷新查询。关闭应用不释放资源，可能继续计费。'
                        : '上次交互预览已中断，没有创建或释放真实云资源。可删除此记录后重新预览。',
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
    if (initialized && !_disposed) {
      for (final job in _jobs.where((job) => job.isReal && !job.canRemove)) {
        _scheduleRealPoll(job.id);
      }
    }
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
        if (_jobs.any(
          (job) => job.isReal && job.createSubmitted && !job.releaseConfirmed,
        )) {
          throw const UserError('云服务器登录密钥丢失，请恢复原密钥；不会自动生成替代密钥。');
        }
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

  Future<String> tencentDeploymentPrivateKey() async {
    try {
      final stored = await store.readSecret(sshIdentityKey);
      if (_disposed || stored == null) throw const FormatException();
      final identity = Map<String, dynamic>.from(jsonDecode(stored) as Map);
      _validateKey(identity);
      if (identity['public_key'] != sshPublicKey ||
          identity['fingerprint'] != sshFingerprint) {
        throw const FormatException();
      }
      return identity['private_key'] as String;
    } catch (_) {
      throw const UserError('无法读取创建云服务器时的 SSH 密钥，请检查安全存储；不会自动更换密钥。');
    }
  }

  Future<CloudMachine> beginTencentDeployment(String id) async {
    _requireInitialized();
    final job = _requireJob(id);
    if (_disposed ||
        !job.isReal ||
        job.provider != CloudProvider.tencent ||
        job.phase != CloudMachinePhase.created ||
        job.instanceId.isEmpty ||
        _deploymentLocks.contains(id) ||
        !_realBusy.add(id)) {
      throw const UserError('当前云服务器不能部署，请等待操作完成或查询云端状态。');
    }
    _deploymentLocks.add(id);
    _notify();
    try {
      late Map<String, dynamic> result;
      try {
        result = await helper.call({
          'action': 'tencent_describe',
          'cloud': _cloudRequest(job),
        });
      } catch (_) {
        throw const UserError('无法核实云服务器状态，尚未开始部署，请检查网络和凭证后重试。');
      }
      final ip = result['public_ip'];
      if (_disposed ||
          result['exists'] != true ||
          result['instance_id'] != job.instanceId ||
          result['state'] != 'RUNNING' ||
          ip is! String ||
          InternetAddress.tryParse(ip) == null) {
        throw const UserError('云服务器尚未运行或公网地址未就绪，请先查询云端状态；未开始 SSH 部署。');
      }
      final current = job.copyWith(publicIp: ip, error: '');
      await _saveReal(current);
      if (_disposed) throw const UserError('应用已关闭，部署已中断。');
      return current;
    } catch (error) {
      endTencentDeployment(id);
      if (error is UserError) rethrow;
      throw const UserError('无法核实云服务器状态，尚未开始部署，请检查网络和凭证后重试。');
    } finally {
      _realBusy.remove(id);
    }
  }

  void endTencentDeployment(String id) {
    _deploymentLocks.remove(id);
    _notify();
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
    required String accessKeyId,
    required String accessKeySecret,
  }) => _serialize(() async {
    _requireInitialized();
    if (_credentials[provider]?.onlineVerified == true) {
      throw const UserError('该云厂商已保存凭证，请先移除原凭证后再提交。');
    }
    for (final check in [
      validateCredentialValue(accessKeyId, provider.credentialIdLabel),
      validateCredentialValue(accessKeySecret, provider.credentialSecretLabel),
    ]) {
      if (check != null) throw UserError(check);
    }
    if (_hasResources(provider) &&
        _credentials[provider]?.accessKeyId != accessKeyId.trim()) {
      throw const UserError('请先释放或核实该账号创建的云资源，再更换 SecretId。');
    }
    try {
      final result = await helper
          .call({
            'action': 'verify_cloud_credential',
            'cloud_credential': {
              'provider': provider.name,
              'access_key_id': accessKeyId.trim(),
              'access_key_secret': accessKeySecret.trim(),
            },
          })
          .timeout(credentialVerificationTimeout);
      if (result['verified'] != true || result['provider'] != provider.name) {
        throw const FormatException();
      }
    } catch (_) {
      // Helper and transport failures may contain credentials. Only this fixed
      // message reaches the UI; no submitted secret is persisted on failure.
      throw UserError(
        '${provider.displayName}凭证联网验证未通过，未保存新凭证。请检查密钥、查询权限和网络后重试。',
      );
    }
    if (_disposed) throw const UserError('公有云页面已关闭，请重新打开。');
    final next = Map<CloudProvider, _StoredCredential>.of(_credentials);
    next[provider] = _StoredCredential(
      provider: provider,
      accessKeyId: accessKeyId.trim(),
      accessKeySecret: accessKeySecret.trim(),
      checkedAt: DateTime.now().toUtc(),
      onlineVerified: true,
    );
    await _persist(next, _jobs);
    _credentials.clear();
    _credentials.addAll(next);
    _notify();
  });

  Future<void> removeCredential(CloudProvider provider) => _serialize(() async {
    _requireInitialized();
    if (_hasResources(provider)) {
      throw const UserError('仍有未释放或待核实的云资源，不能移除管理凭证。');
    }
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
    if (provider == CloudProvider.tencent) {
      throw const UserError('腾讯云请使用真实创建入口，不能创建演示节点。');
    }
    if (credentialFor(provider)?.onlineVerified != true) {
      throw const UserError('请先提交该云厂商的凭证并通过联网验证。');
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
    if (job.isReal) throw const UserError('请使用云资源释放入口。');
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
    if (!_requireJob(id).canRemove) {
      throw const UserError('请先确认云资源已释放，不能仅删除本地记录。');
    }
    final next = _jobs.where((job) => job.id != id).toList();
    await _persist(_credentials, next);
    _timers.remove(id)?.cancel();
    _jobs = next;
    _notify();
  });

  List<CloudTemplate> templatesFor(CloudProvider provider) =>
      provider == CloudProvider.tencent
      ? List.unmodifiable(_tencentTemplates)
      : CloudTemplate.forProvider(provider);

  Future<void> _loadTemplates() async {
    try {
      final loaded = templateLoader != null
          ? await templateLoader!()
          : (await TencentTemplateCatalog.load())
                .map(CloudTemplate.tencent)
                .toList();
      _tencentTemplates = [
        for (final item in loaded)
          CloudTemplate.tencent(
            TencentTemplateCatalog.validateTemplate(item.tencent!),
          ),
      ];
    } catch (_) {
      _tencentTemplates = [];
      templateError = '腾讯云配置模板无法读取或格式无效，请联系管理员重新打包。';
    }
  }

  bool _hasResources(CloudProvider provider) =>
      _jobs.any(
        (job) => job.provider == provider && job.isReal && !job.canRemove,
      ) ||
      (provider == CloudProvider.tencent &&
          _networks.any(
            (network) =>
                network.credentialId == _credentials[provider]?.accessKeyId &&
                network.pending,
          ));

  Future<CloudMachine> startTencentCreation(CloudTemplate template) =>
      _serialize(() async {
        _requireInitialized();
        final credential = _credentials[CloudProvider.tencent];
        if (credential == null || !credential.onlineVerified) {
          throw const UserError('请先提交腾讯云凭证并通过联网验证。');
        }
        if (!sshReady) throw const UserError('请先完成 SSH 登录密钥准备。');
        final canonical = _tencentTemplates
            .where((item) => item.id == template.id)
            .firstOrNull;
        if (canonical == null ||
            jsonEncode(canonical.toJson()) != jsonEncode(template.toJson())) {
          throw const UserError('模板不属于当前应用，请重新选择。');
        }
        final token = const Uuid().v4();
        final job = CloudMachine(
          id: token,
          name: 'MisakaNetwork-$token',
          provider: CloudProvider.tencent,
          template: CloudTemplate.tencent(
            TencentTemplateCatalog.validateTemplate(canonical.tencent!),
          ),
          phase: CloudMachinePhase.creating,
          isReal: true,
          region: canonical.tencent!['region'] as String,
          credentialId: credential.accessKeyId,
          clientToken: token,
          selectedZone:
              canonical.tencent!['runInstances']['Placement']['Zone'] as String,
        );
        final next = [..._jobs, job];
        await _persist(_credentials, next);
        _jobs = next;
        _notify();
        unawaited(_createTencent(job.id));
        return job;
      });

  Map<String, dynamic> _cloudRequest(CloudMachine job) {
    final credential = _credentials[job.provider];
    if (credential == null || credential.accessKeyId != job.credentialId) {
      throw const UserError('请恢复创建此实例时使用的腾讯云凭证。');
    }
    return {
      'secret_id': credential.accessKeyId,
      'secret_key': credential.accessKeySecret,
      'region': job.region,
      'client_token': job.clientToken,
      if (job.instanceId.isNotEmpty) 'instance_id': job.instanceId,
    };
  }

  Map<String, dynamic> _executionTemplate(CloudMachine job) {
    final template = TencentTemplateCatalog.validateTemplate(
      job.template.tencent!,
    );
    template['runInstances']['Placement']['Zone'] = job.effectiveZone;
    return TencentTemplateCatalog.validateTemplate(template);
  }

  Future<List<String>> _alternativeTencentZones(CloudMachine job) async {
    final result = await helper.call({
      'action': 'tencent_zones',
      'cloud': {..._cloudRequest(job), 'template': job.template.tencent},
    });
    final zones = result['zones'];
    final pattern = RegExp('^${RegExp.escape(job.region)}-[1-9][0-9]*\$');
    if (zones is! List ||
        zones.length > 100 ||
        zones.any((zone) => zone is! String || !pattern.hasMatch(zone))) {
      throw const FormatException();
    }
    return zones.cast<String>().toSet().toList()..sort();
  }

  // Serializing preparation within this app avoids competing helpers creating
  // the same reusable networks, security group and public key simultaneously.
  Future<Map<String, dynamic>> _prepareTencent(CloudMachine job) async {
    final previous = _preparation;
    final done = Completer<void>();
    _preparation = done.future;
    await previous;
    try {
      if (_disposed) throw const UserError('应用已关闭。');
      final vpc = await _ensureTencentNetwork(job, 'vpc');
      final subnet = await _ensureTencentNetwork(
        job,
        'subnet',
        vpcId: vpc.vpcId,
      );
      final prepared = await helper.call({
        'action': 'tencent_prepare',
        'cloud': {
          ..._cloudRequest(job),
          'template': _executionTemplate(job),
          'public_key': sshPublicKey,
        },
      });
      return {...prepared, 'vpc_id': vpc.vpcId, 'subnet_id': subnet.subnetId};
    } finally {
      done.complete();
    }
  }

  Future<void> retryTencentPreparation(String id) => _serialize(() async {
    _requireInitialized();
    final job = _requireJob(id);
    if (!job.isReal ||
        job.phase != CloudMachinePhase.createFailed ||
        job.createSubmitted ||
        job.instanceId.isNotEmpty ||
        _realBusy.contains(id)) {
      throw const UserError('当前记录不能重试准备，请先查询云端状态。');
    }
    _cloudRequest(job);
    if (!sshReady) throw const UserError('请先完成 SSH 登录密钥准备。');
    final next = [
      for (final item in _jobs)
        item.id == id
            ? item.copyWith(phase: CloudMachinePhase.creating, error: '')
            : item,
    ];
    await _persist(_credentials, next);
    _jobs = next;
    _notify();
    unawaited(_createTencent(id));
  });

  Future<_CloudNetworkRecord> _ensureTencentNetwork(
    CloudMachine job,
    String kind, {
    String vpcId = '',
  }) async {
    final zone = kind == 'subnet' ? job.effectiveZone : '';
    var record =
        _networks.where((item) => item.matches(job, kind, zone)).firstOrNull ??
        _CloudNetworkRecord(
          credentialId: job.credentialId,
          region: job.region,
          kind: kind,
          zone: zone,
          vpcId: vpcId,
        );
    if (kind == 'subnet' && record.vpcId != vpcId) {
      await _saveNetwork(record.copyWith(pending: true));
      throw const _CloudNetworkError();
    }
    Map<String, dynamic> request() => {
      ..._cloudRequest(job),
      'template': _executionTemplate(job),
      'network_kind': kind,
      if (record.vpcId.isNotEmpty) 'vpc_id': record.vpcId,
      if (kind == 'subnet' && record.subnetId.isNotEmpty)
        'subnet_id': record.subnetId,
      if (kind == 'subnet' && record.subnetCidr.isNotEmpty)
        'subnet_cidr': record.subnetCidr,
    };
    late Map<String, dynamic> lookup;
    try {
      lookup = await helper.call({
        'action': 'tencent_network_lookup',
        'cloud': request(),
      });
      if (lookup['found'] is! bool) throw const FormatException();
      if (lookup['found'] == true) record.resolve(lookup);
    } catch (_) {
      if (!_disposed && (record.pending || record.resourceId.isNotEmpty)) {
        record = record.copyWith(pending: true);
        await _saveNetwork(record);
        return _waitTencentNetwork(record, request);
      }
      rethrow;
    }
    if (_disposed) throw const _CloudNetworkError();
    if (lookup['found'] == true) {
      final resolved = record.resolve(lookup);
      if ((record.vpcId.isNotEmpty && record.vpcId != resolved.vpcId) ||
          (record.subnetId.isNotEmpty &&
              record.subnetId != resolved.subnetId) ||
          (record.subnetCidr.isNotEmpty &&
              record.subnetCidr != resolved.subnetCidr)) {
        await _saveNetwork(record.copyWith(pending: true));
        throw const _CloudNetworkError();
      }
      await _saveNetwork(resolved);
      return resolved;
    }
    if (record.pending || record.resourceId.isNotEmpty) {
      record = record.copyWith(pending: true);
      await _saveNetwork(record);
      return _waitTencentNetwork(record, request);
    }
    if (kind == 'subnet') {
      final cidr = lookup['subnet_cidr'];
      if (!_CloudNetworkRecord.validSubnetCidr(cidr)) {
        throw const FormatException();
      }
      record = record.copyWith(subnetCidr: cidr as String);
    }
    // This ledger survives failed/removed jobs and application restarts. A
    // submitted creation is never sent again merely because lookup is empty.
    record = record.copyWith(pending: true);
    await _saveNetwork(record);
    if (_disposed) throw const _CloudNetworkError();
    Map<String, dynamic> result;
    try {
      result = await helper.call({
        'action': 'tencent_network_create',
        'cloud': {
          ...request(),
          if (kind == 'subnet') 'subnet_cidr': record.subnetCidr,
        },
      });
    } catch (_) {
      // The write intent is already durable. Recover with Describe only,
      // including when the create response itself was lost.
      return _waitTencentNetwork(record, request);
    }
    if (_disposed) throw const _CloudNetworkError();
    if (result['state'] == 'rejected') {
      await _saveNetwork(record.copyWith(pending: false, subnetCidr: ''));
      throw const _CloudNetworkError(rejected: true);
    }
    if (result['state'] == 'unknown') {
      final knownId = result[kind == 'vpc' ? 'vpc_id' : 'subnet_id'];
      if (knownId is String && knownId.isNotEmpty) {
        final known = record.resolve(result);
        if (kind == 'subnet' &&
            (known.vpcId != vpcId || known.subnetCidr != record.subnetCidr)) {
          throw const _CloudNetworkError();
        }
        record = known.copyWith(pending: true);
        await _saveNetwork(record);
      }
      return _waitTencentNetwork(record, request);
    }
    if (result['state'] != 'ready') throw const _CloudNetworkError();
    final resolved = record.resolve(result);
    if (kind == 'subnet' &&
        (resolved.vpcId != vpcId || resolved.subnetCidr != record.subnetCidr)) {
      throw const _CloudNetworkError();
    }
    await _saveNetwork(resolved);
    return resolved;
  }

  Future<_CloudNetworkRecord> _waitTencentNetwork(
    _CloudNetworkRecord record,
    Map<String, dynamic> Function() request,
  ) async {
    for (var attempt = 1; attempt < preparationPollAttempts; attempt++) {
      if (_disposed) throw const _CloudNetworkError();
      await Future<void>.delayed(preparationPollInterval);
      if (_disposed) throw const _CloudNetworkError();
      late Map<String, dynamic> result;
      try {
        result = await helper.call({
          'action': 'tencent_network_lookup',
          'cloud': request(),
        });
      } catch (_) {
        // Newly created resources may be visible before their tags or usable
        // subnet address count are visible. Retry reads within the same bound;
        // no error can authorize another mutation or bypass verification.
        continue;
      }
      if (_disposed) throw const _CloudNetworkError();
      if (result['found'] == false) continue;
      if (result['found'] != true) throw const _CloudNetworkError();
      final resolved = record.resolve(result);
      if ((record.vpcId.isNotEmpty && record.vpcId != resolved.vpcId) ||
          (record.subnetId.isNotEmpty &&
              record.subnetId != resolved.subnetId) ||
          (record.subnetCidr.isNotEmpty &&
              record.subnetCidr != resolved.subnetCidr)) {
        throw const _CloudNetworkError();
      }
      await _saveNetwork(resolved);
      return resolved;
    }
    throw const _CloudNetworkError();
  }

  Future<void> _saveNetwork(_CloudNetworkRecord record) => _serialize(() async {
    final next = [
      for (final item in _networks)
        if (item.identity != record.identity) item,
      record,
    ];
    try {
      await _persist(_credentials, _jobs, networks: next);
    } catch (_) {
      // Preserve a returned ID in memory while retaining uncertainty. The
      // durable prior pending marker still prevents another mutation after a
      // restart even if this confirmation could not be saved.
      if (record.resourceId.isNotEmpty) {
        _networks = [
          for (final item in next)
            item.identity == record.identity
                ? item.copyWith(pending: true)
                : item,
        ];
      }
      rethrow;
    }
    _networks = next;
  });

  Future<void> _createTencent(String id) async {
    _realBusy.add(id);
    var purchaseSubmitted = false;
    try {
      var job = _requireJob(id);
      List<String>? alternatives;
      while (!_disposed) {
        if (job.unavailableZones.contains(job.effectiveZone)) {
          try {
            alternatives ??= await _alternativeTencentZones(job);
          } catch (_) {
            throw const _CloudZoneError(queryFailed: true);
          }
          if (_disposed) return;
          final nextZone = alternatives
              .where((zone) => !job.unavailableZones.contains(zone))
              .firstOrNull;
          if (nextZone == null) throw const _CloudZoneError();
          // A different placement is a different request. Change token only
          // after the previous explicit refusal was durably acknowledged.
          job = job.copyWith(
            selectedZone: nextZone,
            clientToken: const Uuid().v4(),
            subnetId: '',
            requestId: '',
            createSubmitted: false,
          );
          await _saveReal(job);
          if (_disposed) return;
        }
        final prepared = await _prepareTencent(job);
        if (_disposed) return;
        final group = prepared['security_group_id'];
        final key = prepared['key_id'];
        final vpcId = prepared['vpc_id'];
        final subnetId = prepared['subnet_id'];
        if (group is! String ||
            !RegExp(r'^sg-[a-zA-Z0-9]+$').hasMatch(group) ||
            key is! String ||
            !RegExp(r'^skey-[a-zA-Z0-9]+$').hasMatch(key) ||
            !_CloudNetworkRecord.validId(vpcId, 'vpc') ||
            !_CloudNetworkRecord.validId(subnetId, 'subnet')) {
          throw const FormatException();
        }
        // Durably record the exact zone, subnet, token and intent for EACH
        // attempt. Recovery must only query this attempt, never buy again.
        job = job.copyWith(
          securityGroupId: group,
          keyId: key,
          vpcId: vpcId as String,
          subnetId: subnetId as String,
          createSubmitted: true,
        );
        await _saveReal(job);
        if (_disposed) return;
        purchaseSubmitted = true;
        final result = await helper.call({
          'action': 'tencent_create',
          'cloud': {
            ..._cloudRequest(job),
            'template': _executionTemplate(job),
            'security_group_id': group,
            'key_id': key,
            'vpc_id': job.vpcId,
            'subnet_id': job.subnetId,
            'instance_name': job.name,
          },
        });
        if (_disposed) return;
        if (result['state'] == 'unavailable' &&
            (result['instance_id'] == null || result['instance_id'] == '')) {
          final rejected = job.copyWith(
            createSubmitted: false,
            unavailableZones: [...job.unavailableZones, job.effectiveZone],
          );
          // If saving the refusal fails, retain uncertainty and halt. The
          // durable record still protects the last submitted purchase.
          await _saveReal(rejected);
          purchaseSubmitted = false;
          job = rejected;
          continue;
        }
        final instanceId = result['instance_id'];
        if ((result['state'] != null &&
                result['state'] != '' &&
                result['state'] != 'created') ||
            instanceId is! String ||
            !RegExp(r'^ins-[a-zA-Z0-9]+$').hasMatch(instanceId)) {
          throw const FormatException();
        }
        await _saveReal(
          job.copyWith(
            instanceId: instanceId,
            requestId: result['request_id'] as String? ?? '',
          ),
        );
        _scheduleRealPoll(id);
        return;
      }
    } catch (error) {
      if (!_disposed) {
        final job = _requireJob(id);
        final networkPending = _networks.any(
          (record) =>
              record.credentialId == job.credentialId &&
              record.region == job.region &&
              record.pending,
        );
        await _saveRealError(
          job.copyWith(
            createSubmitted: purchaseSubmitted,
            phase: purchaseSubmitted
                ? CloudMachinePhase.unknown
                : CloudMachinePhase.createFailed,
            error: purchaseSubmitted
                ? '创建结果尚未确认，可能已经产生费用。请刷新查询；不要重复创建，必要时到腾讯云控制台核对。'
                : error is _CloudZoneError
                ? error.message
                : error is _CloudNetworkError
                ? error.message
                : networkPending
                ? const _CloudNetworkError().message
                : '创建准备失败，尚未提交购买。请检查凭证权限、模板与网络后重试准备；已准备的共享 VPC、子网、安全组和公钥会保留。',
          ),
        );
      }
    } finally {
      _realBusy.remove(id);
    }
  }

  // If persistence fails after an API response, retain the returned resource ID
  // in memory. The previously persisted token enables recovery after restart.
  Future<void> _saveReal(CloudMachine job) => _serialize(() async {
    final next = [for (final item in _jobs) item.id == job.id ? job : item];
    try {
      await _persist(_credentials, next);
    } catch (_) {
      _jobs = [
        for (final item in next)
          item.id == job.id
              ? item.copyWith(
                  // Do not hide a release confirmation that was not saved.
                  // Keep the card queryable so a retry or restart can finish.
                  phase: item.releaseConfirmed
                      ? CloudMachinePhase.releaseFailed
                      : item.phase,
                  error: '云操作信息无法保存，请保留实例信息并检查安全存储；云资源可能继续计费。',
                )
              : item,
      ];
      _notify();
      rethrow;
    }
    _jobs = next;
    _notify();
  });

  Future<void> _saveRealError(CloudMachine job) async {
    try {
      await _saveReal(job);
    } catch (_) {
      /* Keep the in-memory recovery record. */
    }
  }

  Future<void> refreshTencentMachine(String id) async {
    _requireInitialized();
    if (_disposed || !_realBusy.add(id)) return;
    _timers.remove(id)?.cancel();
    try {
      final job = _requireJob(id);
      if (!job.isReal || job.phase == CloudMachinePhase.released) return;
      if (!job.createSubmitted) return;
      final result = await helper.call({
        'action': job.instanceId.isEmpty
            ? 'tencent_recover'
            : 'tencent_describe',
        'cloud': _cloudRequest(job),
      });
      if (_disposed) return;
      if (result['exists'] != true) {
        if (result['exists'] != false) throw const FormatException();
        // A failed lookup is not proof that a lost purchase response created
        // nothing. Only a known exact instance may be confirmed absent.
        await _saveReal(
          job.copyWith(
            phase:
                job.instanceId.isNotEmpty &&
                    (job.phase == CloudMachinePhase.releasing ||
                        job.phase == CloudMachinePhase.releaseFailed)
                ? CloudMachinePhase.released
                : CloudMachinePhase.unknown,
            error:
                job.instanceId.isEmpty ||
                    (job.phase != CloudMachinePhase.releasing &&
                        job.phase != CloudMachinePhase.releaseFailed)
                ? '暂未查询到创建结果，仍需到腾讯云控制台核实；请勿重复购买。'
                : '云端已查不到此实例；请在控制台核对账单及自行添加的附属资源。',
          ),
        );
        return;
      }
      final found = result['instance_id'];
      if (found is! String ||
          !RegExp(r'^ins-[a-zA-Z0-9]+$').hasMatch(found) ||
          (job.instanceId.isNotEmpty && found != job.instanceId)) {
        throw const FormatException();
      }
      final state = result['state'];
      final releasing =
          job.phase == CloudMachinePhase.releasing ||
          job.phase == CloudMachinePhase.releaseFailed;
      final phase = switch (state) {
        'TERMINATED' => CloudMachinePhase.released,
        'RUNNING' || 'STOPPED'
            when job.phase == CloudMachinePhase.releaseFailed =>
          CloudMachinePhase.releaseFailed,
        'RUNNING' when !releasing => CloudMachinePhase.created,
        'STOPPED' when !releasing => CloudMachinePhase.created,
        'LAUNCH_FAILED' => CloudMachinePhase.createFailed,
        _ =>
          releasing ? CloudMachinePhase.releasing : CloudMachinePhase.creating,
      };
      await _saveReal(
        job.copyWith(
          instanceId: found,
          publicIp: result['public_ip'] as String? ?? '',
          phase: phase,
          requestId: result['request_id'] as String? ?? job.requestId,
          error: state == 'LAUNCH_FAILED'
              ? '云端报告创建失败，请释放或到控制台核实资源与费用。'
              : phase == CloudMachinePhase.releaseFailed
              ? '实例仍在运行或停止状态，尚未确认释放。请核对后重试释放。'
              : '',
        ),
      );
      if (phase == CloudMachinePhase.creating ||
          phase == CloudMachinePhase.releasing) {
        _scheduleRealPoll(id);
      } else {
        _pollAttempts.remove(id);
      }
    } catch (_) {
      if (!_disposed) {
        final job = _requireJob(id);
        await _saveRealError(
          job.copyWith(
            phase: job.phase == CloudMachinePhase.releasing
                ? CloudMachinePhase.releaseFailed
                : job.phase == CloudMachinePhase.creating
                ? CloudMachinePhase.unknown
                : job.phase,
            error: '无法确认云端状态，请检查网络与凭证权限后刷新；现有资源可能继续计费。',
          ),
        );
      }
    } finally {
      _realBusy.remove(id);
    }
  }

  Future<void> requestTencentRelease(String id) async {
    _requireInitialized();
    final job = _requireJob(id);
    if (_deploymentLocks.contains(id)) {
      throw const UserError('Sisters 正在部署，请等待部署结束后再释放云服务器。');
    }
    if (!job.isReal ||
        job.instanceId.isEmpty ||
        job.phase == CloudMachinePhase.released ||
        job.phase == CloudMachinePhase.releasing ||
        !_realBusy.add(id)) {
      throw const UserError('当前实例不能释放，请先刷新云端状态。');
    }
    try {
      _cloudRequest(job);
      await _saveReal(
        job.copyWith(phase: CloudMachinePhase.releasing, error: ''),
      );
      _timers.remove(id)?.cancel();
      if (_disposed) {
        _realBusy.remove(id);
        return;
      }
      unawaited(_releaseTencent(id));
    } catch (_) {
      if (!_disposed) {
        await _saveRealError(
          job.copyWith(error: '释放意图无法保存，尚未提交释放；请修复安全存储后重试。'),
        );
      }
      _realBusy.remove(id);
      rethrow;
    }
  }

  Future<void> _releaseTencent(String id) async {
    try {
      final job = _requireJob(id);
      final result = await helper.call({
        'action': 'tencent_release',
        'cloud': _cloudRequest(job),
      });
      if (_disposed) return;
      await _saveReal(
        job.copyWith(
          requestId: result['request_id'] as String? ?? job.requestId,
        ),
      );
      _pollAttempts.remove(id);
      _scheduleRealPoll(id);
    } catch (_) {
      if (!_disposed) {
        await _saveRealError(
          _requireJob(id).copyWith(
            phase: CloudMachinePhase.releaseFailed,
            error: '释放结果尚未确认。请刷新查询；若实例仍在，请检查权限、释放保护、额外磁盘或独立公网 IP 后重试。资源可能继续计费。',
          ),
        );
      }
    } finally {
      _realBusy.remove(id);
    }
  }

  void _scheduleRealPoll(String id) {
    if (_disposed) return;
    final count = (_pollAttempts[id] ?? 0) + 1;
    _pollAttempts[id] = count;
    if (count > 60) {
      final job = _requireJob(id);
      unawaited(
        _saveRealError(
          job.copyWith(
            phase: job.phase == CloudMachinePhase.releasing
                ? CloudMachinePhase.releaseFailed
                : CloudMachinePhase.unknown,
            error: '等待云端状态超时，请手动刷新或到控制台核对，资源可能继续计费。',
          ),
        ),
      );
      return;
    }
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(cloudPollInterval, () {
      _timers.remove(id);
      unawaited(refreshTencentMachine(id));
    });
  }

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
                    phase: job.isReal
                        ? (job.phase == CloudMachinePhase.releasing
                              ? CloudMachinePhase.releaseFailed
                              : job.createSubmitted
                              ? CloudMachinePhase.unknown
                              : CloudMachinePhase.createFailed)
                        : CloudMachinePhase.interrupted,
                    error: job.isReal
                        ? '上次云操作已中断，请刷新查询。关闭应用不释放资源，可能继续计费。'
                        : '无法保存预览进度，请检查系统安全存储。没有操作真实云资源。',
                  )
                : job,
        ];
        _notify();
      }
    });
  }

  Future<void> _persist(
    Map<CloudProvider, _StoredCredential> credentials,
    List<CloudMachine> jobs, {
    List<_CloudNetworkRecord>? networks,
  }) async {
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
          'networks': [
            for (final network in networks ?? _networks) network.toJson(),
          ],
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
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.checkedAt,
    required this.onlineVerified,
  });
  final CloudProvider provider;
  final String accessKeyId, accessKeySecret;
  final DateTime checkedAt;
  final bool onlineVerified;
  CloudCredential get summary => CloudCredential(
    provider: provider,
    maskedId: accessKeyId.length > 8
        ? '${accessKeyId.substring(0, 4)}••••${accessKeyId.substring(accessKeyId.length - 4)}'
        : '••••••••',
    checkedAt: checkedAt,
    onlineVerified: onlineVerified,
  );
  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'accessKeyId': accessKeyId,
    'accessKeySecret': accessKeySecret,
    'checkedAt': checkedAt.toIso8601String(),
    'onlineVerified': onlineVerified,
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
      accessKeyId: id,
      accessKeySecret: secret,
      checkedAt: DateTime.parse(value['checkedAt'] as String),
      onlineVerified: value['onlineVerified'] == true,
    );
  }
}

class _CloudZoneError implements Exception {
  const _CloudZoneError({this.queryFailed = false});
  final bool queryFailed;
  String get message => queryFailed
      ? '当前可用区无法购买，同地域其他可用区查询失败。尚未创建实例，请检查网络及查询机型的权限后重试准备。'
      : '建议可用区及本次查询可售的同地域其他可用区均无法购买相同规格，尚未创建实例。可稍后重新选择模板创建；已准备的共享网络会保留。';
}

class _CloudNetworkError implements Exception {
  const _CloudNetworkError({this.rejected = false});
  final bool rejected;
  String get message => rejected
      ? '腾讯云拒绝了网络创建，尚未提交服务器购买。请检查网络创建权限与配额后重试准备。'
      : '共享网络创建结果待核实，尚未提交服务器购买。重试准备只会先查询找回网络；未确认前不会重复创建，请到腾讯云控制台核对。';
}

class _CloudNetworkRecord {
  const _CloudNetworkRecord({
    required this.credentialId,
    required this.region,
    required this.kind,
    this.zone = '',
    this.vpcId = '',
    this.subnetId = '',
    this.subnetCidr = '',
    this.pending = false,
  });
  final String credentialId, region, kind, zone, vpcId, subnetId, subnetCidr;
  final bool pending;
  String get identity => jsonEncode([credentialId, region, kind, zone]);
  String get resourceId => kind == 'vpc' ? vpcId : subnetId;
  bool matches(CloudMachine job, String requestedKind, String requestedZone) =>
      credentialId == job.credentialId &&
      region == job.region &&
      kind == requestedKind &&
      zone == requestedZone;
  static bool validId(Object? value, String prefix) =>
      value is String && RegExp('^$prefix-[a-z0-9]+\$').hasMatch(value);
  static bool validSubnetCidr(Object? value) {
    if (value is! String) return false;
    final match = RegExp(r'^10\.8\.(0|[1-9][0-9]{0,2})\.0/24$')
        .firstMatch(value);
    return match != null && int.parse(match.group(1)!) <= 255;
  }

  _CloudNetworkRecord copyWith({bool? pending, String? subnetCidr}) =>
      _CloudNetworkRecord(
        credentialId: credentialId,
        region: region,
        kind: kind,
        zone: zone,
        vpcId: vpcId,
        subnetId: subnetId,
        subnetCidr: subnetCidr ?? this.subnetCidr,
        pending: pending ?? this.pending,
      );
  _CloudNetworkRecord resolve(Map<String, dynamic> value) {
    if (!validId(value['vpc_id'], 'vpc') ||
        (kind == 'subnet' &&
            (!validId(value['subnet_id'], 'subnet') ||
                !validSubnetCidr(value['subnet_cidr'])))) {
      throw const FormatException();
    }
    return _CloudNetworkRecord(
      credentialId: credentialId,
      region: region,
      kind: kind,
      zone: zone,
      vpcId: value['vpc_id'] as String,
      subnetId: kind == 'subnet' ? value['subnet_id'] as String : '',
      subnetCidr: kind == 'subnet' ? value['subnet_cidr'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'credentialId': credentialId,
    'region': region,
    'kind': kind,
    'zone': zone,
    'vpcId': vpcId,
    'subnetId': subnetId,
    'subnetCidr': subnetCidr,
    'pending': pending,
  };
  factory _CloudNetworkRecord.fromJson(Map<String, dynamic> value) {
    final record = _CloudNetworkRecord(
      credentialId: value['credentialId'] as String,
      region: value['region'] as String,
      kind: value['kind'] as String,
      zone: value['zone'] as String,
      vpcId: value['vpcId'] as String,
      subnetId: value['subnetId'] as String,
      subnetCidr: value['subnetCidr'] as String,
      pending: value['pending'] as bool,
    );
    if (CloudController.validateCredentialValue(
              record.credentialId,
              'SecretId',
            ) !=
            null ||
        !RegExp(r'^[a-z]{2}-[a-z]+(?:-[a-z]+)*$').hasMatch(record.region) ||
        !['vpc', 'subnet'].contains(record.kind) ||
        (record.vpcId.isNotEmpty && !validId(record.vpcId, 'vpc')) ||
        (record.subnetId.isNotEmpty && !validId(record.subnetId, 'subnet')) ||
        (record.subnetCidr.isNotEmpty && !validSubnetCidr(record.subnetCidr)) ||
        (record.kind == 'vpc' &&
            (record.zone.isNotEmpty ||
                record.subnetId.isNotEmpty ||
                record.subnetCidr.isNotEmpty)) ||
        (record.kind == 'subnet' &&
            (!validId(record.vpcId, 'vpc') ||
                !RegExp('^${RegExp.escape(record.region)}-[1-9][0-9]*\$')
                    .hasMatch(record.zone) ||
                (record.subnetId.isNotEmpty && record.subnetCidr.isEmpty)))) {
      throw const FormatException();
    }
    return record;
  }
}
