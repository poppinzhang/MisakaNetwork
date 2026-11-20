// Opt-in captures render actual LastOrder widgets with a caller-supplied CJK
// font for docs/使用指南.md. Set USER_GUIDE_FONT and USER_GUIDE_OUTPUT to run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fixnum/fixnum.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

// Synthetic QR PNG encoding "MisakaNetwork Demo QR (Example Only)".
const _demoQrBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAMYAAADGAQAAAACh4MLwAAABoklEQVR4nO1YQW7tIBAzAekvidQDkRv0SNU/Um/AO1AlWFaaJ1ce0rdpu+kmsyiKCEk2lhnbQxLx/bhvP3wA/r4A4NCcSY4GtKwZQLPr2QFHI5lHy+w+c+G067EVAAniyoD3p6Hnuee3UFV1AxrmYfO4CsGXUc57ZXl77kSqTl0IbJtKjh243XdgHpJGpUXBdkspYb7kIRLLPO4ppT0CNnANpyuTVs8XFshDsBByILNrW7cA2KjqMpHWrXZ/lMtZBGyjOTBh07Y6b1H2lI7EtckzHWAhMmvDfCkzSaG1A3jfAV8gjBYoFTRVmid+lKwnUbuKDe2hiDBaACDqVGPVOyXtaQzeBqx2UafNlS7EZAhsBWilgnO3p9ek0B/30jifY2gB6nsHsoyun14XorfEasWXs6nkdCkmLAo2LN4cnksjCG9rjEXdWiAKtqE5y+WUXOuoFcPftmVuOsvM45/jNNxi9L04j6WeDrK1z5d2PbbtsdIJq/4vspFAWQ/xpubtwVscD6E3lqQifvVvYbwX7m9NLaXngrls7Xps6e8fF37D2wefFVeZbCK5qAAAAABJRU5ErkJggg==';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _loadFonts(String fontPath) async {
  final font = FontLoader('Roboto')
    ..addFont(
      Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
    );
  await font.load();
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest) {
    final loader = FontLoader(family['family'] as String);
    for (final entry in family['fonts'] as List) {
      loader.addFont(rootBundle.load(entry['asset'] as String));
    }
    await loader.load();
  }
}

