import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_templates.dart';
import 'package:last_order/src/models.dart';

import 'aliyun_controller_test.dart' as aliyun show Harness;
import 'fakes.dart';

Map<String, dynamic> volcTemplateData() => {
  'id': 'volc-fixture',
  'name': '火山测试模板',
  'description': '离线测试',
  'cpu': 2,
  'memoryGb': 4,
  'diskGb': 40,
  'architecture': 'x64',
  'os': 'Ubuntu 24.04 LTS',
  'sshUsername': 'root',
  'regionLabel': '测试地域',
  'region': 'cn-beijing',
  'runInstances': {
    'ZoneId': 'cn-beijing-a',
    'InstanceTypeId': 'ecs.g3i.large',
    'ImageId': 'image-fixture',
    'Volumes': [
      {'VolumeType': 'ESSD_PL0', 'Size': 40},
    ],
    'EipAddress': {
      'BandwidthMbps': 5,
      'ISP': 'BGP',
      'ChargeType': 'PayByTraffic',
      'ReleaseWithInstance': true,
    },
  },
};

class VolcHarness {
  final store = MemoryStore();
  final helper = FakeHelper();
  late CloudController c;
  String state = 'RUNNING', eipId = 'eip-fixture';
  bool exists = true, purchaseLost = false, unavailable = false;
  bool networkVisible = true, networkCreateLost = false;
  bool releaseLost = false, failAfterDescribe = false, prepareFails = false;
  bool disposed = false;
  CloudController controller(MemoryStore storage) => CloudController(
    store: storage,
    helper: helper,
    templateLoader: () async => [],
    volcengineTemplateLoader: () async => [
      CloudTemplate.volcengine(volcTemplateData()),
    ],
    preparationPollAttempts: 2,
    preparationPollInterval: Duration.zero,
  );
  Future<void> init() async {
    helper.handler = (request, _) async {
      final action = request['action'];
      if (action == 'verify_cloud_credential') {
        return {
          'verified': true,
          'provider': (request['cloud_credential'] as Map)['provider'],
        };
      }
      if (action == 'generate_cloud_ssh_key') {
        return {
          'private_key': '-----BEGIN RSA PRIVATE KEY-----fixture',
          'public_key': 'ssh-rsa fixture',
          'fingerprint': 'SHA256:fixture',
        };
      }
      expectSync(request.containsKey('cloud'), isFalse);
      final input = request['volcengine'] as Map;
      switch (action) {
        case 'volcengine_zones':
          return {'zones': <String>[]};
        case 'volcengine_network_lookup':
          return {
            'found': networkVisible,
            'vpc_id': networkVisible ? 'vpc-fixture' : '',
            'subnet_id': networkVisible ? 'subnet-fixture' : '',
            'subnet_cidr': '10.8.0.0/24',
          };
        case 'volcengine_network_create':
          if (networkCreateLost) {
            throw const UserError('secret-sensitive-upstream');
          }
          return {
            'state': 'ready',
            'vpc_id': 'vpc-fixture',
            'subnet_id': 'subnet-fixture',
            'subnet_cidr': '10.8.0.0/24',
          };
        case 'volcengine_prepare':
          if (prepareFails) {
            throw const UserError('secret-sensitive-upstream');
          }
          expectSync(input['vpc_id'], 'vpc-fixture');
          return {
            'security_group_id': 'sg-fixture',
            'key_id': 'MisakaNetwork-key',
          };
        case 'volcengine_create':
          final saved =
              (jsonDecode(store.secrets[CloudController.workspaceKey]!)['jobs']
                          as List)
                      .last
                  as Map;
          expectSync(saved['provider'], 'volcengine');
          expectSync(saved['createSubmitted'], true);
          expectSync(saved['clientToken'], input['client_token']);
          expectSync(
            input['template']['runInstances']['EipAddress']['ReleaseWithInstance'],
            true,
          );
          if (purchaseLost) throw const UserError('secret-sensitive-upstream');
          if (unavailable) return {'state': 'unavailable'};
          return {
            'state': 'created',
            'instance_id': 'i-fixture',
            'request_id': 'fixture-create',
          };
        case 'volcengine_describe':
        case 'volcengine_recover':
          if (failAfterDescribe) {
            store.failWrite.add(CloudController.workspaceKey);
          }
          return {
            'exists': exists,
            'instance_id': 'i-fixture',
            'eip_id': eipId,
            'state': state,
            'public_ip': '192.0.2.42',
          };
        case 'volcengine_release':
          final saved =
              (jsonDecode(store.secrets[CloudController.workspaceKey]!)['jobs']
                          as List)
                      .last
                  as Map;
          expectSync(saved['releaseSubmitted'], true);
          expectSync(saved['eipId'], 'eip-fixture');
          expectSync(input['release_submitted'], true);
          expectSync(input['eip_id'], 'eip-fixture');
          if (releaseLost) throw const UserError('secret-sensitive-upstream');
          return {'request_id': 'fixture-release'};
      }
      throw StateError('Unexpected action $action');
    };
    c = controller(store);
    await c.initialize();
    await c.saveCredential(
      CloudProvider.volcengine,
      accessKeyId: 'FixtureAccessId',
      accessKeySecret: 'FixtureSecret',
    );
  }

