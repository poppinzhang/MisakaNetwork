import 'cloud_templates.dart';

/// Fixed ports and ingress rules shared by the cloud deployment workflows.
abstract final class TencentAccessPolicy {
  static const sshPort = 22;
  static const sistersPort = 20001;
  static const ingressCidr = '0.0.0.0/0';
}

/// Each provider owns one credential, saved after a read-only cloud check.
enum CloudProvider { tencent, aliyun, volcengine }

extension CloudProviderDetails on CloudProvider {
  bool get supportsResources => true;
  bool validRegion(String region) => RegExp(
    this != CloudProvider.tencent
        ? r'^[a-z]{2}-[a-z]+(?:-[a-z0-9]+)*$'
        : r'^[a-z]{2}-[a-z]+(?:-[a-z]+)*$',
  ).hasMatch(region);
  RegExp zonePattern(String region) {
    final suffix = this != CloudProvider.tencent
        ? RegExp(r'[0-9]$').hasMatch(region)
              ? '[a-z]'
              : '-[a-z]'
        : '-[1-9][0-9]*';
    return RegExp('^${RegExp.escape(region)}$suffix\$');
  }

  bool validInstanceId(Object? value) =>
      value is String &&
      RegExp(
        this != CloudProvider.tencent
            ? r'^i-[a-zA-Z0-9]+$'
            : r'^ins-[a-zA-Z0-9]+$',
      ).hasMatch(value);

  String get displayName => switch (this) {
    CloudProvider.tencent => '腾讯云',
    CloudProvider.aliyun => '阿里云',
    CloudProvider.volcengine => '火山引擎',
  };
  String get productName => this == CloudProvider.tencent ? 'CVM' : 'ECS';
  String get credentialIdLabel => switch (this) {
    CloudProvider.tencent => 'SecretId',
    CloudProvider.aliyun => 'AccessKey ID',
    CloudProvider.volcengine => 'Access Key ID',
  };
  String get credentialSecretLabel => switch (this) {
    CloudProvider.tencent => 'SecretKey',
    CloudProvider.aliyun => 'AccessKey Secret',
    CloudProvider.volcengine => 'Secret Access Key',
  };
  String get identityHint => switch (this) {
    CloudProvider.tencent => '使用 CAM 子用户的 API 密钥，无需填写 AppID。',
    CloudProvider.aliyun => '使用 RAM 用户的 AccessKey，不是网页登录密码。',
    CloudProvider.volcengine => '使用 IAM 用户的访问密钥，不支持火山方舟模型 API Key。',
  };
  String get docsUrl => switch (this) {
    CloudProvider.tencent =>
      'https://cloud.tencent.com/document/product/598/37140',
    CloudProvider.aliyun =>
      'https://help.aliyun.com/zh/ram/user-guide/create-an-accesskey-pair',
    CloudProvider.volcengine =>
      'https://docs.volcengine.com/docs/iam/api-access-key-management?lang=zh',
  };
}

class CloudCredential {
  const CloudCredential({
    required this.provider,
    required this.maskedId,
    required this.checkedAt,
    this.onlineVerified = false,
  });
  final CloudProvider provider;
  final String maskedId;
  final DateTime checkedAt;
  final bool onlineVerified;
  bool get locallyChecked => true;
}

