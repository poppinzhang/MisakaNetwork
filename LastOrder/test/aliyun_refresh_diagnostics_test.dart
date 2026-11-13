import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'aliyun_controller_test.dart' as aliyun show Harness;
import 'tencent_controller_test.dart' as tencent show Harness;
import 'volcengine_controller_test.dart' show VolcHarness;

const _pagination = '阿里云分页查询结果不完整或格式异常，请重新查询';
const _generic = '无法确认云端状态，请检查网络与凭证权限后刷新；现有资源可能继续计费。';

void main() {
  Future<aliyun.Harness> harness() async {
    final h = aliyun.Harness();
    await h.init();
    addTearDown(() => h.c.dispose());
    return h;
  }

  for (final reason in [
    _pagination,
    '阿里云分页查询模式异常，请重新查询',
    '阿里云分页查询结果重复，请重新查询',
    '阿里云响应字段格式异常，操作结果可能未知，请查询确认',
    '阿里云响应读取失败，操作结果可能未知，请查询确认',
    '阿里云身份或权限校验失败，请检查 API 密钥及授权',
    '阿里云网络请求超时，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云实例标识或操作记录无效',
    '实例查询结果不唯一，请在阿里云控制台核对',
    '云服务器与本地创建记录不匹配，已停止操作',
    '云服务器状态格式异常',
  ]) {
    testWidgets('Aliyun query retains only fixed reason: $reason', (
      tester,
    ) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_describe') throw UserError(reason);
        return delegate(request, progress);
      };
      await h.c.refreshCloudMachine(job.id);
      final failed = h.c.jobs.single;
      expect(failed.phase, CloudMachinePhase.unknown);
      expect(failed.instanceId, 'i-test1234');
      expect(failed.createSubmitted, isTrue);
      expect(failed.error, '无法确认云端状态。$reason。处理后请刷新查询；现有资源可能继续计费。');
      final stored =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect((stored['jobs'] as List).single['error'], failed.error);
      expect(h.c.visibleJobs, hasLength(1));
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
    });
  }

  testWidgets(
    'Aliyun query failure survives restart and recovers exact instance without repurchase',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      final token = h.c.jobs.single.clientToken;
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_describe') {
          throw const UserError(_pagination);
        }
        return delegate(request, progress);
      };
      await h.c.refreshCloudMachine(job.id);
      final diagnostic = h.c.jobs.single.error;
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      await expectLater(
        h.c.removeCredential(CloudProvider.aliyun),
        throwsA(isA<UserError>()),
      );
      h.c.dispose();
      h.c = h.controllerFor(h.store);
      await h.c.initialize();
      expect(h.c.jobs.single.instanceId, 'i-test1234');
      expect(h.c.jobs.single.clientToken, token);
      expect(h.c.jobs.single.error, diagnostic);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      h.helper.handler = delegate;
      await h.c.refreshCloudMachine(job.id);
      expect(h.c.jobs.single.id, job.id);
      expect(h.c.jobs.single.clientToken, token);
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(h.c.jobs.single.publicIp, '192.0.2.20');
      expect(h.c.jobs.single.error, isEmpty);
      expect(h.helper.requests.last['action'], 'aliyun_describe');
      expect(
        (h.helper.requests.last['aliyun'] as Map)['instance_id'],
        'i-test1234',
      );
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_recover'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'Aliyun lost purchase response retains token through failed recovery',
    (tester) async {
      final h = await harness();
      h.failAction = 'aliyun_create';
      final job = await h.create();
      await tester.pump();
      final token = h.c.jobs.single.clientToken;
      h.failAction = null;
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_recover') {
          throw const UserError(_pagination);
        }
        return delegate(request, progress);
      };
      await h.c.refreshCloudMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.c.jobs.single.instanceId, isEmpty);
      expect(h.c.jobs.single.error, contains(_pagination));
      h.c.dispose();
      h.c = h.controllerFor(h.store);
      await h.c.initialize();
      h.helper.handler = delegate;
      await h.c.refreshCloudMachine(job.id);
      expect(h.c.jobs.single.clientToken, token);
      expect(h.c.jobs.single.instanceId, 'i-test1234');
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(h.helper.requests.last['action'], 'aliyun_recover');
      expect((h.helper.requests.last['aliyun'] as Map)['client_token'], token);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'Aliyun release query failure protects record until confirmed absent',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshCloudMachine(job.id);
      await h.c.requestCloudRelease(job.id);
      await tester.pump();
      final token = h.c.jobs.single.clientToken;
      expect(h.c.jobs.single.phase, CloudMachinePhase.releasing);
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_describe') {
          throw const UserError(_pagination);
        }
        return delegate(request, progress);
      };
      for (var attempt = 0; attempt < 2; attempt++) {
        await h.c.refreshCloudMachine(job.id);
        expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
        expect(h.c.jobs.single.releaseSubmitted, isTrue);
        expect(h.c.jobs.single.instanceId, 'i-test1234');
        expect(h.c.jobs.single.clientToken, token);
        expect(h.c.jobs.single.publicIp, '192.0.2.20');
        expect(h.c.jobs.single.error, contains(_pagination));
        expect(h.c.visibleJobs, hasLength(1));
        expect(h.c.credentialFor(CloudProvider.aliyun), isNotNull);
        await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
        await expectLater(
          h.c.removeCredential(CloudProvider.aliyun),
          throwsA(isA<UserError>()),
        );
      }
      h.c.dispose();
      h.c = h.controllerFor(h.store);
      await h.c.initialize();
      expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
      expect(h.c.jobs.single.error, contains(_pagination));
      h.exists = false;
      h.helper.handler = delegate;
      await h.c.refreshCloudMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.released);
      expect(h.c.visibleJobs, isEmpty);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_release'),
        hasLength(1),
      );
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
    },
  );

  for (final error in [
    const UserError('$_pagination sensitive-secret'),
    const UserError('sensitive-secret $_pagination'),
    const UserError('https://sensitive-secret.invalid'),
    const UserError('云服务器关联了独立弹性公网 IP，请先在阿里云控制台核对和处理'),
    const UserError('镜像检查：模板镜像不存在或无权访问'),
    Exception(_pagination),
    const FormatException('sensitive-secret'),
  ]) {
    testWidgets(
      'Aliyun query rejects nonquery or untrusted diagnostics: $error',
      (tester) async {
        final h = await harness();
        final job = await h.create();
        await tester.pump();
        final delegate = h.helper.handler!;
        h.helper.handler = (request, progress) async {
          if (request['action'] == 'aliyun_describe') throw error;
          return delegate(request, progress);
        };
        await h.c.refreshCloudMachine(job.id);
        expect(h.c.jobs.single.error, _generic);
        expect(
          h.store.secrets[CloudController.workspaceKey],
          isNot(contains('sensitive-secret')),
        );
        expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
        expect(h.c.visibleJobs, hasLength(1));
      },
    );
  }

  testWidgets('Tencent query does not display Aliyun fixed reason', (
    tester,
  ) async {
    final h = tencent.Harness();
    await h.init();
    addTearDown(h.c.dispose);
    final job = await h.create();
    await tester.pump();
    final delegate = h.helper.handler!;
    h.helper.handler = (request, progress) async {
      if (request['action'] == 'tencent_describe') {
        throw const UserError(_pagination);
      }
      return delegate(request, progress);
    };
    await h.c.refreshCloudMachine(job.id);
    expect(h.c.jobs.single.error, _generic);
    expect(
      h.store.secrets[CloudController.workspaceKey],
      isNot(contains(_pagination)),
    );
  });

  testWidgets('Volcengine query does not display Aliyun fixed reason', (
    tester,
  ) async {
    final h = VolcHarness();
    await h.init();
    addTearDown(h.c.dispose);
    final id = await h.create(tester, refresh: false);
    final delegate = h.helper.handler!;
    h.helper.handler = (request, progress) async {
      if (request['action'] == 'volcengine_describe') {
        throw const UserError(_pagination);
      }
      return delegate(request, progress);
    };
    await h.c.refreshCloudMachine(id);
    expect(h.c.jobs.single.error, _generic);
    expect(
      h.store.secrets[CloudController.workspaceKey],
      isNot(contains(_pagination)),
    );
  });
}