  Future<String> create(WidgetTester tester, {bool refresh = true}) async {
    final job = await c.startCloudCreation(
      CloudProvider.volcengine,
      c.templatesFor(CloudProvider.volcengine).single,
    );
    await tester.pump();
    if (refresh) await c.refreshCloudMachine(job.id);
    return job.id;
  }

  int calls(String suffix) =>
      helper.requests.where((r) => r['action'] == 'volcengine_$suffix').length;
}

void main() {
  Future<VolcHarness> harness() async {
    final h = VolcHarness();
    await h.init();
    addTearDown(() {
      if (!h.disposed) h.c.dispose();
    });
    return h;
  }

  test(
    'catalog strictly accepts fixed EIP lifecycle and administrator fields',
    () {
      final value = volcTemplateData();
      final parsed = VolcengineTemplateCatalog.parse(
        jsonEncode({
          'schemaVersion': 2,
          'templates': [value],
        }),
      );
      expect(parsed.single, value);
      for (final region in ['ap-southeast-1', 'ap-southeast-3']) {
        final international = volcTemplateData();
        international['region'] = region;
        international['runInstances']['ZoneId'] = '${region}a';
        expect(
          VolcengineTemplateCatalog.validateTemplate(international),
          international,
        );
        expect(
          CloudProvider.volcengine.zonePattern(region).hasMatch('${region}a'),
          true,
        );
        international['runInstances']['ZoneId'] = '$region-a';
        expect(
          () => VolcengineTemplateCatalog.validateTemplate(international),
          throwsFormatException,
        );
      }
      final hyphenFamily = volcTemplateData();
      hyphenFamily['runInstances']['InstanceTypeId'] = 'ecs.g3i-test.large';
      expect(
        VolcengineTemplateCatalog.validateTemplate(hyphenFamily),
        hyphenFamily,
      );
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (t) => t['runInstances']['EipAddress']['ReleaseWithInstance'] = false,
        (t) => t['runInstances']['EipAddress']['ChargeType'] = 'PrePaid',
        (t) => t['runInstances']['UserData'] = 'secret',
        (t) => t['runInstances']['ImageId'] = 'image-UPPERCASE',
        (t) => t['runInstances']['Volumes'].add({
          'VolumeType': 'ESSD_PL0',
          'Size': 40,
        }),
        (t) => t['runInstances']['Volumes'][0]['DeleteWithInstance'] = false,
        (t) => t['runInstances']['ZoneId'] = 'cn-shanghai-a',
        (t) => t['runInstances']['EipAddress']['BandwidthMbps'] = 201,
        (t) => t['runInstances']['Volumes'][0]['Size'] = 2049,
        (t) => t['secretKey'] = 'secret',
      ]) {
        final bad = volcTemplateData();
        mutate(bad);
        expect(
          () => VolcengineTemplateCatalog.validateTemplate(bad),
          throwsFormatException,
        );
      }
      expect(
        () => VolcengineTemplateCatalog.parse(
          jsonEncode({
            'schemaVersion': 2,
            'templates': [value, value],
          }),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('persists EIP and release intent then waits for both resources', (
    tester,
  ) async {
    final h = await harness();
    final id = await h.create(tester);
    expect(h.c.jobs.single.phase, CloudMachinePhase.created);
    expect(h.c.jobs.single.eipId, 'eip-fixture');
    await h.c.requestCloudRelease(id);
    await tester.pump();
    expect(h.c.jobs.single.phase, CloudMachinePhase.releasing);
    h.state = 'EIP_RELEASE_PENDING';
    await h.c.refreshCloudMachine(id);
    expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
    expect(h.c.visibleJobs, hasLength(1));
    expect(h.c.jobs.single.error, contains('公网 IP'));
    await expectLater(
      h.c.removeCredential(CloudProvider.volcengine),
      throwsA(isA<UserError>()),
    );
    await expectLater(h.c.removeMachine(id), throwsA(isA<UserError>()));
    h.state = 'TERMINATED';
    await h.c.refreshCloudMachine(id);
    expect(h.c.jobs.single.releaseConfirmed, true);
    expect(h.c.visibleJobs, isEmpty);
    await h.c.removeCredential(CloudProvider.volcengine);
    expect(h.calls('release'), 1);
  });

  testWidgets(
    'missing EIP blocks release and persistence failure never submits deletion',
    (tester) async {
      final h = await harness();
      h.eipId = '';
      final id = await h.create(tester);
      await expectLater(h.c.requestCloudRelease(id), throwsA(isA<UserError>()));
      expect(h.calls('release'), 0);
      h.eipId = 'eip-fixture';
      await h.c.refreshCloudMachine(id);
      h.store.failWrite.add(CloudController.workspaceKey);
      await expectLater(h.c.requestCloudRelease(id), throwsA(isA<UserError>()));
      expect(h.calls('release'), 0);
      expect(h.c.jobs.single.releaseSubmitted, false);
    },
  );

  testWidgets('changed EIP and unproven absence cannot hide resources', (
    tester,
  ) async {
    final h = await harness();
    final id = await h.create(tester);
    h.eipId = 'eip-other';
    await h.c.refreshCloudMachine(id);
    expect(h.c.jobs.single.eipId, 'eip-fixture');
    expect(h.c.jobs.single.error, contains('无法确认'));
    h.state = 'TERMINATED';
    h.eipId = 'eip-fixture';
    await h.c.refreshCloudMachine(id);
    expect(h.c.visibleJobs, hasLength(1)); // no prior release intent
    await h.c.requestCloudRelease(id);
    await tester.pump();
    h.exists = false;
    await h.c.refreshCloudMachine(id);
    expect(h.c.visibleJobs, hasLength(1));
    expect(h.c.jobs.single.canRemove, false);
    h.exists = true;
    h.eipId = '';
    await h.c.refreshCloudMachine(id);
    expect(h.c.visibleJobs, hasLength(1)); // final response must identify EIP
  });

  testWidgets(
    'lost purchase response only recovers and cannot replay or remove credential',
    (tester) async {
      final h = await harness();
      h.purchaseLost = true;
      final id = await h.create(tester, refresh: false);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.c.jobs.single.error, isNot(contains('secret-sensitive')));
      h.exists = false;
      await h.c.refreshCloudMachine(id);
      await expectLater(
        h.c.retryCloudPreparation(id),
        throwsA(isA<UserError>()),
      );
      await expectLater(
        h.c.removeCredential(CloudProvider.volcengine),
        throwsA(isA<UserError>()),
      );
      expect(h.calls('create'), 1);
      expect(h.calls('recover'), 1);
    },
  );

  testWidgets(
    'unavailable zone queries alternatives once and does not rebuy without candidates',
    (tester) async {
      final h = await harness();
      h.unavailable = true;
      await h.create(tester, refresh: false);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.createSubmitted, false);
      expect(h.c.jobs.single.error, contains('相同规格'));
      expect(h.calls('create'), 1);
      expect(h.calls('zones'), 1);
    },
  );

  testWidgets(
    'restart retains EIP and release intent, query only completes cleanup',
    (tester) async {
      final h = await harness();
      final id = await h.create(tester);
      h.releaseLost = true;
      await h.c.requestCloudRelease(id);
      await tester.pump();
      expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
      h.c.dispose();
      h.disposed = true;
      final next = h.controller(h.store);
      addTearDown(next.dispose);
      await next.initialize();
      expect(next.jobs.single.eipId, 'eip-fixture');
      expect(next.jobs.single.releaseSubmitted, true);
      h.state = 'TERMINATED';
      await next.refreshCloudMachine(id);
      expect(next.visibleJobs, isEmpty);
      expect(h.calls('create'), 1);
      expect(h.calls('release'), 1);
    },
  );

  testWidgets(
    'unknown network intent survives removed failed job and blocks replay',
    (tester) async {
      final h = await harness();
      h.networkVisible = false;
      h.networkCreateLost = true;
      final id = await h.create(tester, refresh: false);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.calls('create'), 0);
      await h.c.removeMachine(id);
      await expectLater(
        h.c.removeCredential(CloudProvider.volcengine),
        throwsA(isA<UserError>()),
      );
      await h.c.saveCredential(
        CloudProvider.tencent,
        accessKeyId: 'FixtureAccessId',
        accessKeySecret: 'OtherProviderSecret',
      );
      await h.c.removeCredential(CloudProvider.tencent);
      await h.create(tester, refresh: false);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(h.calls('network_create'), 1);
      final stored =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect(stored['networks'].single['provider'], 'volcengine');
      expect(stored['networks'].single['pending'], true);
    },
  );

  testWidgets(
    'submitted release never reopens deployment while instance still runs',
    (tester) async {
      final h = await harness();
      final id = await h.create(tester);
      await h.c.requestCloudRelease(id);
      await tester.pump();
      await h.c.refreshCloudMachine(id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
      await expectLater(
        h.c.beginCloudDeployment(id),
        throwsA(isA<UserError>()),
      );
    },
  );

  testWidgets(
    'international region and network ledger restore with native zone naming',
    (tester) async {
      final h = await harness();
      await h.create(tester);
      h.c.dispose();
      h.disposed = true;
      final saved = jsonDecode(
        h.store.secrets[CloudController.workspaceKey]!,
      ) as Map<String, dynamic>;
      final job = saved['jobs'].single as Map;
      job['region'] = 'ap-southeast-1';
      job['selectedZone'] = 'ap-southeast-1a';
      job['template']['volcengine']['region'] = 'ap-southeast-1';
      job['template']['volcengine']['runInstances']['ZoneId'] =
          'ap-southeast-1a';
      for (final network in saved['networks'] as List) {
        network['region'] = 'ap-southeast-1';
        if (network['kind'] == 'subnet') network['zone'] = 'ap-southeast-1a';
      }
      h.store.secrets[CloudController.workspaceKey] = jsonEncode(saved);
      final restored = h.controller(h.store);
      try {
        await restored.initialize();
        expect(restored.initialized, true);
        expect(restored.startupError, isNull);
        expect(restored.jobs.single.effectiveZone, 'ap-southeast-1a');
      } finally {
        restored.dispose();
      }
    },
  );

  testWidgets(
    'helper preparation errors never expose raw text before purchase',
    (tester) async {
      final h = await harness();
      h.prepareFails = true;
      await h.create(tester, refresh: false);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.error, contains('创建准备失败'));
      expect(
        h.c.jobs.single.error,
        isNot(contains('secret-sensitive-upstream')),
      );
      expect(h.calls('create'), 0);
    },
  );

  for (final reason in [
    '火山引擎身份或权限校验失败，请检查访问密钥及授权',
    '火山引擎配额或请求频率受限，请查询确认后重试',
    '火山引擎账户余额不足',
    '火山引擎网络请求未完成，结果可能未知，请查询核对',
    '火山引擎服务域名解析失败，结果可能未知，请查询核对',
    '火山引擎网络请求超时，结果可能未知，请查询核对',
    '火山引擎 TLS 服务器证书验证失败，结果可能未知，请查询核对',
    '火山引擎 TLS 服务器域名验证失败，结果可能未知，请查询核对',
    '火山引擎网络访问被系统权限阻止，结果可能未知，请查询核对',
    '火山引擎网络连接被拒绝，结果可能未知，请查询核对',
    '火山引擎网络或目标主机不可达，结果可能未知，请查询核对',
    '火山引擎网络连接中断，结果可能未知，请查询核对',
    '火山引擎网络请求已取消，结果可能未知，请查询核对',
    '火山引擎响应格式异常，请查询确认',
    '火山引擎查询响应缺少资源列表，请重新查询',
    '火山引擎查询资源列表格式异常，请重新查询',
    '火山引擎查询分页结果不完整，请重新查询',
    '云资源准备未完成，请重试查询确认',
    '模板镜像不存在或无权访问',
    '模板镜像必须是可用的 Linux 镜像，架构与系统盘须匹配',
    '模板镜像不允许附带数据盘',
    '同名云密钥的归属或指纹不匹配',
    '安全组规则与固定策略不匹配，请在控制台核对',
  ]) {
    testWidgets('preparation shows fixed reason without purchasing: $reason', (
      tester,
    ) async {
      final h = await harness();
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_prepare') {
          throw UserError(reason);
        }
        return original(request, progress);
      };
      await h.create(tester, refresh: false);
      final job = h.c.jobs.single;
      expect(job.phase, CloudMachinePhase.createFailed);
      expect(job.createSubmitted, false);
      expect(job.error, contains('镜像、公钥与安全组检查：$reason'));
      expect(job.error, contains('尚未提交购买'));
      expect(h.calls('create'), 0);
      final saved =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect(saved['jobs'].single['error'], job.error);
    });
  }

  for (final entry in {
    'SSH 公钥检查': 'SSH 公钥必须是有效的 OpenSSH RSA 公钥',
    '镜像检查': '火山引擎查询响应缺少资源列表，请重新查询',
    '共享 VPC 复核': '火山引擎查询分页结果不完整，请重新查询',
    'SSH 公钥准备': '火山引擎查询资源列表格式异常，请重新查询',
    '安全组准备': '云资源准备未完成，请重试查询确认',
  }.entries) {
    testWidgets(
      'specific preparation stage persists and retries: ${entry.key}',
      (tester) async {
        final h = await harness();
        final original = h.helper.handler!;
        h.helper.handler = (request, progress) async {
          if (request['action'] == 'volcengine_prepare') {
            throw UserError('${entry.key}：${entry.value}');
          }
          return original(request, progress);
        };
        final id = await h.create(tester, refresh: false);
        final job = h.c.jobs.single;
        expect(job.phase, CloudMachinePhase.createFailed);
        expect(job.createSubmitted, false);
        expect(job.error, contains('${entry.key}：${entry.value}'));
        expect(job.error, isNot(contains('镜像、公钥与安全组检查')));
        expect(h.calls('create'), 0);
        final saved =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
        expect(saved['jobs'].single['error'], job.error);

        h.c.dispose();
        h.c = h.controller(h.store);
        await h.c.initialize();
        expect(h.c.jobs.single.id, id);
        expect(h.c.jobs.single.error, job.error);
        expect(h.calls('create'), 0);
        h.helper.handler = original;
        await h.c.retryCloudPreparation(id);
        await tester.pump();
        await h.c.refreshCloudMachine(id);
        expect(h.c.jobs, hasLength(1));
        expect(h.c.jobs.single.id, id);
        expect(h.c.jobs.single.instanceId, 'i-fixture');
        expect(h.c.jobs.single.error, isEmpty);
        expect(h.calls('create'), 1);
      },
    );
  }

  testWidgets('Volcengine preparation reason is not recognized for Aliyun', (
    tester,
  ) async {
    final h = aliyun.Harness();
    await h.init();
    addTearDown(h.c.dispose);
    final original = h.helper.handler!;
    h.helper.handler = (request, progress) async {
      if (request['action'] == 'aliyun_prepare') {
        throw const UserError('安全组准备：火山引擎网络请求超时，结果可能未知，请查询核对');
      }
      return original(request, progress);
    };
    await h.create();
    await tester.pump();
    expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
    expect(h.c.jobs.single.createSubmitted, false);
    expect(h.c.jobs.single.error, contains('请检查凭证权限、模板与网络'));
    expect(h.c.jobs.single.error, isNot(contains('安全组准备：')));
    expect(
      h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
      isEmpty,
    );
  });

  for (final kind in ['vpc', 'subnet']) {
    testWidgets('initial $kind lookup reports fixed conflict and can retry', (
      tester,
    ) async {
      final h = await harness();
      final original = h.helper.handler!;
      const reason = '同名共享网络的归属或配置不匹配，请在火山引擎控制台核对';
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_network_lookup' &&
            (request['volcengine'] as Map)['network_kind'] == kind) {
          throw const UserError(reason);
        }
        return original(request, progress);
      };
      final id = await h.create(tester, refresh: false);
      final job = h.c.jobs.single;
      expect(job.phase, CloudMachinePhase.createFailed);
      expect(job.createSubmitted, false);
      expect(
        job.error,
        contains('${kind == 'vpc' ? '共享 VPC 准备' : '共享子网准备'}：$reason'),
      );
      expect(h.calls('network_create'), 0);
      expect(h.calls('create'), 0);

      h.helper.handler = original;
      await h.c.retryCloudPreparation(id);
      await tester.pump();
      await h.c.refreshCloudMachine(id);
      expect(h.c.jobs.single.instanceId, 'i-fixture');
      expect(h.c.jobs.single.error, isEmpty);
      expect(h.c.jobs.single.id, id);
      expect(h.calls('create'), 1);
    });

    testWidgets('specific helper stage is not recognized during $kind lookup', (
      tester,
    ) async {
      final h = await harness();
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_network_lookup' &&
            (request['volcengine'] as Map)['network_kind'] == kind) {
          throw const UserError('安全组准备：云资源准备未完成，请重试查询确认');
        }
        return original(request, progress);
      };
      await h.create(tester, refresh: false);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.error, contains('请检查凭证权限、模板与网络'));
      expect(h.c.jobs.single.error, isNot(contains('安全组准备：')));
      expect(h.calls('network_create'), 0);
      expect(h.calls('create'), 0);
    });
  }

  for (final error in <Object>[
    const UserError('模板镜像不存在或无权访问 secret-sensitive-upstream'),
    const UserError('secret-sensitive-upstream 模板镜像不存在或无权访问'),
    StateError('模板镜像不存在或无权访问'),
    const UserError('secret-sensitive-upstream：模板镜像不存在或无权访问'),
    const UserError('镜像检查：模板镜像不存在或无权访问 secret-sensitive-upstream'),
    const UserError('secret-sensitive-upstream 镜像检查：模板镜像不存在或无权访问'),
    const UserError('镜像检查：secret-sensitive-upstream'),
    const UserError('镜像检查：模板镜像不存在或无权访问。'),
    const UserError('镜像检查:模板镜像不存在或无权访问'),
    const UserError(' 镜像检查：模板镜像不存在或无权访问'),
    StateError('镜像检查：模板镜像不存在或无权访问'),
  ]) {
    testWidgets('non-allowlisted preparation error stays generic: $error', (
      tester,
    ) async {
      final h = await harness();
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_prepare') throw error;
        return original(request, progress);
      };
      await h.create(tester, refresh: false);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.error, contains('请检查凭证权限、模板与网络'));
      expect(h.c.jobs.single.error, isNot(contains('模板镜像')));
      expect(h.c.jobs.single.error, isNot(contains('secret-sensitive')));
      expect(h.calls('create'), 0);
      final saved =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect(saved['jobs'].single['error'], h.c.jobs.single.error);
    });
  }

  for (final helperError in [
    '火山引擎身份或权限校验失败，请检查访问密钥及授权',
    '安全组准备：火山引擎身份或权限校验失败，请检查访问密钥及授权',
  ]) {
    testWidgets(
      'pending network takes priority over helper reason: $helperError',
      (tester) async {
        final h = await harness();
        final original = h.helper.handler!;
        var lookups = 0;
        h.helper.handler = (request, progress) async {
          if (request['action'] == 'volcengine_network_lookup') {
            if (++lookups == 1) return {'found': false};
            throw UserError(helperError);
          }
          if (request['action'] == 'volcengine_network_create') {
            throw const UserError('火山引擎网络请求未完成，结果可能未知，请查询核对');
          }
          return original(request, progress);
        };
        final id = await h.create(tester, refresh: false);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(h.c.jobs.single.error, contains('共享网络创建结果待核实'));
        expect(h.c.jobs.single.error, isNot(contains('身份或权限')));
        expect(h.calls('network_create'), 1);
        expect(h.calls('create'), 0);
        await h.c.retryCloudPreparation(id);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(h.calls('network_create'), 1);
        expect(h.calls('create'), 0);
      },
    );
  }

  for (final helperError in [
    '火山引擎身份或权限校验失败，请检查访问密钥及授权',
    '安全组准备：火山引擎身份或权限校验失败，请检查访问密钥及授权',
  ]) {
    testWidgets(
      'reason after purchase keeps uncertainty and only recovers: $helperError',
      (tester) async {
        final h = await harness();
        final original = h.helper.handler!;
        h.helper.handler = (request, progress) async {
          if (request['action'] == 'volcengine_create') {
            throw UserError(helperError);
          }
          return original(request, progress);
        };
        final id = await h.create(tester, refresh: false);
        expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
        expect(h.c.jobs.single.createSubmitted, true);
        expect(h.c.jobs.single.error, contains('创建结果尚未确认'));
        expect(h.c.jobs.single.error, isNot(contains('身份或权限')));
        final saved =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
        expect(saved['jobs'].single['error'], h.c.jobs.single.error);
        await expectLater(
          h.c.retryCloudPreparation(id),
          throwsA(isA<UserError>()),
        );
        h.exists = false;
        await h.c.refreshCloudMachine(id);
        expect(h.calls('create'), 1);
        expect(h.calls('recover'), 1);
      },
    );
  }

  testWidgets(
    'creating network IDs are pinned across lookup timeout and restart',
    (tester) async {
      final h = await harness();
      final original = h.helper.handler!;
      var lookups = 0;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_network_lookup') {
          lookups++;
          final input = request['volcengine'] as Map;
          if (lookups == 1) return {'found': false};
          if (lookups > 2) expect(input['vpc_id'], 'vpc-pending');
          return {'found': false, 'vpc_id': 'vpc-pending'};
        }
        if (request['action'] == 'volcengine_network_create') {
          throw const UserError('lost response');
        }
        return original(request, progress);
      };
      final id = await h.create(tester, refresh: false);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      final saved =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect(saved['networks'].single['vpcId'], 'vpc-pending');
      expect(saved['networks'].single['pending'], true);
      h.c.dispose();
      h.disposed = true;
      final restored = h.controller(h.store);
      try {
        await restored.initialize();
        await restored.retryCloudPreparation(id);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(restored.jobs.single.phase, CloudMachinePhase.createFailed);
        expect(h.calls('network_create'), 1);
        expect(h.calls('create'), 0);
      } finally {
        restored.dispose();
      }
    },
  );

  testWidgets(
    'existing creating network is pinned without a mutation and save failure stops purchase',
    (tester) async {
      final h = await harness();
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'volcengine_network_lookup') {
          h.store.failWrite.add(CloudController.workspaceKey);
          return {'found': false, 'vpc_id': 'vpc-pending'};
        }
        return original(request, progress);
      };
      await h.create(tester, refresh: false);
      expect(h.calls('network_create'), 0);
      expect(h.calls('create'), 0);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
    },
  );

  testWidgets('Volcengine cannot use preview or Tencent templates', (
    tester,
  ) async {
    final h = await harness();
    await expectLater(
      h.c.startPreviewCreation(
        CloudProvider.volcengine,
        CloudTemplate.forProvider(CloudProvider.volcengine).first,
      ),
      throwsA(isA<UserError>()),
    );
    await expectLater(
      h.c.startCloudCreation(
        CloudProvider.tencent,
        h.c.templatesFor(CloudProvider.volcengine).single,
      ),
      throwsA(isA<UserError>()),
    );
    expect(h.calls('create'), 0);
  });
}