class CloudTemplate {
  const CloudTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.cpu,
    required this.memoryGb,
    this.diskGb = 40,
    this.architecture = 'x64',
    this.os = 'Linux',
    this.regionLabel = '地域待配置',
    this.tencent,
    this.volcengine,
    this.aliyun,
  });
  final String id, name, description, architecture, os, regionLabel;
  final int cpu, memoryGb, diskGb;
  final Map<String, dynamic>? tencent;
  final Map<String, dynamic>? volcengine;
  final Map<String, dynamic>? aliyun;
  Map<String, dynamic>? get configuration => tencent ?? volcengine ?? aliyun;
  bool belongsTo(CloudProvider provider) =>
      [tencent, volcengine, aliyun].where((value) => value != null).length ==
          1 &&
      switch (provider) {
        CloudProvider.tencent => tencent != null,
        CloudProvider.volcengine => volcengine != null,
        CloudProvider.aliyun => aliyun != null,
      };
  bool get isReal => configuration != null;
  String get sshUsername => configuration?['sshUsername'] as String? ?? '';
  String get zone =>
      tencent?['runInstances']['Placement']['Zone'] as String? ??
      volcengine?['runInstances']['ZoneId'] as String? ??
      aliyun?['runInstances']['ZoneId'] as String? ??
      '';

  factory CloudTemplate.volcengine(Map<String, dynamic> value) => CloudTemplate(
    id: value['id'] as String,
    name: value['name'] as String,
    description: value['description'] as String,
    cpu: value['cpu'] as int,
    memoryGb: value['memoryGb'] as int,
    diskGb: value['diskGb'] as int,
    architecture: value['architecture'] as String,
    os: value['os'] as String,
    regionLabel: value['regionLabel'] as String,
    volcengine: value,
  );

  factory CloudTemplate.aliyun(Map<String, dynamic> value) => CloudTemplate(
    id: value['id'] as String,
    name: value['name'] as String,
    description: value['description'] as String,
    cpu: value['cpu'] as int,
    memoryGb: value['memoryGb'] as int,
    diskGb: value['diskGb'] as int,
    architecture: value['architecture'] as String,
    os: value['os'] as String,
    regionLabel: value['regionLabel'] as String,
    aliyun: value,
  );

  factory CloudTemplate.tencent(Map<String, dynamic> value) => CloudTemplate(
    id: value['id'] as String,
    name: value['name'] as String,
    description: value['description'] as String,
    cpu: value['cpu'] as int,
    memoryGb: value['memoryGb'] as int,
    diskGb: value['diskGb'] as int,
    architecture: value['architecture'] as String,
    os: value['os'] as String,
    regionLabel: value['regionLabel'] as String,
    tencent: value,
  );

  static List<CloudTemplate> forProvider(CloudProvider provider) => [
    CloudTemplate(
      id: '${provider.name}-starter',
      name: '轻量起步',
      description: '适合单任务体验与小规模部署',
      cpu: 2,
      memoryGb: 2,
    ),
    CloudTemplate(
      id: '${provider.name}-balanced',
      name: '均衡配置',
      description: '为日常执行与运行余量预留空间',
      cpu: 2,
      memoryGb: 4,
      diskGb: 60,
    ),
    CloudTemplate(
      id: '${provider.name}-performance',
      name: '充裕性能',
      description: '适合需要更多计算与内存的场景',
      cpu: 4,
      memoryGb: 8,
      diskGb: 80,
    ),
  ];

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'cpu': cpu,
    'memoryGb': memoryGb,
    'diskGb': diskGb,
    'architecture': architecture,
    'os': os,
    'regionLabel': regionLabel,
    'tencent': ?tencent,
    'volcengine': ?volcengine,
    'aliyun': ?aliyun,
  };
  factory CloudTemplate.fromJson(Map<String, dynamic> value) => CloudTemplate(
    id: value['id'] as String,
    name: value['name'] as String,
    description: value['description'] as String,
    cpu: value['cpu'] as int,
    memoryGb: value['memoryGb'] as int,
    diskGb: value['diskGb'] as int,
    architecture: value['architecture'] as String,
    os: value['os'] as String,
    regionLabel: value['regionLabel'] as String,
    aliyun: value['aliyun'] == null
        ? null
        : AliyunTemplateCatalog.validateTemplate(
            Map<String, dynamic>.from(value['aliyun'] as Map),
          ),
    volcengine: value['volcengine'] == null
        ? null
        : VolcengineTemplateCatalog.validateTemplate(
            Map<String, dynamic>.from(value['volcengine'] as Map),
          ),
    tencent: value['tencent'] == null
        ? null
        : TencentTemplateCatalog.validateTemplate(
            Map<String, dynamic>.from(value['tencent'] as Map),
          ),
  );
}

enum CloudMachinePhase {
  creating,
  deploying,
  ready,
  createFailed,
  deployFailed,
  releasing,
  released,
  interrupted,
  created,
  releaseFailed,
  unknown,
}

enum CloudPreviewOutcome { success, createFailure, deployFailure }

