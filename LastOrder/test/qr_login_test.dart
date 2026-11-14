import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/login_dialog.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Map<String, dynamic> confirmed({String uid = '123'}) => {
  'status': 'confirmed',
  'uid': uid,
  'username': '测试账号',
  'cookies': [
    {'name': 'session', 'value': 'synthetic-qr-secret'},
  ],
};

Future<({AppController c, FakeRuntime runtime, MemoryStore store})> mountLogin(
  WidgetTester tester, {
  FakeRuntime? runtime,
  MemoryStore? store,
  Account? account,
  AppLifecycleState openedIn = AppLifecycleState.resumed,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final r = runtime ?? FakeRuntime();
  r.responses.putIfAbsent('qr_start', () => testQrStart);
  r.responses.putIfAbsent('qr_poll', () => {'status': 'pending'});
  final s = store ?? MemoryStore();
  final c = controller(runtime: r, store: s);
  await c.initialize(poll: false);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => LoginDialog(controller: c, account: account),
            ),
            child: const Text('打开登录'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开登录'));
  // The lifecycle can change between the tap and the dialog's first build.
  switch (openedIn) {
    case AppLifecycleState.resumed:
      break;
    case AppLifecycleState.inactive:
      tester.binding.handleAppLifecycleStateChanged(openedIn);
    default:
      pauseApp(tester);
  }
  await tester.pump();
  await tester.pump();
  return (c: c, runtime: r, store: s);
}

Finder qrButton() => find.widgetWithText(TextButton, '重新生成二维码');

int polls(FakeRuntime runtime) =>
    runtime.calls.where((op) => op == 'qr_poll').length;

void pauseApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void resumeApp(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'generates on open, polls every two seconds, saves once and closes',
    (tester) async {
      final f = await mountLogin(tester);
      expect(f.runtime.calls, ['qr_start']);
      expect(find.text('检测登录'), findsNothing);
      expect(find.text('生成二维码'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(polls(f.runtime), 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(polls(f.runtime), 1);
      expect(f.runtime.parameters.last, {'qrcode_key': 'test-qr'});
      expect(f.c.state.accounts, isEmpty);
      f.runtime.responses['qr_poll'] = confirmed();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(LoginDialog), findsNothing);
      expect(f.c.state.accounts.single.uid, '123');
      expect(f.store.secrets.values.single, contains('synthetic-qr-secret'));
      await tester.pump(const Duration(minutes: 1));
      expect(polls(f.runtime), 2);
      expect(f.runtime.calls, isNot(contains('login_state')));
    },
  );

  testWidgets(
    'Android inactive (visible without window focus) still generates and polls',
    (tester) async {
      // Android reports inactive while the activity is resumed but a split
      // screen, system or third-party overlay holds window focus. 0.3.1 waited
      // for resumed here and stayed on "正在生成" with a disabled button.
      final f = await mountLogin(tester, openedIn: AppLifecycleState.inactive);
      expect(f.runtime.calls, ['qr_start']);
      expect(find.text('请使用手机客户端扫码并确认，完成后将自动登录。'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(polls(f.runtime), 1);
      f.runtime.responses['qr_poll'] = confirmed();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(f.c.state.accounts.single.uid, '123');
      expect(find.byType(LoginDialog), findsNothing);
    },
  );

  testWidgets('losing window focus keeps polling; only hiding pauses it', (
    tester,
  ) async {
    final f = await mountLogin(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 2));
    expect(polls(f.runtime), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(polls(f.runtime), 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(minutes: 1));
    expect(polls(f.runtime), 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(polls(f.runtime), 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(polls(f.runtime), 3);
    expect(f.runtime.calls.where((op) => op == 'qr_start'), hasLength(1));
  });

  testWidgets(
    'opened while hidden says why it waits and the button never dead-ends',
    (tester) async {
      final f = await mountLogin(tester, openedIn: AppLifecycleState.paused);
      expect(f.runtime.calls, isEmpty);
      expect(find.text('正在生成登录二维码…'), findsNothing);
      expect(find.text('应用回到前台后将自动生成登录二维码。'), findsOneWidget);
      // A tap proves the dialog is on screen even if a lifecycle event is late.
      // Flutter renders no frames while paused, so only the request is visible
      // here; the image appears once the platform reports visibility.
      expect(tester.widget<TextButton>(qrButton()).onPressed, isNotNull);
      await tester.tap(qrButton());
      await tester.pump();
      expect(f.runtime.calls, ['qr_start']);
      resumeApp(tester);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(f.runtime.calls.where((op) => op == 'qr_start'), hasLength(1));
      // Becoming visible checks once immediately, then keeps the 2 s cadence.
      expect(polls(f.runtime), 1);
      await tester.pump(const Duration(seconds: 2));
      expect(polls(f.runtime), 2);
    },
  );

  testWidgets('opened while hidden generates automatically on return', (
    tester,
  ) async {
    final f = await mountLogin(tester, openedIn: AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 1));
    expect(f.runtime.calls, isEmpty);
    resumeApp(tester);
    await tester.pump();
    expect(f.runtime.calls, ['qr_start']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('slow calls never overlap or catch up missed timer ticks', (
    tester,
  ) async {
    final response = Completer<Map<String, dynamic>>();
    final r = FakeRuntime()
      ..handler = (op, params) async =>
          op == 'qr_start' ? testQrStart : response.future;
    await mountLogin(tester, runtime: r);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 20));
    expect(polls(r), 1);
    response.complete({'status': 'pending'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1999));
    expect(polls(r), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(polls(r), 2);
  });

  testWidgets('only platform expiry stops polling even after three minutes', (
    tester,
  ) async {
    final f = await mountLogin(tester);
    for (var i = 0; i < 91; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    expect(polls(f.runtime), 91);
    expect(find.textContaining('二维码已失效'), findsNothing);
    f.runtime.responses['qr_poll'] = {'status': 'expired'};
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('二维码已失效，请重新生成。'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(polls(f.runtime), 92);
    f.runtime.responses['qr_poll'] = {'status': 'scanned'};
    await tester.tap(find.text('重新生成二维码'));
    await tester.pump();
    expect(f.runtime.calls.where((op) => op == 'qr_start'), hasLength(2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('已扫码，请在手机客户端确认登录。'), findsOneWidget);
  });

  testWidgets(
    'temporary errors back off, pause after three and retry the same QR',
    (tester) async {
      final f = await mountLogin(tester);
      f.runtime.responses['qr_poll'] = {'status': 'transient_error'};
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 3));
      expect(polls(f.runtime), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(polls(f.runtime), 2);
      await tester.pump(const Duration(seconds: 7));
      expect(polls(f.runtime), 2);
      await tester.pump(const Duration(seconds: 1));
      expect(polls(f.runtime), 3);
      expect(find.text('重试连接'), findsOneWidget);
      expect(find.textContaining('二维码已失效'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(polls(f.runtime), 3);
      f.runtime.responses['qr_poll'] = {'status': 'pending'};
      await tester.tap(find.text('重试连接'));
      await tester.pump();
      expect(polls(f.runtime), 4);
      expect(f.runtime.calls.where((op) => op == 'qr_start'), hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(polls(f.runtime), 5);
    },
  );

  for (final failure in ['failed', 'invalid', 'exception']) {
    testWidgets('$failure stops automatic queries without claiming expiry', (
      tester,
    ) async {
      final r = FakeRuntime()
        ..handler = (op, params) async {
          if (op == 'qr_start') return testQrStart;
          if (failure == 'exception') throw const UserError('内置服务请求超时');
          return {'status': failure, 'message': '账号尚未保存，请重新扫码'};
        };
      final f = await mountLogin(tester, runtime: r);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(minutes: 1));
      expect(polls(r), 1);
      expect(f.c.state.accounts, isEmpty);
      expect(find.textContaining('二维码已失效'), findsNothing);
    });
  }

  testWidgets('generation failure can retry directly with one button', (
    tester,
  ) async {
    final r = FakeRuntime()
      ..responses['qr_start'] = {'qrcode_key': 'incomplete'};
    await mountLogin(tester, runtime: r);
    expect(find.textContaining('登录二维码不完整'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(polls(r), 0);
    r.responses['qr_start'] = testQrStart;
    await tester.tap(find.text('重新生成二维码'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(polls(r), 1);
  });

  testWidgets('background pauses new checks and resumes without regenerating', (
    tester,
  ) async {
    final f = await mountLogin(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pauseApp(tester);
    await tester.pump(const Duration(minutes: 4));
    expect(polls(f.runtime), 0);
    resumeApp(tester);
    await tester.pump();
    expect(polls(f.runtime), 1);
    expect(f.runtime.calls.where((op) => op == 'qr_start'), hasLength(1));
  });

  testWidgets('confirmed response in background is saved once after resume', (
    tester,
  ) async {
    final response = Completer<Map<String, dynamic>>();
    final r = FakeRuntime()
      ..handler = (op, params) async =>
          op == 'qr_start' ? testQrStart : response.future;
    final f = await mountLogin(tester, runtime: r);
    await tester.pump(const Duration(seconds: 2));
    pauseApp(tester);
    response.complete(confirmed());
    await tester.pump();
    expect(f.store.secrets, isEmpty);
    await tester.pump(const Duration(minutes: 4));
    expect(polls(r), 1);
    resumeApp(tester);
    await tester.pumpAndSettle();
    expect(f.c.state.accounts, hasLength(1));
    expect(find.byType(LoginDialog), findsNothing);
    expect(polls(r), 1);
  });

  testWidgets('QR generated in background starts polling only on resume', (
    tester,
  ) async {
    final response = Completer<Map<String, dynamic>>();
    final r = FakeRuntime()
      ..handler = (op, params) async =>
          op == 'qr_start' ? response.future : {'status': 'pending'};
    await mountLogin(tester, runtime: r);
    pauseApp(tester);
    response.complete(testQrStart);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(polls(r), 0);
    resumeApp(tester);
    await tester.pump();
    expect(polls(r), 1);
  });

  for (final action in ['关闭', '切换', '重新生成二维码', '返回']) {
    testWidgets('$action discards a late successful QR response', (
      tester,
    ) async {
      final response = Completer<Map<String, dynamic>>();
      final r = FakeRuntime()
        ..handler = (op, params) async =>
            op == 'qr_start' ? testQrStart : response.future;
      final f = await mountLogin(tester, runtime: r);
      await tester.pump(const Duration(seconds: 2));
      if (action == '切换') {
        await tester.tap(find.byType(SwitchListTile));
      } else if (action == '返回') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.text(action));
      }
      await tester.pump();
      response.complete(confirmed());
      await tester.pump();
      expect(f.c.state.accounts, isEmpty);
      expect(f.store.secrets, isEmpty);
      if (action == '重新生成二维码') {
        expect(r.calls.where((op) => op == 'qr_start'), hasLength(2));
      }
    });
  }

  testWidgets(
    'replacing QR waits for old generation and ignores its image/key',
    (tester) async {
      final first = Completer<Map<String, dynamic>>();
      var starts = 0;
      final r = FakeRuntime()
        ..handler = (op, params) async {
          if (op == 'qr_start') {
            if (++starts == 1) return first.future;
            return {...testQrStart, 'qrcode_key': 'new-key'};
          }
          return {'status': 'pending'};
        };
      await mountLogin(tester, runtime: r);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('重新生成二维码'));
      await tester.pump();
      expect(starts, 1);
      first.complete({...testQrStart, 'qrcode_key': 'old-key'});
      await tester.pump();
      expect(starts, 2);
      await tester.pump(const Duration(seconds: 2));
      expect(r.parameters.last['qrcode_key'], 'new-key');
    },
  );

  testWidgets('saving failure retries the verified result without a new poll', (
    tester,
  ) async {
    final f = await mountLogin(tester);
    f.store.failSave = true;
    f.runtime.responses['qr_poll'] = confirmed();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('重试保存'), findsOneWidget);
    expect(f.c.state.accounts, isEmpty);
    expect(f.store.secrets, isEmpty);
    await tester.pump(const Duration(seconds: 20));
    expect(polls(f.runtime), 1);
    f.store.failSave = false;
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    expect(f.c.state.accounts, hasLength(1));
    expect(polls(f.runtime), 1);
    expect(find.byType(LoginDialog), findsNothing);
  });

  testWidgets('unverified identity is never saved', (tester) async {
    final f = await mountLogin(tester);
    f.runtime.responses['qr_poll'] = confirmed()..remove('uid');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 10));
    expect(polls(f.runtime), 1);
    expect(f.c.state.accounts, isEmpty);
    expect(f.store.secrets, isEmpty);
  });

  testWidgets('an undecodable QR image stops checks and can be regenerated', (
    tester,
  ) async {
    final r = FakeRuntime()
      ..responses['qr_start'] = {
        'qrcode_key': 'test-key',
        'qr_png_base64': 'bm90LWFuLWltYWdl',
      };
    await mountLogin(tester, runtime: r);
    await tester.pumpAndSettle();
    expect(find.text('二维码无法显示，请重新生成。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(polls(r), 0);
    r.responses['qr_start'] = testQrStart;
    await tester.tap(find.text('重新生成二维码'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(polls(r), 1);
  });

  testWidgets(
    'barrier dismissal discards a late confirmation before route disposal',
    (tester) async {
      final response = Completer<Map<String, dynamic>>();
      final r = FakeRuntime()
        ..handler = (op, params) async =>
            op == 'qr_start' ? testQrStart : response.future;
      final f = await mountLogin(tester, runtime: r);
      await tester.pump(const Duration(seconds: 2));
      await tester.tapAt(const Offset(5, 5));
      response.complete(confirmed());
      await tester.pumpAndSettle();
      expect(f.c.state.accounts, isEmpty);
      expect(f.store.secrets, isEmpty);
    },
  );

  testWidgets(
    'manual cookie validation also waits for foreground before saving',
    (tester) async {
      final response = Completer<Map<String, dynamic>>();
      final r = FakeRuntime()
        ..handler = (op, params) async =>
            op == 'qr_start' ? testQrStart : response.future;
      final f = await mountLogin(tester, runtime: r);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField),
        '[{"name":"session","value":"synthetic"}]',
      );
      await tester.tap(find.text('验证并保存'));
      await tester.pump();
      pauseApp(tester);
      response.complete({...confirmed(), 'status': 'valid', 'logged_in': true});
      await tester.pump();
      expect(f.store.secrets, isEmpty);
      resumeApp(tester);
      await tester.pumpAndSettle();
      expect(f.c.state.accounts, hasLength(1));
      expect(polls(r), 0);
      expect(r.calls.where((op) => op == 'login_cookie'), hasLength(1));
    },
  );

  testWidgets('storage commit blocks dismissal and finishes only once', (
    tester,
  ) async {
    final commit = Completer<void>();
    final f = await mountLogin(tester);
    f.store.beforeSave = (_) => commit.future;
    f.runtime.responses['qr_poll'] = confirmed();
    await tester.pump(const Duration(seconds: 2));
    final close = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '关闭'),
    );
    expect(close.onPressed, isNull);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(LoginDialog), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    resumeApp(tester);
    commit.complete();
    await tester.pumpAndSettle();
    expect(f.c.state.accounts, hasLength(1));
    expect(polls(f.runtime), 1);
    expect(find.byType(LoginDialog), findsNothing);
  });

  for (final outcome in ['expired', 'failed']) {
    testWidgets('$outcome from a relogin never deletes the original Cookie', (
      tester,
    ) async {
      final original = Account(id: 'old', name: '原账号', uid: '123');
      final store = MemoryStore()
        ..state = SavedState(accounts: [original])
        ..secrets['account.old'] = '[{"name":"session","value":"old-secret"}]';
      final f = await mountLogin(tester, store: store, account: original);
      f.runtime.responses['qr_poll'] = {'status': outcome};
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 10));
      expect(f.store.secrets['account.old'], contains('old-secret'));
      expect(f.c.state.accounts.single.id, original.id);
    });
  }

  testWidgets(
    'phone QR and retry controls fit large text with keyboard insets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final f = await mountLogin(tester);
      f.runtime.responses['qr_poll'] = confirmed();
      f.store.failSave = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('重试保存').hitTestable(), findsOneWidget);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'routine checks defer during QR login but explicit checks continue',
    (tester) async {
      final store = MemoryStore()
        ..state = SavedState(
          accounts: [Account(id: 'old', name: '原账号', uid: '123')],
        )
        ..secrets['account.old'] = '[{"name":"session","value":"old-secret"}]';
      final f = await mountLogin(tester, store: store);
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['qr_start']);
      expect(
        await f.c.checkAccount(f.c.state.accounts.single),
        AccountAuthStatus.valid,
      );
      expect(f.runtime.calls, ['qr_start', 'login_state']);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      // Explicit validation already covered the current credential, so release
      // does not redundantly check this account a second time.
      expect(f.runtime.calls, ['qr_start', 'login_state']);
    },
  );
}