void main() {
  final fontPath = Platform.environment['USER_GUIDE_FONT'];
  final output = Platform.environment['USER_GUIDE_OUTPUT'];

  testWidgets('capture user guide screenshots with actual LastOrder widgets', (
    tester,
  ) async {
    await _loadFonts(fontPath!);

    Future<void> setSize(double width, double height) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(output!);
        await directory.create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    // -------------------------------------------------------------------------
    // Phase 1: First-time workflow (Overview -> Add Machine -> Machines ->
    //          Login QR -> Create Task -> Accounts & Tasks -> Dispatch ->
    //          Monitor & Payment)
    // -------------------------------------------------------------------------
    final store = MemoryStore();
    store.secrets[CloudController.sshIdentityKey] = jsonEncode({
      'private_key':
          '-----BEGIN RSA PRIVATE KEY-----\nDEMO-ONLY\n-----END RSA PRIVATE KEY-----',
      'public_key': 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDemoKeyOnly',
      'fingerprint': 'SHA256:DemoLocalSshKeyFingerprintExample00000000000',
    });

    final deployCompleter = Completer<Map<String, dynamic>>();
    final helper = FakeHelper();
    void Function(DeploymentProgress)? remoteDeployProgress;
    helper.handler = (request, onProgress) async {
      switch (request['action']) {
        case 'init_pki':
          return {};
        case 'verify_cloud_credential':
          return {
            'verified': true,
            'provider': (request['cloud_credential'] as Map)['provider'],
          };
        case 'deploy':
          remoteDeployProgress = onProgress;
          return deployCompleter.future;
      }
      return {'ca_cert': 'ca', 'client_cert': 'cert', 'client_key': 'key'};
    };

    final gateway = FakeGateway();
    var monitorMode = false;
    const taskId = 'demo-task-1';
    final localMachine = Machine(
      id: 'local-mac',
      name: '本机电脑',
      host: '127.0.0.1',
      port: defaultSistersPort,
      caCert: 'ca',
      clientCert: 'cert',
      clientKey: 'key',
    );
    final remoteMachine = Machine(
      id: 'remote-node-a',
      name: '抢票机 A',
      host: '203.0.113.10',
      port: defaultSistersPort,
      caCert: 'ca',
      clientCert: 'cert',
      clientKey: 'key',
    );

    final baseTime = DateTime(2027, 4, 20, 12, 0, 1).millisecondsSinceEpoch;
    gateway.statusHandler = (machine) async {
      final isLocal = machine.id == localMachine.id;
      final tasks = <TaskStatus>[];
      if (monitorMode) {
        if (isLocal) {
          tasks.add(
            TaskStatus(
              id: taskId,
              name: '2027 示例音乐节（上海站）',
              state: TaskState.TASK_STATE_SUCCEEDED,
              message: '已成功锁单，请前往付款（订单 2027042000012345）',
              updatedUnixMs: Int64(baseTime + 2500),
              events: [
                TaskEvent(
                  message: '到达开售时间，开始尝试下单',
                  timestampUnixMs: Int64(baseTime),
                ),
                TaskEvent(
                  message: '已成功锁单，请前往付款（订单 2027042000012345）',
                  timestampUnixMs: Int64(baseTime + 2500),
                ),
              ],
              payment: OrderPayment(
                orderId: '2027042000012345',
                paymentCodeUrl: 'https://qr.alipay.com/demo_example_code_001',
                orderDetailUrl:
                    'https://show.bilibili.com/platform/orderDetail.html?order_id=2027042000012345',
                capturedUnixMs: Int64(baseTime + 2500),
              ),
            ),
          );
        } else if (machine.id == remoteMachine.id) {
          tasks.add(
            TaskStatus(
              id: taskId,
              name: '2027 示例音乐节（上海站）',
              state: TaskState.TASK_STATE_RUNNING,
              message: '正在第 1 轮尝试下单（请求间隔 500 毫秒）…',
              updatedUnixMs: Int64(baseTime + 1800),
              events: [
                TaskEvent(
                  message: '已接收任务，等待开售时间 2027-04-20 12:00:00（北京时间）',
                  timestampUnixMs: Int64(baseTime - 60000),
                ),
                TaskEvent(
                  message: '正在第 1 轮尝试下单（请求间隔 500 毫秒）…',
                  timestampUnixMs: Int64(baseTime + 1800),
                ),
              ],
            ),
          );
        }
      }
      return AgentStatus(
        version: '0.4.4',
        biliVersion: '2.15.18',
        runtimeReady: true,
        platform: isLocal ? 'macos/arm64' : 'linux/amd64',
        maxConcurrency: 2,
        tasks: tasks,
        supportsTimeStart: true,
        supportsRequestInterval: true,
      );
    };

    final runtime = FakeRuntime();
    runtime.responses['qr_start'] = {
      'qrcode_key': 'demo-qr-key',
      'qr_png_base64': _demoQrBase64,
    };
    runtime.responses['qr_poll'] = {'status': 'pending'};
    runtime.responses['login_state'] = {
      'status': 'valid',
      'logged_in': true,
      'username': '御坂示例账号',
      'uid': '100020001',
    };
    runtime.responses['purchase_context'] = {
      'project_id': 90001,
      'project_name': '2027 示例音乐节（上海站）',
      'selected_date': '2027-05-01',
      'ticket_options': [
        {
          'id': 3001,
          'screen_id': 2001,
          'project_id': 90001,
          'screen': '周六场',
          'desc': 'VIP 看台票 ¥680',
          'display': '2027-05-01 周六场 · VIP 看台票 ¥680',
          'sale_start': '2027-04-20 12:00:00',
        },
        {
          'id': 3002,
          'screen_id': 2001,
          'project_id': 90001,
          'screen': '周六场',
          'desc': '普通站票 ¥380',
          'display': '2027-05-01 周六场 · 普通站票 ¥380',
          'sale_start': '2027-04-20 12:00:00',
        },
      ],
      'buyers': [
        {'id': 1, 'name': '张三', 'id_type': 0, 'tel': '13800138000'},
        {'id': 2, 'name': '李四', 'id_type': 1, 'tel': '139****9000'},
      ],
      'addresses': [
        {
          'id': 10,
          'name': '张三',
          'prov': '浙江省',
          'city': '杭州市',
          'area': '西湖区',
        },
      ],
    };
    runtime.responses['build_config'] = {
      'project_id': 90001,
      'screen_id': 2001,
      'sku_id': 3001,
      'buyer': '张三',
      'tel': '13800138000',
      'buyer_info': [
        {'id': 1, 'name': '张三', 'id_type': 0, 'tel': '13800138000'},
      ],
    };
    runtime.responses['payment_qr'] = {'qr_png_base64': _demoQrBase64};

    final c = AppController(
      store: store,
      gateway: gateway,
      runtime: runtime,
      helper: helper,
      accountCheckClock: () => DateTime(2027, 4, 20, 11, 30, 0),
    );
    await c.initialize(poll: false);
    await c.cloud.initialize();

    await setSize(1280, 820);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LastOrderApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final provider in CloudProvider.values) {
        await precacheImage(
          AssetImage('assets/cloud_providers/${provider.name}.png'),
          tester.element(find.byType(LastOrderApp)),
        );
      }
    });
    await tester.pumpAndSettle();

    // 01: Overview page (first-time entry screen)
    await capture('01-overview');

    // 02: Add machine dialog filled with local deployment example (127.0.0.1)
    await tester.tap(find.byTooltip('机器管理'));
    await tester.pumpAndSettle();
    await setSize(1280, 1220);
    await tester.tap(find.text('添加机器'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('机器名称'), '本机电脑');
    await tester.enterText(_field('主机地址'), '127.0.0.1');
    await tester.enterText(_field('SSH 用户名'), 'your-username');
    await tester.enterText(_field('SSH 密码（与私钥二选一，不保存）'), 'demo-password');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await capture('02-add-machine-dialog');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 03: Machines list with one online local machine + one deploying remote
    await setSize(1280, 800);
    await c.addMachine(localMachine);
    await c.refresh();
    await c.startDeployment(
      name: '抢票机 A',
      host: '203.0.113.10',
      port: defaultSistersPort,
      request: {
        'host': '203.0.113.10',
        'port': 22,
        'username': 'ubuntu',
        'password': 'demo-password',
        'grpc_port': defaultSistersPort,
      },
    );
    await tester.pump();
    remoteDeployProgress?.call(
      const DeploymentProgress(percent: 64, stage: '上传并解压安装包'),
    );
    await tester.pump();
    await capture('03-machines-list');

    // Finish background deployment cleanly before continuing.
    deployCompleter.complete({
      'ca_cert': 'ca',
      'client_cert': 'cert',
      'client_key': 'key',
    });
    await tester.pumpAndSettle();
    final deployedRemote = c.currentMachines.firstWhere(
      (m) => m.host == '203.0.113.10',
    );
    await c.removeMachine(deployedRemote);
    await c.addMachine(remoteMachine);
    await c.refresh();
    await tester.pumpAndSettle();

    // 04: Login QR dialog (decode and paint the MemoryImage before capturing)
    await tester.tap(find.byTooltip('账号与任务'));
    await tester.pumpAndSettle();
    await setSize(1280, 820);
    await tester.tap(find.text('添加账号'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final qrImageFinder = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Image),
    );
    expect(qrImageFinder, findsOneWidget);
    final qrImage = tester.widget<Image>(qrImageFinder);
    await tester.runAsync(
      () => precacheImage(qrImage.image, tester.element(qrImageFinder)),
    );
    await tester.pump();
    await capture('04-login-qr-dialog');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // Add demo account into controller so we can create a task
    await c.addAccount('御坂示例账号', [
      {'name': 'SESSDATA', 'value': 'demo-cookie'},
    ], uid: '100020001');
    await tester.pumpAndSettle();

    // 05: Create Task dialog (loaded project, selected buyer & autofilled contact)
    await setSize(1280, 1180);
    await tester.tap(find.text('创建任务'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _field('演出 ID 或会员购链接'),
      'https://show.bilibili.com/platform/detail.html?id=90001',
    );
    await tester.tap(find.text('读取演出与购票人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('张三（身份证）'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await capture('05-create-task-dialog');
    await tester.tap(find.text('保存任务'));
    await tester.pumpAndSettle();

    // 06: Accounts & Tasks page showing logged-in account + created task card
    await setSize(1280, 980);
    await capture('06-accounts-and-tasks');

    // 07: Dispatch dialog with local machine checked
    await tester.ensureVisible(find.text('分发'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分发'));
    await tester.pumpAndSettle();
    await setSize(1280, 860);
    await tester.tap(
      find.byKey(ValueKey('dispatch-machine-${localMachine.id}')),
    );
    await tester.pumpAndSettle();
    await capture('07-dispatch-dialog');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 08: Task Monitor with Order & Payment card + succeeded/running executions
    final createdTask = c.state.tasks.single;
    final linkedTask = TicketTask(
      id: taskId,
      name: createdTask.name,
      accountId: createdTask.accountId,
      startAt: createdTask.startAt,
      requestIntervalMs: createdTask.requestIntervalMs,
      summary: createdTask.summary,
      dispatches: [
        TaskDispatch(
          machineId: localMachine.id,
          executionId: taskId,
          finished: true,
        ),
        TaskDispatch(
          machineId: remoteMachine.id,
          executionId: taskId,
          finished: false,
        ),
      ],
    );
    store.state = SavedState(
      machines: [localMachine, remoteMachine],
      accounts: c.state.accounts,
      tasks: [linkedTask],
    );
    monitorMode = true;
    await c.initialize(poll: false);
    await c.refresh();
    await setSize(1280, 920);
    await tester.tap(find.byTooltip('任务监控'));
    await tester.pumpAndSettle();
    await capture('08-task-monitor-payment');

    // -------------------------------------------------------------------------
    // Phase 2: Public Cloud workflow (Credentials -> Template Selection ->
    //          Cloud Machine Cards)
    // -------------------------------------------------------------------------
    await setSize(1280, 960);
    await tester.tap(find.byTooltip('公有云部署'));
    await tester.pumpAndSettle();
    // 09: Public cloud credentials page (Tencent Cloud selected by default)
    await capture('09-cloud-credentials');

    await c.cloud.saveCredential(
      CloudProvider.tencent,
      accessKeyId: 'AKIDDemoExample123456789',
      accessKeySecret: 'DemoSecretExample123456789',
    );
    await c.cloud.saveCredential(
      CloudProvider.aliyun,
      accessKeyId: 'LTAI5tDemoExample123456',
      accessKeySecret: 'DemoAliyunSecret123456',
    );
    await tester.pumpAndSettle();

    // 10: Cloud creation dialog step 2 (template selected with summary)
    await setSize(1280, 940);
    await tester.tap(find.text('创建云服务器'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cloud-select-provider-tencent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cloud-template-t-shanghai-ubuntu-2c2g')),
    );
    await tester.pumpAndSettle();
    await capture('10-cloud-create-dialog');
    await tester.tap(find.byTooltip('关闭创建云服务器'));
    await tester.pumpAndSettle();

    // 11: Unified Cloud Machine Cards in Machines page (one ready to deploy,
    //     one already deployed and online)
    final tencentTemplate = c.cloud.templatesFor(CloudProvider.tencent).first;
    final aliyunTemplate = c.cloud.templatesFor(CloudProvider.aliyun).first;
    final tencentJob = CloudMachine(
      id: 'demo-tencent-1',
      name: '腾讯云 · 上海 2核2G Linux 服务器',
      provider: CloudProvider.tencent,
      template: tencentTemplate,
      phase: CloudMachinePhase.created,
      isReal: true,
      createSubmitted: true,
      instanceId: 'ins-demo0001',
      publicIp: '203.0.113.25',
      region: 'ap-shanghai',
      credentialId: 'AKIDDemoExample123456789',
      clientToken: 'demo-token-1',
    );
    final aliyunJob = CloudMachine(
      id: 'demo-aliyun-1',
      name: '阿里云 · 上海 2核2G Linux 服务器',
      provider: CloudProvider.aliyun,
      template: aliyunTemplate,
      phase: CloudMachinePhase.created,
      isReal: true,
      createSubmitted: true,
      instanceId: 'i-demo0002',
      publicIp: '203.0.113.26',
      region: 'cn-shanghai',
      credentialId: 'LTAI5tDemoExample123456',
      clientToken: 'demo-token-2',
    );
    final linkedAliyunSisters = Machine(
      id: 'aliyun-demo-aliyun-1',
      name: '阿里云 · 上海 2核2G Linux 服务器',
      host: '203.0.113.26',
      port: defaultSistersPort,
      caCert: 'ca',
      clientCert: 'cert',
      clientKey: 'key',
    );

    final cloudStore = MemoryStore();
    cloudStore.secrets[CloudController.sshIdentityKey] =
        store.secrets[CloudController.sshIdentityKey]!;
    cloudStore.secrets[CloudController.workspaceKey] = jsonEncode({
      'version': 1,
      'credentials': [
        {
          'provider': 'tencent',
          'accessKeyId': 'AKIDDemoExample123456789',
          'accessKeySecret': 'DemoSecretExample123456789',
          'checkedAt': '2027-04-20T04:00:00Z',
          'onlineVerified': true,
        },
        {
          'provider': 'aliyun',
          'accessKeyId': 'LTAI5tDemoExample123456',
          'accessKeySecret': 'DemoAliyunSecret123456',
          'checkedAt': '2027-04-20T04:00:00Z',
          'onlineVerified': true,
        },
      ],
      'jobs': [aliyunJob.toJson(), tencentJob.toJson()],
      'networks': [],
    });
    cloudStore.state = SavedState(machines: [linkedAliyunSisters]);

    final cloudGateway = FakeGateway()
      ..statusHandler = (_) async => AgentStatus(
        version: '0.4.4',
        biliVersion: '2.15.18',
        runtimeReady: true,
        platform: 'linux/amd64',
        maxConcurrency: 2,
        supportsTimeStart: true,
        supportsRequestInterval: true,
      );

    final c2 = AppController(
      store: cloudStore,
      gateway: cloudGateway,
      runtime: runtime,
      helper: helper,
    );
    await c2.initialize(poll: false);
    await c2.cloud.initialize();
    await c2.refresh();

    await setSize(1280, 880);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LastOrderApp(controller: c2),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final provider in CloudProvider.values) {
        await precacheImage(
          AssetImage('assets/cloud_providers/${provider.name}.png'),
          tester.element(find.byType(LastOrderApp)),
        );
      }
    });
    await tester.tap(find.byTooltip('机器管理'));
    await tester.pumpAndSettle();
    await capture('11-cloud-machine-card');

    await tester.pumpWidget(const SizedBox.shrink());
    c2.dispose();
    c.dispose();
  }, skip: fontPath == null || output == null);
}
