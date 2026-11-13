import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'desktop dashboard and four navigation pages have real empty states',
    (tester) async {
      tester.view.physicalSize = const Size(1360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('让每个节点，协同工作'), findsOneWidget);
      await tester.tap(find.text('机器管理').first);
      await tester.pumpAndSettle();
      expect(find.text('还没有 Sisters'), findsOneWidget);
      await tester.tap(find.text('账号与任务').first);
      await tester.pumpAndSettle();
      expect(find.text('还没有登录账号'), findsOneWidget);
      expect(find.text('暂无抢票任务'), findsOneWidget);
      await tester.tap(find.text('任务监控').first);
      await tester.pumpAndSettle();
      expect(find.text('暂无可显示的执行记录'), findsOneWidget);
    },
  );
  testWidgets('compact desktop navigation has no overflow', (tester) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = controller();
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();
  });
  const statisticLabels = ['在线 Sisters', '抢票任务', '执行中 / 排队', '登录账号'];
  const statisticCaptions = [
    '共 0 台机器',
    '可分发到多个节点',
    '以最近一次同步为准',
    'Cookie 保存于安全存储',
  ];
  for (final width in [320.0, 390.0]) {
    for (final textScale in [1.0, 1.3]) {
      testWidgets(
        'Android $width statistics use two columns at text scale $textScale',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final c = controller();
          await c.initialize(poll: false);
          addTearDown(c.dispose);
          await tester.pumpWidget(LastOrderApp(controller: c));
          await tester.pumpAndSettle();

          final cards = [
            for (final label in statisticLabels)
              tester.getRect(
                find.ancestor(
                  of: find.text(label),
                  matching: find.byType(Card),
                ),
              ),
          ];
          expect(cards[0].top, cards[1].top);
          expect(cards[2].top, cards[3].top);
          expect(cards[0].left, cards[2].left);
          expect(cards[1].left, cards[3].left);
          expect(cards[1].left, greaterThan(cards[0].right));
          expect(cards[2].top, greaterThan(cards[0].bottom));
          expect(cards[2].top, greaterThan(cards[1].bottom));
          final navigationTop = tester
              .getTopLeft(find.byType(NavigationBar))
              .dy;
          for (var i = 0; i < cards.length; i++) {
            expect(cards[i].width, closeTo(cards.first.width, .01));
            expect(cards[i].left, greaterThanOrEqualTo(0));
            expect(cards[i].right, lessThanOrEqualTo(width));
            expect(cards[i].bottom, lessThan(navigationTop));
            expect(find.text(statisticLabels[i]).hitTestable(), findsOneWidget);
            final caption = find.text(statisticCaptions[i]);
            expect(caption.hitTestable(), findsOneWidget);
            expect(
              tester.getBottomRight(caption).dy,
              lessThan(cards[i].bottom),
            );
          }
          if (width == 390 && textScale == 1) {
            expect(find.text('开始连接御坂网络').hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final layout in [(1360.0, 4), (800.0, 2), (390.0, 1)]) {
      testWidgets(
        '${platform.name} ${layout.$1} retains ${layout.$2} statistic columns',
        (tester) async {
          tester.view.physicalSize = Size(layout.$1, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = controller();
          await c.initialize(poll: false);
          addTearDown(c.dispose);
          await tester.pumpWidget(LastOrderApp(controller: c));
          await tester.pumpAndSettle();

          final cards = [
            for (final label in statisticLabels)
              tester.getRect(
                find.ancestor(
                  of: find.text(label),
                  matching: find.byType(Card),
                ),
              ),
          ];
          final columns = layout.$2;
          for (var i = 0; i < cards.length; i++) {
            expect(cards[i].width, closeTo(cards.first.width, .01));
            expect(cards[i].top, cards[(i ~/ columns) * columns].top);
            if (i % columns != 0) {
              expect(cards[i].left, greaterThan(cards[i - 1].right));
            }
            if (i >= columns) {
              expect(cards[i].left, cards[i - columns].left);
              expect(cards[i].top, greaterThan(cards[i - columns].bottom));
            }
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
  for (final width in [320.0, 390.0]) {
    testWidgets('phone $width supports navigation and populated task cards', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller();
      await c.initialize(poll: false);
      final account = await c.addAccount('测试账号', [
        {'name': 'session', 'value': 'synthetic'},
      ], uid: '123');
      await c.addTask('很长的演出任务名称，用于验证手机上的自动换行', account, {
        'ticket': {'id': 1},
      });
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final title in ['机器管理', '账号与任务', '任务监控']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(title),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
  testWidgets('quitting during a deploy asks first and can be cancelled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = controller();
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(find.text('部署仍在进行'), findsNothing);
    c.deploying = 1;
    var response = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('部署仍在进行'), findsOneWidget);
    await tester.tap(find.text('继续等待'));
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.cancel);
    response = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然退出'));
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
  });
  testWidgets('dispatch dialog disables machines that already hold the task', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore()
      ..state = SavedState(machines: [machine('a'), machine('b')]);
    final c = controller(store: store);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    final account = await c.addAccount('测试账号', [
      {'name': 'session', 'value': 'synthetic'},
    ], uid: '123');
    final task = await c.addTask('演出', account, {});
    await c.dispatch(task, [machine('a')]);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号与任务').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分发'));
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(tiles.map((t) => t.onChanged == null), [true, false]);
    expect(find.text('node.example:20001 · 执行未结束或结果待确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('phone dialogs stay usable with the soft keyboard visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final c = controller();
    await c.initialize(poll: false);
    await c.addAccount('测试账号', [
      {'name': 'session', 'value': 'synthetic'},
    ], uid: '123');
    addTearDown(c.dispose);
    for (final dialog in [
      MachineDialog(controller: c),
      LoginDialog(controller: c),
      TaskDialog(controller: c),
    ]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: dialog)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('关闭'), findsOneWidget);
    }
  });
  testWidgets('manual machine dialog requires credentials before saving', (
    tester,
  ) async {
    final c = controller();
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MachineDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全部署'));
    await tester.pumpAndSettle();
    expect(find.text('请填写机器名称和主机地址。'), findsOneWidget);
    expect(c.state.machines, isEmpty);
  });
  testWidgets('a deployment this device cannot reach warns about the port', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = controller(helper: FakeHelper()..reachable = false);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('机器管理').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加机器'));
    await tester.pumpAndSettle();
    Finder labelled(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    await tester.enterText(labelled('机器名称'), '节点 x');
    await tester.enterText(labelled('主机地址'), 'node.example');
    await tester.enterText(labelled('SSH 用户'), 'ticket');
    await tester.enterText(labelled('SSH 密码（仅用于本次部署）'), 'secret');
    await tester.tap(find.text('安全部署'));
    await tester.pumpAndSettle();
    expect(c.state.machines.single.name, '节点 x');
    expect(find.textContaining('本机无法直接连接 node.example:20001'), findsOneWidget);
    expect(find.textContaining('防火墙或安全组'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });
  testWidgets('a duplicate machine name is rejected before deploying', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final helper = FakeHelper();
    final c = controller(
      store: MemoryStore()..state = SavedState(machines: [machine('a')]),
      helper: helper,
    );
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MachineDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    Finder labelled(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    await tester.enterText(labelled('机器名称'), '节点 a');
    await tester.enterText(labelled('主机地址'), 'other.example');
    await tester.enterText(labelled('SSH 用户'), 'ticket');
    await tester.enterText(labelled('SSH 密码（仅用于本次部署）'), 'secret');
    await tester.tap(find.text('安全部署'));
    await tester.pumpAndSettle();
    expect(find.text('机器名称已存在，请使用不同的名称。'), findsOneWidget);
    expect(helper.requests, isEmpty);
    expect(c.state.machines, hasLength(1));
  });
  testWidgets('cookie login validates malformed input and never saves it', (
    tester,
  ) async {
    final c = controller();
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoginDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-json');
    await tester.tap(find.text('验证并保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 JSON Cookie 数组'), findsOneWidget);
    expect(c.state.accounts, isEmpty);
  });
  testWidgets('task creation requires a project before runtime call', (
    tester,
  ) async {
    final store = MemoryStore()
      ..state = SavedState(
        accounts: [Account(id: 'a', name: '测试账号', uid: '123')],
      );
    final c = controller(store: store);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TaskDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取演出与购票人'));
    await tester.pumpAndSettle();
    expect(find.text('请填写演出 ID 或会员购链接。'), findsOneWidget);
    expect(c.state.tasks, isEmpty);
  });
  testWidgets('QR confirmation saves only confirmed cookies', (tester) async {
    final runtime = FakeRuntime();
    runtime.responses['qr_start'] = {'qrcode_key': 'test-qr'};
    runtime.responses['qr_poll'] = {
      'status': 'confirmed',
      'uid': '123',
      'username': '测试账号',
      'cookies': [
        {'name': 'session', 'value': 'test-secret'},
      ],
    };
    final store = MemoryStore();
    final c = controller(store: store, runtime: runtime);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoginDialog(controller: c)),
      ),
    );
    await tester.tap(find.text('生成二维码'));
    await tester.pumpAndSettle();
    expect(c.state.accounts, isEmpty);
    await tester.tap(find.text('检测登录'));
    await tester.pumpAndSettle();
    expect(c.state.accounts.single.name, '测试账号');
    expect(store.secrets.values.single, contains('test-secret'));
  });
  testWidgets('unknown cookie validation preserves the existing login', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    runtime.responses['login_cookie'] = {
      'status': 'unknown',
      'logged_in': false,
    };
    final store = MemoryStore();
    final c = controller(store: store, runtime: runtime);
    await c.initialize(poll: false);
    final account = await c.addAccount('原账号', [
      {'name': 'session', 'value': 'old-secret'},
    ], uid: '123');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginDialog(controller: c, account: account),
        ),
      ),
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '[{"name":"session","value":"candidate"}]',
    );
    await tester.tap(find.text('验证并保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂时无法验证登录状态'), findsOneWidget);
    expect(c.state.accounts.single.id, account.id);
    expect(store.secrets['account.${account.id}'], contains('old-secret'));
  });
  testWidgets('QR relogin updates the original account and preserves tasks', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    runtime.responses['qr_start'] = {'qrcode_key': 'test-qr'};
    runtime.responses['qr_poll'] = {
      'status': 'confirmed',
      'uid': '123',
      'username': '更新后的昵称',
      'cookies': [
        {'name': 'session', 'value': 'new-secret'},
      ],
    };
    final store = MemoryStore();
    final c = controller(store: store, runtime: runtime);
    await c.initialize(poll: false);
    final account = await c.addAccount('原账号', [
      {'name': 'session', 'value': 'old-secret'},
    ], uid: '123');
    final task = await c.addTask('已选场次', account, {
      'ticket': {'id': 1},
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginDialog(controller: c, account: account),
        ),
      ),
    );
    expect(find.text('重新登录账号'), findsOneWidget);
    await tester.tap(find.text('生成二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测登录'));
    await tester.pumpAndSettle();
    expect(c.state.accounts.single.id, account.id);
    expect(c.state.accounts.single.name, '更新后的昵称');
    expect(c.state.tasks.single.id, task.id);
    expect(c.state.tasks.single.accountId, account.id);
    expect(store.secrets['account.${account.id}'], contains('new-secret'));
    expect(
      store.secrets['account.${account.id}'],
      isNot(contains('old-secret')),
    );
  });
  testWidgets('QR relogin rejects a different verified account', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    runtime.responses['qr_start'] = {'qrcode_key': 'test-qr'};
    runtime.responses['qr_poll'] = {
      'status': 'confirmed',
      'uid': '456',
      'username': '另一个账号',
      'cookies': [
        {'name': 'session', 'value': 'wrong-account'},
      ],
    };
    final store = MemoryStore();
    final c = controller(store: store, runtime: runtime);
    await c.initialize(poll: false);
    final account = await c.addAccount('原账号', [
      {'name': 'session', 'value': 'old-secret'},
    ], uid: '123');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginDialog(controller: c, account: account),
        ),
      ),
    );
    await tester.tap(find.text('生成二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测登录'));
    await tester.pumpAndSettle();
    expect(find.text('重新登录账号'), findsOneWidget);
    expect(c.state.accounts.single.uid, '123');
    expect(store.secrets['account.${account.id}'], contains('old-secret'));
    expect(store.secrets.values.join(), isNot(contains('wrong-account')));
  });
  testWidgets('expired account has a relogin action in compact layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore()
      ..state = SavedState(
        accounts: [
          Account(
            id: 'a',
            name: '原账号',
            uid: '123',
            authStatus: AccountAuthStatus.expired,
          ),
        ],
      );
    final c = controller(store: store);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('账号与任务').first);
    await tester.pumpAndSettle();
    expect(find.text('登录失效'), findsOneWidget);
    expect(find.text('请重新扫码登录，恢复任务分发。'), findsOneWidget);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(find.text('重新登录账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('expired login blocks ticket query and offers relogin', (
    tester,
  ) async {
    final runtime = FakeRuntime();
    runtime.responses['login_state'] = {
      'status': 'expired',
      'logged_in': false,
      'uid': '',
    };
    final c = controller(runtime: runtime);
    await c.initialize(poll: false);
    await c.addAccount('原账号', [
      {'name': 'session', 'value': 'expired'},
    ], uid: '123');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TaskDialog(controller: c)),
      ),
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '演出 ID 或会员购链接',
      ),
      '1234',
    );
    await tester.tap(find.text('读取演出与购票人'));
    await tester.pumpAndSettle();
    expect(c.state.accounts.single.authStatus, AccountAuthStatus.expired);
    expect(runtime.calls, isNot(contains('purchase_context')));
    expect(find.text('重新登录此账号'), findsOneWidget);
  });
  testWidgets(
    'task wizard validates buyer selection then saves a complete configuration',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = FakeRuntime();
      runtime.responses['purchase_context'] = {
        'project_name': '测试演出',
        'selected_date': '2026-11-28',
        'ticket_options': [
          {
            'display': '测试场次 / 票档',
            'screen': '周六晚场',
            'desc': '前排票',
            'sale_start': '2026-11-20 20:00:00',
          },
        ],
        'buyers': [
          {'name': '测试购票人'},
        ],
        'addresses': [
          {'name': '测试地址', 'city': '测试城市'},
        ],
      };
      runtime.responses['build_config'] = {
        'ticket': {'id': 1},
      };
      final c = controller(runtime: runtime);
      await c.initialize(poll: false);
      await c.addAccount('测试账号', [
        {'name': 'session', 'value': 'test'},
      ], uid: '123');
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TaskDialog(controller: c)),
        ),
      );
      final project = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '演出 ID 或会员购链接',
      );
      await tester.enterText(project, '1234');
      await tester.tap(find.text('读取演出与购票人'));
      await tester.pumpAndSettle();
      final start = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '开售时间（北京时间）',
      );
      expect(
        tester.widget<TextField>(start).controller!.text,
        '2026-11-20 20:00:00',
      );
      final interval = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '抢票请求间隔（毫秒）',
      );
      expect(tester.widget<TextField>(interval).controller!.text, '1000');
      expect(
        tester.widget<TextField>(interval).keyboardType,
        TextInputType.number,
      );
      expect(find.textContaining('每轮下单最多尝试 40 次'), findsOneWidget);
      await tester.tap(find.text('保存任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请至少选择一位购票人'), findsOneWidget);
      expect(runtime.calls, isNot(contains('build_config')));
      await tester.tap(find.text('测试购票人'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '联系人（必填）',
        ),
        '测试联系人',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '联系电话（必填）',
        ),
        '13800000000',
      );
      await tester.enterText(start, '20:00');
      await tester.tap(find.text('保存任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('开售时间应为北京时间'), findsOneWidget);
      expect(runtime.calls, isNot(contains('build_config')));
      await tester.enterText(start, '2026-11-20 20:00');
      for (final value in ['', '99', '60001', '100.5', 'abc']) {
        await tester.ensureVisible(interval);
        await tester.enterText(interval, value);
        await tester.tap(find.text('保存任务'));
        await tester.pumpAndSettle();
        expect(find.text(requestIntervalError), findsOneWidget);
        expect(runtime.calls, isNot(contains('build_config')));
        expect(c.state.tasks, isEmpty);
      }
      await tester.ensureVisible(interval);
      await tester.enterText(interval, '750');
      await tester.tap(find.text('保存任务'));
      await tester.pumpAndSettle();
      expect(c.state.tasks.single.name, '测试演出');
      expect(c.state.tasks.single.startAt, '2026-11-20T20:00:00');
      expect(c.state.tasks.single.requestIntervalMs, 750);
      final summary = c.state.tasks.single.summary!;
      expect(summary.projectName, '测试演出');
      expect(summary.screenName, '周六晚场');
      expect(summary.ticketName, '前排票');
      expect(summary.selectedDate, '2026-11-28');
      expect(summary.quantity, 1);
      expect(
        runtime.calls,
        containsAllInOrder(['purchase_context', 'build_config', 'validate']),
      );
    },
  );
}
