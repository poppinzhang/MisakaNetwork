import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'aliyun_controller_test.dart' show Harness;

const _responseReasons = <String>[
  '阿里云响应读取失败，操作结果可能未知，请查询确认',
  '阿里云响应超过大小限制，操作结果可能未知，请查询确认',
  '阿里云 HTTP 响应状态异常，操作结果可能未知，请查询确认',
  '阿里云响应字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组规则查询响应读取失败，操作结果可能未知，请查询确认',
  '阿里云安全组规则查询响应超过大小限制，操作结果可能未知，请查询确认',
  '阿里云安全组规则查询 HTTP 响应状态异常，操作结果可能未知，请查询确认',
  '阿里云安全组规则查询响应字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组规则优先级字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组规则列表字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组分页标记字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组归属字段格式异常，操作结果可能未知，请查询确认',
  '阿里云安全组规则内容字段格式异常，操作结果可能未知，请查询确认',
];

void main() {
  Future<Harness> harness() async {
    final h = Harness();
    await h.init();
    addTearDown(() => h.c.dispose());
    return h;
  }

  const permission = '阿里云身份或权限校验失败，请检查 API 密钥及授权';
  for (final entry in {
    'vpc': '共享 VPC 准备',
    'subnet': '共享子网准备',
    'prepare': '镜像、公钥与安全组检查',
  }.entries) {
    testWidgets(
      'Aliyun ${entry.key} failure retains exact fixed stage and safe reason',
      (tester) async {
        final h = await harness();
        final delegate = h.helper.handler!;
        h.helper.handler = (request, progress) async {
          if (entry.key == 'prepare'
              ? request['action'] == 'aliyun_prepare'
              : request['action'] == 'aliyun_network_lookup' &&
                    (request['aliyun'] as Map)['network_kind'] == entry.key) {
            throw const UserError(permission);
          }
          return delegate(request, progress);
        };
        await h.create();
        await tester.pump();
        final job = h.c.jobs.single;
        expect(job.phase, CloudMachinePhase.createFailed);
        expect(job.createSubmitted, isFalse);
        expect(job.error, contains('${entry.value}：$permission'));
        expect(
          h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
          isEmpty,
        );
        final stored =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
        expect((stored['jobs'] as List).single['error'], job.error);
      },
    );
  }

  for (final reason in [
    '阿里云服务域名解析失败，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络请求超时，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云 TLS 服务器域名验证失败，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云 TLS 服务器证书验证失败，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络访问被系统权限阻止，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络连接被拒绝，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络或目标主机不可达，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络连接中断，操作结果可能未知，请重新查询或到控制台核对',
    '阿里云网络请求已取消，操作结果可能未知，请重新查询或到控制台核对',
    '云资源准备未完成，请重试查询确认',
    '模板镜像必须是可用的 Linux 镜像，架构与系统盘大小必须匹配',
    '模板镜像不允许附带数据盘',
    '模板镜像必须仅包含一块系统盘，不允许附带数据盘',
    '模板镜像缺少磁盘映射信息，无法确认单系统盘配置',
    '模板镜像磁盘类型无法确认，已停止创建',
    '模板镜像系统盘映射与容量不匹配',
    '阿里云分页查询模式异常，请重新查询',
  ]) {
    testWidgets('Aliyun preparation explains fixed contract failure: $reason', (
      tester,
    ) async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_prepare') throw UserError(reason);
        return delegate(request, progress);
      };
      await h.create();
      await tester.pump();
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.error, contains(reason));
      expect(h.c.jobs.single.createSubmitted, isFalse);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
    });
  }

  for (final entry in {
    'SSH 公钥检查': 'SSH 公钥必须是有效的 OpenSSH RSA 公钥',
    '共享 VPC 复核': '阿里云服务域名解析失败，操作结果可能未知，请重新查询或到控制台核对',
    '镜像检查': '模板镜像缺少磁盘映射信息，无法确认单系统盘配置',
    'SSH 公钥准备': '阿里云网络请求超时，操作结果可能未知，请重新查询或到控制台核对',
    '安全组准备': permission,
    '云资源准备': '云资源准备未完成，请重试查询确认',
  }.entries) {
    testWidgets('Aliyun ${entry.key} persists and retries the same record', (
      tester,
    ) async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_prepare') {
          throw UserError('${entry.key}：${entry.value}');
        }
        return delegate(request, progress);
      };
      final created = await h.create();
      await tester.pump();
      final failed = h.c.jobs.single;
      expect(failed.createSubmitted, isFalse);
      expect(failed.error, contains('${entry.key}：${entry.value}'));
      expect(failed.error, isNot(contains('镜像、公钥与安全组检查')));
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
      final stored =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect((stored['jobs'] as List).single['error'], failed.error);

      h.c.dispose();
      h.c = h.controllerFor(h.store);
      await h.c.initialize();
      expect(h.c.jobs.single.id, created.id);
      expect(h.c.jobs.single.error, failed.error);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
      h.helper.handler = delegate;
      await h.c.retryCloudPreparation(created.id);
      await tester.pump();
      await h.c.refreshCloudMachine(created.id);
      expect(h.c.jobs, hasLength(1));
      expect(h.c.jobs.single.id, created.id);
      expect(h.c.jobs.single.instanceId, 'i-test1234');
      expect(h.c.jobs.single.error, isEmpty);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_network_create'),
        isEmpty,
      );
    });
  }

  for (final reason in _responseReasons) {
    testWidgets('Aliyun response diagnostic persists and retries: $reason', (
      tester,
    ) async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_prepare') {
          throw UserError('安全组准备：$reason');
        }
        return delegate(request, progress);
      };
      final created = await h.create();
      await tester.pump();
      final failed = h.c.jobs.single;
      expect(failed.error, contains('安全组准备：$reason'));
      expect(failed.createSubmitted, isFalse);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
      final stored =
          jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
      expect((stored['jobs'] as List).single['error'], failed.error);
      h.c.dispose();
      h.c = h.controllerFor(h.store);
      await h.c.initialize();
      expect(h.c.jobs.single.id, created.id);
      expect(h.c.jobs.single.error, failed.error);
      h.helper.handler = delegate;
      await h.c.retryCloudPreparation(created.id);
      await tester.pump();
      await h.c.refreshCloudMachine(created.id);
      expect(h.c.jobs.single.id, created.id);
      expect(h.c.jobs.single.instanceId, 'i-test1234');
      expect(h.c.jobs.single.error, isEmpty);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        hasLength(1),
      );
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_network_create'),
        isEmpty,
      );
    });
  }

  for (final error in [
    for (final reason in _responseReasons)
      UserError('安全组准备：$reason sensitive-secret'),
    UserError('未知阶段：$permission'),
    UserError('安全组准备：$permission sensitive-secret'),
    const UserError('镜像检查：https://sensitive-secret.invalid'),
    const UserError('安全组准备：火山引擎网络请求超时，结果可能未知，请查询核对'),
    Exception('安全组准备：$permission'),
  ]) {
    testWidgets('Aliyun staged error rejects untrusted text: $error', (
      tester,
    ) async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_prepare') throw error;
        return delegate(request, progress);
      };
      await h.create();
      await tester.pump();
      final shown = h.c.jobs.single.error;
      expect(shown, isNot(contains('安全组准备：')));
      expect(shown, isNot(contains('镜像检查：')));
      expect(shown, isNot(contains('未知阶段')));
      expect(
        h.store.secrets[CloudController.workspaceKey],
        isNot(contains('sensitive-secret')),
      );
      expect(h.c.jobs.single.createSubmitted, isFalse);
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
    });
  }

  for (final kind in ['vpc', 'subnet']) {
    testWidgets('Aliyun helper stage is not accepted during $kind lookup', (
      tester,
    ) async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_network_lookup' &&
            (request['aliyun'] as Map)['network_kind'] == kind) {
          throw const UserError('安全组准备：$permission');
        }
        return delegate(request, progress);
      };
      await h.create();
      await tester.pump();
      expect(h.c.jobs.single.error, isNot(contains('安全组准备：')));
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
        isEmpty,
      );
    });
  }

  for (final reason in [
    '仅允许释放本应用创建的普通按量 VPC 云服务器',
    '云服务器关联了独立弹性公网 IP，请先在阿里云控制台核对和处理',
    '云服务器磁盘不符合随实例释放的单系统盘配置，请先在阿里云控制台核对和处理',
    '云服务器网卡配置已改变或不完整，请先在阿里云控制台核对和处理',
    '云服务器仍在变更状态，请稍后查询再释放',
    permission,
  ]) {
    testWidgets('Aliyun release explains exact fixed reason: $reason', (
      tester,
    ) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshCloudMachine(job.id);
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'aliyun_release') throw UserError(reason);
        return delegate(request, progress);
      };
      await h.c.requestCloudRelease(job.id);
      await tester.pump();
      expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releaseFailed);
      expect(h.c.jobs.single.error, contains(reason));
      expect(h.c.jobs.single.error, contains('可能继续计费'));
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      await expectLater(
        h.c.removeCredential(CloudProvider.aliyun),
        throwsA(isA<UserError>()),
      );
    });
  }

  for (final action in ['prepare', 'release']) {
    for (final error in [
      UserError('$permission secret-sensitive-response'),
      UserError('secret-sensitive-response $permission'),
      const UserError('https://secret-sensitive-response.invalid'),
      Exception(permission),
    ]) {
      testWidgets(
        'Aliyun $action rejects untrusted or appended diagnostic text: ${error.runtimeType} ${error.toString().length}',
        (tester) async {
          final h = await harness();
          String? id;
          if (action == 'release') {
            id = (await h.create()).id;
            await tester.pump();
            await h.c.refreshCloudMachine(id);
          }
          final delegate = h.helper.handler!;
          h.helper.handler = (request, progress) async {
            if (request['action'] == 'aliyun_$action') throw error;
            return delegate(request, progress);
          };
          if (action == 'prepare') {
            await h.create();
          } else {
            await h.c.requestCloudRelease(id!);
          }
          await tester.pump();
          final shown = h.c.jobs.single.error;
          expect(shown, isNot(contains(permission)));
          expect(shown, isNot(contains('secret-sensitive-response')));
          expect(
            h.store.secrets[CloudController.workspaceKey],
            isNot(contains('secret-sensitive-response')),
          );
        },
      );
    }
  }
}
