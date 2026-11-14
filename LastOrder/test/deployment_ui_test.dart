import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

class _DeploymentCall {
  _DeploymentCall(this.request, this.progress);
  final Map<String, dynamic> request;
  final void Function(DeploymentProgress)? progress;
  final result = Completer<Map<String, dynamic>>();
}

class _Deployments {
  _Deployments() {
    helper.handler = (request, progress) async {
      if (request['action'] != 'deploy') return credentials;
      final call = _DeploymentCall(Map.of(request), progress);
      calls.add(call);
      return call.result.future;
    };
  }

  static const credentials = <String, dynamic>{
    'ca_cert': 'ca',
    'client_cert': 'cert',
    'client_key': 'key',
  };
  final helper = FakeHelper();
  final calls = <_DeploymentCall>[];
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _card(String id) => find.byKey(ValueKey('machine-card-$id'));

Future<AppController> _openMachines(
  WidgetTester tester,
  _Deployments deployments, {
  double width = 1360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = controller(helper: deployments.helper);
  await c.initialize(poll: false);
  addTearDown(c.dispose);
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(
    width >= 600 ? find.byTooltip('机器管理') : find.text('机器管理').first,
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _submitMachine(
  WidgetTester tester, {
  required String name,
  required String host,
}) async {
  await tester.tap(find.text('添加机器'));
  await tester.pumpAndSettle();
  await tester.enterText(_field('机器名称'), name);
  await tester.enterText(_field('主机地址'), host);
  await tester.enterText(_field('SSH 用户'), 'deploy-user');
  await tester.enterText(_field('SSH 密码（仅用于本次部署）'), 'synthetic-password');
  await tester.tap(find.text('安全部署'));
  await tester.pumpAndSettle();
}

Future<void> _startMachine(AppController c, {String name = '测试部署节点'}) =>
    c.startDeployment(
      name: name,
      host: '192.0.2.10',
      port: defaultSistersPort,
      request: {
        'host': '192.0.2.10',
        'port': 22,
        'username': 'deploy-user',
        'password': 'synthetic-password',
        'grpc_port': defaultSistersPort,
      },
    );

void main() {
  testWidgets('Windows deployment explains setup and reports its platform', (
    tester,
  ) async {
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    (c.gateway as FakeGateway).statusHandler = (_) async => AgentStatus(
      version: '0.4.0',
      runtimeReady: true,
      platform: 'windows/amd64',
      maxConcurrency: 2,
    );
    expect(find.textContaining('支持 Windows 10+ x64'), findsOneWidget);
    await tester.tap(find.text('添加机器'));
    await tester.pumpAndSettle();
    expect(find.textContaining('具有管理员权限的 SSH 账号'), findsOneWidget);
    await tester.enterText(_field('机器名称'), 'Windows 执行节点');
    await tester.enterText(_field('主机地址'), '192.0.2.20');
    await tester.enterText(_field('SSH 用户'), 'deploy-user');
    await tester.enterText(_field('SSH 密码（仅用于本次部署）'), 'synthetic-password');
    await tester.tap(find.text('安全部署'));
    await tester.pumpAndSettle();
    deployments.calls.single.result.complete({
      ..._Deployments.credentials,
      'platform': 'windows',
      'arch': 'amd64',
      'reachable': true,
    });
    await tester.pumpAndSettle();
    expect(c.statuses[c.state.machines.single.id]?.platform, 'windows/amd64');
    expect(find.text('windows/amd64'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('secure deployment closes the form and permits a second host', (
    tester,
  ) async {
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    await _submitMachine(tester, name: '节点一', host: '192.0.2.10');

    expect(find.byType(MachineDialog), findsNothing);
    expect(c.state.machines, hasLength(1));
    expect(deployments.calls, hasLength(1));
    expect(find.text('部署 Sisters'), findsOneWidget);
    expect(find.text('添加机器').hitTestable(), findsOneWidget);
    final first = c.state.machines.single;
    deployments.calls.single.progress?.call(
      const DeploymentProgress(percent: 62, stage: '上传安装包'),
    );
    await tester.pumpAndSettle();
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('上传安装包'), findsOneWidget);

    await _submitMachine(tester, name: '节点二', host: '192.0.2.11');
    expect(find.byType(MachineDialog), findsNothing);
    expect(c.state.machines, hasLength(2));
    expect(deployments.calls, hasLength(2));
    expect(find.text('部署 Sisters'), findsNWidgets(2));
    expect(
      find.descendant(of: _card(first.id), matching: find.text('62%')),
      findsOneWidget,
    );
    deployments.calls.last.result.complete(_Deployments.credentials);
    await tester.pumpAndSettle();
    expect(find.text('部署 Sisters'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a duplicate IP is rejected while its first deploy is active', (
    tester,
  ) async {
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    await _submitMachine(tester, name: '节点一', host: '192.0.2.10');
    await _submitMachine(tester, name: '重复地址', host: '192.0.2.10');

    expect(find.byType(MachineDialog), findsOneWidget);
    expect(c.state.machines, hasLength(1));
    expect(deployments.calls, hasLength(1));
    expect(find.textContaining('该 IP 或主机地址已在机器列表中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first host identity is remembered without an approval step', (
    tester,
  ) async {
    const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    await _submitMachine(tester, name: '自动部署节点', host: '192.0.2.10');
    deployments.calls.single.result.complete({
      'needs_confirmation': true,
      'fingerprint': fingerprint,
    });
    await tester.pumpAndSettle();

    expect(find.text('确认 SSH 主机指纹'), findsNothing);
    expect(find.text('核对 SSH 指纹'), findsNothing);
    expect(find.text('取消部署'), findsNothing);
    expect(find.text(fingerprint), findsNothing);
    expect(deployments.calls, hasLength(2));
    expect(deployments.calls.last.request['host_key_fingerprint'], fingerprint);
    expect(c.state.machines.single.fingerprint, fingerprint);
    deployments.calls.last.result.complete(_Deployments.credentials);
    await tester.pumpAndSettle();
    expect(c.state.machines.single.canConnect, isTrue);
    expect(find.text('部署 Sisters'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a changed host identity fails visibly without replacing its pin',
    (tester) async {
      const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final deployments = _Deployments();
      final c = await _openMachines(tester, deployments);
      await _submitMachine(tester, name: '身份变化节点', host: '192.0.2.10');
      final id = c.state.machines.single.id;
      deployments.calls.single.result.complete({
        'needs_confirmation': true,
        'fingerprint': fingerprint,
      });
      await tester.pumpAndSettle();
      deployments.calls.last.result.completeError(
        const UserError('SSH 主机指纹不匹配，连接已停止。'),
      );
      await tester.pumpAndSettle();

      expect(deployments.calls, hasLength(2));
      expect(c.state.machines.single.id, id);
      expect(c.state.machines.single.fingerprint, fingerprint);
      expect(c.state.machines.single.canConnect, isFalse);
      expect(find.text('部署失败'), findsOneWidget);
      expect(find.text('SSH 主机指纹不匹配，连接已停止。'), findsOneWidget);
      expect(find.text('重试部署'), findsOneWidget);
      expect(find.text('移除连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed deployment retries the same machine from its card', (
    tester,
  ) async {
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    await _submitMachine(tester, name: '可重试节点', host: '192.0.2.10');
    final id = c.state.machines.single.id;
    deployments.calls.single.result.completeError(const UserError('测试连接失败'));
    await tester.pumpAndSettle();
    expect(find.text('部署失败'), findsOneWidget);
    expect(find.text('测试连接失败'), findsOneWidget);

    await tester.tap(find.text('重试部署'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MachineDialog>(find.byType(MachineDialog)).existing?.id,
      id,
    );
    expect(
      tester.widget<TextField>(_field('主机地址')).controller?.text,
      '192.0.2.10',
    );
    expect(
      tester.widget<TextField>(_field('SSH 密码（仅用于本次部署）')).controller?.text,
      isEmpty,
    );
    await tester.enterText(_field('SSH 用户'), 'deploy-user');
    await tester.enterText(_field('SSH 密码（仅用于本次部署）'), 'new-synthetic-password');
    await tester.tap(find.text('安全部署'));
    await tester.pumpAndSettle();

    expect(c.state.machines.single.id, id);
    expect(deployments.calls, hasLength(2));
    expect(find.byType(MachineDialog), findsNothing);
    expect(find.text('部署 Sisters'), findsOneWidget);
    expect(find.text('测试连接失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final layout in [
    (320.0, 1.0),
    (320.0, 2.0),
    (390.0, 2.0),
    (900.0, 2.0),
  ]) {
    testWidgets(
      'deployment progress fits width ${layout.$1} scale ${layout.$2}',
      (tester) async {
        final deployments = _Deployments();
        final c = await _openMachines(
          tester,
          deployments,
          width: layout.$1,
          textScale: layout.$2,
        );
        await _startMachine(c, name: '用于验证窄屏和大字体换行的部署节点名称');
        await tester.pumpAndSettle();
        deployments.calls.single.progress?.call(
          const DeploymentProgress(percent: 86, stage: '检查 Sisters 与内嵌运行时'),
        );
        await tester.pumpAndSettle();

        final card = tester.getRect(_card(c.state.machines.single.id));
        expect(find.text('86%'), findsOneWidget);
        expect(find.text('检查 Sisters 与内嵌运行时'), findsOneWidget);
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(layout.$1));
        for (final label in ['部署 Sisters', '86%', '检查 Sisters 与内嵌运行时']) {
          final text = tester.getRect(find.text(label));
          expect(text.left, greaterThanOrEqualTo(card.left));
          expect(text.right, lessThanOrEqualTo(card.right));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('pending deployments cannot be selected for task dispatch', (
    tester,
  ) async {
    final deployments = _Deployments();
    final c = await _openMachines(tester, deployments);
    await _startMachine(c);
    final account = await c.addAccount('测试账号', [
      {'name': 'session', 'value': 'synthetic'},
    ], uid: '123');
    await c.addTask('测试任务', account, {});
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('账号与任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分发'));
    await tester.pumpAndSettle();

    final tile = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
