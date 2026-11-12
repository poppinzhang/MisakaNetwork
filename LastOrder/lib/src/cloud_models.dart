/// Cloud credentials are checked locally in this UI preview. No value in this
/// model represents a successful cloud identity or permission check.
enum CloudProvider { tencent, aliyun, volcengine }

extension CloudProviderDetails on CloudProvider {
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
    required this.alias,
    required this.maskedId,
    required this.checkedAt,
  });
  final CloudProvider provider;
  final String alias, maskedId;
  final DateTime checkedAt;
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
    this.os = 'Ubuntu 24.04 LTS',
    this.regionLabel = '地域待配置',
  });
  final String id, name, description, architecture, os, regionLabel;
  final int cpu, memoryGb, diskGb;

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
  });
  final String id, name, error;
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
      phase == CloudMachinePhase.interrupted;
  String get statusLabel => switch (phase) {
    CloudMachinePhase.creating => '创建云服务器',
    CloudMachinePhase.deploying => '部署 Sisters',
    CloudMachinePhase.ready => '部署完成',
    CloudMachinePhase.createFailed => '创建失败',
    CloudMachinePhase.deployFailed => '部署失败',
    CloudMachinePhase.releasing => '释放云服务器',
    CloudMachinePhase.released => '已释放',
    CloudMachinePhase.interrupted => '预览已中断',
  };
  CloudMachine copyWith({CloudMachinePhase? phase, String? error}) =>
      CloudMachine(
        id: id,
        name: name,
        provider: provider,
        template: template,
        phase: phase ?? this.phase,
        error: error ?? this.error,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'template': template.toJson(),
    'phase': phase.name,
    'error': error,
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
  );
}