class CloudMachine {
  const CloudMachine({
    required this.id,
    required this.name,
    required this.provider,
    required this.template,
    required this.phase,
    this.error = '',
    this.isReal = false,
    this.createSubmitted = false,
    this.instanceId = '',
    this.eipId = '',
    this.releaseSubmitted = false,
    this.publicIp = '',
    this.region = '',
    this.requestId = '',
    this.credentialId = '',
    this.clientToken = '',
    this.securityGroupId = '',
    this.keyId = '',
    this.vpcId = '',
    this.subnetId = '',
    this.selectedZone = '',
    this.unavailableZones = const [],
  });
  final String id, name, error;
  final bool isReal, createSubmitted, releaseSubmitted;
  final String instanceId,
      eipId,
      publicIp,
      region,
      requestId,
      credentialId,
      clientToken,
      securityGroupId,
      keyId,
      vpcId,
      subnetId,
      selectedZone;
  final List<String> unavailableZones;
  String get effectiveZone =>
      selectedZone.isNotEmpty ? selectedZone : template.zone;
  bool get canRemove =>
      !isReal ||
      phase == CloudMachinePhase.released ||
      (phase == CloudMachinePhase.createFailed && !createSubmitted);
  // Confirmed resources leave the active list but keep their historical
  // association with task and payment reports. Previews have no API result.
  bool get releaseConfirmed =>
      isReal &&
      provider.supportsResources &&
      phase == CloudMachinePhase.released;
  final CloudProvider provider;
  final CloudTemplate template;
  final CloudMachinePhase phase;
  bool get active =>
      phase == CloudMachinePhase.creating ||
      phase == CloudMachinePhase.deploying ||
      phase == CloudMachinePhase.releasing;
  bool get failed =>
      phase == CloudMachinePhase.createFailed ||
      phase == CloudMachinePhase.deployFailed ||
      phase == CloudMachinePhase.interrupted ||
      phase == CloudMachinePhase.releaseFailed ||
      phase == CloudMachinePhase.unknown;
  String get statusLabel => switch (phase) {
    CloudMachinePhase.creating => '创建云服务器',
    CloudMachinePhase.deploying => '部署 Sisters',
    CloudMachinePhase.ready => '部署完成',
    CloudMachinePhase.createFailed => '创建失败',
    CloudMachinePhase.deployFailed => '部署失败',
    CloudMachinePhase.releasing => '释放云服务器',
    CloudMachinePhase.released => '已释放',
    CloudMachinePhase.interrupted => isReal ? '操作已中断' : '预览已中断',
    CloudMachinePhase.created => '已创建 · 待部署',
    CloudMachinePhase.releaseFailed => '释放待核实',
    CloudMachinePhase.unknown => '创建结果待核实',
  };
  CloudMachine copyWith({
    CloudMachinePhase? phase,
    String? error,
    bool? createSubmitted,
    String? instanceId,
    String? eipId,
    bool? releaseSubmitted,
    String? publicIp,
    String? requestId,
    String? securityGroupId,
    String? keyId,
    String? vpcId,
    String? subnetId,
    String? selectedZone,
    String? clientToken,
    List<String>? unavailableZones,
  }) => CloudMachine(
    id: id,
    name: name,
    provider: provider,
    template: template,
    phase: phase ?? this.phase,
    error: error ?? this.error,
    isReal: isReal,
    createSubmitted: createSubmitted ?? this.createSubmitted,
    instanceId: instanceId ?? this.instanceId,
    eipId: eipId ?? this.eipId,
    releaseSubmitted: releaseSubmitted ?? this.releaseSubmitted,
    publicIp: publicIp ?? this.publicIp,
    region: region,
    requestId: requestId ?? this.requestId,
    credentialId: credentialId,
    clientToken: clientToken ?? this.clientToken,
    securityGroupId: securityGroupId ?? this.securityGroupId,
    keyId: keyId ?? this.keyId,
    vpcId: vpcId ?? this.vpcId,
    subnetId: subnetId ?? this.subnetId,
    selectedZone: selectedZone ?? this.selectedZone,
    unavailableZones: List.unmodifiable(
      unavailableZones ?? this.unavailableZones,
    ),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'template': template.toJson(),
    'phase': phase.name,
    'error': error,
    'isReal': isReal,
    'createSubmitted': createSubmitted,
    'instanceId': instanceId,
    'eipId': eipId,
    'releaseSubmitted': releaseSubmitted,
    'publicIp': publicIp,
    'region': region,
    'requestId': requestId,
    'credentialId': credentialId,
    'clientToken': clientToken,
    'securityGroupId': securityGroupId,
    'keyId': keyId,
    'vpcId': vpcId,
    'subnetId': subnetId,
    'selectedZone': selectedZone,
    'unavailableZones': unavailableZones,
  };
  factory CloudMachine.fromJson(Map<String, dynamic> value) => CloudMachine(
    id: value['id'] as String,
    name: value['name'] as String,
    provider: CloudProvider.values.byName(value['provider'] as String),
    template: CloudTemplate.fromJson(
      Map<String, dynamic>.from(value['template'] as Map),
    ),
    phase: CloudMachinePhase.values.byName(value['phase'] as String),
    error: value['error'] as String,
    isReal: value['isReal'] as bool? ?? false,
    createSubmitted: value['createSubmitted'] as bool? ?? false,
    instanceId: value['instanceId'] as String? ?? '',
    eipId: value['eipId'] as String? ?? '',
    releaseSubmitted: value['releaseSubmitted'] as bool? ?? false,
    publicIp: value['publicIp'] as String? ?? '',
    region: value['region'] as String? ?? '',
    requestId: value['requestId'] as String? ?? '',
    credentialId: value['credentialId'] as String? ?? '',
    clientToken: value['clientToken'] as String? ?? '',
    securityGroupId: value['securityGroupId'] as String? ?? '',
    keyId: value['keyId'] as String? ?? '',
    vpcId: value['vpcId'] as String? ?? '',
    subnetId: value['subnetId'] as String? ?? '',
    selectedZone: value['selectedZone'] as String? ?? '',
    unavailableZones: List<String>.unmodifiable(
      value['unavailableZones'] as List? ?? const [],
    ),
  );
}
