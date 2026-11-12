import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder accountCard(String id) => find.byKey(ValueKey('account-card-$id'));
Finder accountText(String id, String text) =>
    find.descendant(of: accountCard(id), matching: find.textContaining(text));
Finder accountAction(String id, String label) => find.ancestor(
  of: accountText(id, label),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);
Finder removeAccount(String id) =>
    find.descendant(of: accountCard(id), matching: find.byTooltip('移除账号'));

const longName = '很长的账号昵称用于验证完整显示与同一行卡片操作按钮底部对齐';
const longUid = '123456789012345678901234567890123456789012345678901234567890';
const longError = '暂时无法确认登录状态，请检查当前网络与平台连接后重试；现有凭据没有删除，账号相关任务暂时不能分发。';
final checkedAt = DateTime.utc(2026, 11, 13, 3, 4, 5);

Future<({AppController controller, MemoryStore store, FakeRuntime runtime})>
openAccounts(
  WidgetTester tester, {
  double width = 1360,
  bool longDetails = false,
  AccountAuthStatus rightStatus = AccountAuthStatus.expired,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final accounts = [
    Account(
      id: 'a',
      name: '共用昵称',
      uid: '10001',
      authStatus: AccountAuthStatus.valid,
      lastChecked: checkedAt,
    ),
    Account(
      id: 'b',
      name: longDetails ? longName : '共用昵称',
      uid: longDetails ? longUid : '10002',
      authStatus: rightStatus,
    ),
    Account(id: 'c', name: '备用账号', uid: '10003'),
  ];
  final store = MemoryStore()
    ..state = SavedState(
      accounts: accounts,
      tasks: [
        TicketTask(id: 'task-a', name: '任务甲', accountId: 'a'),
        TicketTask(id: 'task-b', name: '任务乙', accountId: 'a'),
      ],
    );
  for (final account in accounts) {
    store.secrets['account.${account.id}'] = jsonEncode([
      {'name': 'DedeUserID', 'value': account.uid},
    ]);
  }
  final runtime = FakeRuntime();
  final c = controller(store: store, runtime: runtime);
  await c.initialize(poll: false);
  addTearDown(c.dispose);
  if (longDetails) c.accountMessages['b'] = longError;
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(
    width >= 600 ? find.byTooltip('账号与任务') : find.text('账号与任务').first,
  );
  await tester.pumpAndSettle();
  return (controller: c, store: store, runtime: runtime);
}

void main() {
  for (final width in [1024.0, 1360.0]) {
    testWidgets('accounts fill two equal desktop columns at $width', (
      tester,
    ) async {
      await openAccounts(tester, width: width);
      final a = tester.getRect(accountCard('a'));
      final b = tester.getRect(accountCard('b'));
      final c = tester.getRect(accountCard('c'));
      expect(a.top, b.top);
      expect(a.bottom, b.bottom);
      expect(a.width, closeTo(b.width, 0.01));
      expect(b.left - a.right, closeTo(16, 0.01));
      expect(c.left, a.left);
      expect(c.width, closeTo(a.width, 0.01));
      expect(c.top - a.bottom, closeTo(16, 0.01));
      expect(b.right, closeTo(width - 32, 0.01));
      expect(
        find.descendant(of: accountCard('a'), matching: find.byType(Card)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'compact desktop and phone accounts use full-width single cards',
    (tester) async {
      await openAccounts(tester, width: 800);
      for (final width in [800.0, 390.0, 320.0]) {
        tester.view.physicalSize = Size(width, 1400);
        await tester.pumpAndSettle();
        final a = tester.getRect(accountCard('a'));
        final b = tester.getRect(accountCard('b'));
        final c = tester.getRect(accountCard('c'));
        expect(a.left, b.left);
        expect(b.left, c.left);
        expect(a.width, b.width);
        expect(b.width, c.width);
        expect(b.top - a.bottom, closeTo(16, 0.01));
        expect(c.top - b.bottom, closeTo(16, 0.01));
        expect(a.right, closeTo(width - 16, 0.01));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('large text changes account cards to one column', (tester) async {
    await openAccounts(tester, width: 900);
    expect(
      tester.getRect(accountCard('a')).top,
      tester.getRect(accountCard('b')).top,
    );
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await tester.pumpAndSettle();
    final a = tester.getRect(accountCard('a'));
    final b = tester.getRect(accountCard('b'));
    expect(a.left, b.left);
    expect(a.width, b.width);
    expect(b.top, greaterThan(a.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long account details wrap without clipping and align row actions',
    (tester) async {
      await openAccounts(tester, width: 1024, longDetails: true);
      for (final width in [1024.0, 320.0]) {
        tester.view.physicalSize = Size(width, 1400);
        await tester.pumpAndSettle();
        final b = tester.getRect(accountCard('b'));
        for (final finder in [
          accountText('b', longName),
          accountText('b', longUid),
          accountText('b', longError),
          accountAction('b', '检查登录'),
          accountAction('b', '重新登录'),
          removeAccount('b'),
        ]) {
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(b.left));
          expect(rect.right, lessThanOrEqualTo(b.right));
          expect(rect.top, greaterThanOrEqualTo(b.top));
          expect(rect.bottom, lessThanOrEqualTo(b.bottom));
        }
        if (width == 1024) {
          expect(tester.getRect(accountCard('a')).bottom, b.bottom);
          for (final label in ['检查登录', '重新登录']) {
            expect(
              tester.getRect(accountAction('a', label)).bottom,
              tester.getRect(accountAction('b', label)).bottom,
            );
          }
          expect(
            tester.getRect(removeAccount('a')).bottom,
            tester.getRect(removeAccount('b')).bottom,
          );
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'account identity, auth status, task counts and last check are distinct',
    (tester) async {
      await openAccounts(tester);
      expect(accountText('a', '共用昵称'), findsOneWidget);
      expect(accountText('b', '共用昵称'), findsOneWidget);
      expect(accountText('a', 'UID 10001'), findsOneWidget);
      expect(accountText('b', 'UID 10002'), findsOneWidget);
      expect(accountText('a', '10002'), findsNothing);
      expect(accountText('b', '10001'), findsNothing);
      expect(accountText('a', '登录有效'), findsOneWidget);
      expect(accountText('b', '登录失效'), findsOneWidget);
      expect(accountText('c', '待确认'), findsOneWidget);
      expect(accountText('a', '关联任务 2 个'), findsOneWidget);
      expect(accountText('b', '关联任务 0 个'), findsOneWidget);
      expect(accountText('c', '关联任务 0 个'), findsOneWidget);
      expect(
        accountText('a', checkedAt.toLocal().toString().split('.').first),
        findsOneWidget,
      );
      expect(accountText('b', '尚未检查'), findsOneWidget);
      expect(accountText('c', '尚未检查'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'right-column relogin and remove actions target the selected account',
    (tester) async {
      final fixture = await openAccounts(tester);
      await tester.tap(accountAction('b', '重新登录'));
      await tester.pumpAndSettle();
      final login = tester.widget<LoginDialog>(find.byType(LoginDialog));
      expect(login.account?.id, 'b');
      expect(login.account?.uid, '10002');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(removeAccount('b'));
      await tester.pumpAndSettle();
      expect(find.text('移除账号'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(fixture.controller.state.accounts.map((a) => a.id), [
        'a',
        'b',
        'c',
      ]);
      await tester.tap(removeAccount('b'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(fixture.controller.state.accounts.map((a) => a.id), ['a', 'c']);
      expect(fixture.store.secrets.containsKey('account.b'), isFalse);
      expect(fixture.store.secrets.containsKey('account.a'), isTrue);
      expect(fixture.store.secrets.containsKey('account.c'), isTrue);
      expect(accountCard('b'), findsNothing);
      expect(
        tester.getRect(accountCard('a')).top,
        tester.getRect(accountCard('c')).top,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('an account with linked tasks cannot be removed', (tester) async {
    final fixture = await openAccounts(tester);
    final secret = fixture.store.secrets['account.a'];
    await tester.tap(removeAccount('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('请先删除使用此账号的任务，再移除账号。'), findsOneWidget);
    expect(fixture.controller.state.accounts.map((a) => a.id), ['a', 'b', 'c']);
    expect(fixture.controller.state.tasks, hasLength(2));
    expect(fixture.store.secrets['account.a'], secret);
    expect(accountCard('a'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'checking login shows progress and disables the in-flight target action',
    (tester) async {
      final fixture = await openAccounts(
        tester,
        rightStatus: AccountAuthStatus.unknown,
      );
      final gate = Completer<Map<String, dynamic>>();
      fixture.runtime.handler = (operation, params) async => gate.future;
      await tester.tap(accountAction('b', '检查登录'));
      await tester.pump();
      expect(fixture.runtime.calls, ['login_state']);
      expect(fixture.runtime.parameters.single['cookies'], [
        {'name': 'DedeUserID', 'value': '10002'},
      ]);
      expect(fixture.controller.checkingAccounts, {'b'});
      expect(accountText('b', '验证中'), findsOneWidget);
      expect(
        tester.widget<ButtonStyleButton>(accountAction('b', '检查登录')).onPressed,
        isNull,
      );
      gate.complete({
        'status': 'valid',
        'logged_in': true,
        'username': '共用昵称',
        'uid': '10002',
      });
      await tester.pumpAndSettle();
      expect(fixture.controller.checkingAccounts, isEmpty);
      expect(accountText('b', '登录有效'), findsOneWidget);
      expect(accountText('b', '验证中'), findsNothing);
      expect(
        tester.widget<ButtonStyleButton>(accountAction('b', '检查登录')).onPressed,
        isNotNull,
      );
      expect(fixture.controller.state.accounts.first.lastChecked, checkedAt);
      expect(tester.takeException(), isNull);
    },
  );
}
