import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

List<dynamic> credentials([String value = 'old', String uid = '123']) => [
  {'name': 'DedeUserID', 'value': uid},
  {'name': 'SESSDATA', 'value': value},
];
Map<String, dynamic> get valid => {
  'status': 'valid',
  'logged_in': true,
  'username': '测试账号',
  'uid': '123',
};
Map<String, dynamic> get expired => {
  'status': 'expired',
  'logged_in': false,
  'uid': '',
};
Future<
  ({
    AppController c,
    MemoryStore store,
    FakeRuntime runtime,
    FakeGateway gateway,
    Account account,
    TicketTask task,
  })
>
fixture() async {
  final store = MemoryStore();
  final runtime = FakeRuntime();
  final gateway = FakeGateway();
  final c = controller(store: store, runtime: runtime, gateway: gateway);
  await c.initialize(poll: false);
  final account = await c.addAccount('原账号', credentials(), uid: '123');
  final task = await c.addTask('原任务', account, {
    'ticket': {'id': 7},
    'buyer': {'name': '测试购票人'},
    'cookies': credentials(),
  });
  return (
    c: c,
    store: store,
    runtime: runtime,
    gateway: gateway,
    account: account,
    task: task,
  );
}

void main() {
  test(
    'account identity is required and authentication metadata roundtrips',
    () {
      for (final uid in ['', '0', '0123', '-1', 'abc', ' 123']) {
        expect(
          () => Account(id: 'a', name: '账号', uid: uid),
          throwsFormatException,
        );
      }
      final date = DateTime.utc(2026, 1, 1);
      final account = Account(
        id: 'a',
        name: '账号',
        uid: '123',
      ).copyWith(authStatus: AccountAuthStatus.expired, lastChecked: date);
      final decoded = Account.fromJson(account.toJson());
      expect(decoded.id, 'a');
      expect(decoded.uid, '123');
      expect(decoded.authStatus, AccountAuthStatus.expired);
      expect(decoded.lastChecked, date);
      expect(() => SavedState.decode('{"schema":1}'), throwsFormatException);
      expect(jsonDecode(SavedState(accounts: [account]).encode())['schema'], 2);
    },
  );

  test(
    'new task config never stores cookies, validation uses current credential',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final stored = f.store.secrets['task.${f.task.id}']!;
      expect(stored, isNot(contains('SESSDATA')));
      expect(jsonDecode(stored)['ticket'], {'id': 7});
      expect(f.runtime.parameters.last['config']['cookies'], credentials());
    },
  );
  test('explicit expiry clears account cookies and preserves cookie-free task selection', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final originalConfig = f.store.secrets['task.${f.task.id}'];
    f.runtime.responses['login_state'] = expired;
    expect(await f.c.checkAccount(f.account), AccountAuthStatus.expired);
    expect(f.store.secrets.containsKey('account.${f.account.id}'), false);
    expect(f.store.secrets['task.${f.task.id}'], originalConfig);
    expect(originalConfig, isNot(contains('SESSDATA')));
    expect(f.c.state.accounts.single.id, f.account.id);
    expect(f.c.state.accounts.single.uid, '123');
    expect(f.c.state.tasks.single.id, f.task.id);
    expect(f.c.accountMessages[f.account.id], contains('已清除'));
    await expectLater(f.c.cookies(f.account), throwsA(isA<UserError>()));
  });

  test(
    'unknown and network failure preserve secrets and block dispatch',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final original = Map.of(f.store.secrets);
      f.runtime.responses['login_state'] = {
        'status': 'unknown',
        'logged_in': false,
      };
      expect(await f.c.checkAccount(f.account), AccountAuthStatus.unknown);
      expect(f.store.secrets, original);
      await expectLater(
        f.c.dispatch(f.task, [machine('a')]),
        throwsA(isA<UserError>()),
      );
      expect(f.gateway.submitted, isEmpty);
      f.runtime.handler = (op, params) async => throw StateError('unavailable');
      expect(await f.c.checkAccount(f.account), AccountAuthStatus.unknown);
      expect(f.store.secrets, original);
    },
  );
  test(
    'a plain logged_in false without explicit expiry never deletes cookies',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      f.runtime.responses['login_state'] = {'logged_in': false};
      expect(await f.c.checkAccount(f.account), AccountAuthStatus.unknown);
      expect(f.store.secrets['account.${f.account.id}'], isNotNull);
    },
  );
  test('failed expiry deletion remains expired and retries cleanup without platform call', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final key = 'account.${f.account.id}';
    f.store.failDelete.add(key);
    f.runtime.responses['login_state'] = expired;
    await expectLater(f.c.checkAccount(f.account), throwsA(isA<UserError>()));
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
    expect(f.store.secrets[key], isNotNull);
    expect(f.c.accountMessages[f.account.id], contains('未完成'));
    expect(f.c.accountMessages[f.account.id], isNot(contains('已清除')));
    f.store.failRead.add(key);
    await expectLater(f.c.checkAccount(f.account), throwsA(isA<UserError>()));
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
    f.store.failRead.clear();
    f.store.failDelete.clear();
    expect(await f.c.checkAccount(f.account), AccountAuthStatus.expired);
    expect(f.store.secrets[key], isNull);
    expect(f.runtime.calls.where((op) => op == 'login_state').length, 1);
  });
  test('silent keychain deletion failure is not reported as cleaned', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    f.store.silentDelete.add('account.${f.account.id}');
    f.runtime.responses['login_state'] = expired;
    await expectLater(f.c.checkAccount(f.account), throwsA(isA<UserError>()));
    expect(f.c.accountMessages[f.account.id], contains('未完成'));
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
  });

  test('task deletion failure retains metadata and is retryable', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    f.store.failDelete.add('task.${f.task.id}');
    await expectLater(f.c.removeTask(f.task), throwsA(isA<UserError>()));
    expect(f.c.state.tasks, hasLength(1));
    expect(f.store.secrets['task.${f.task.id}'], isNotNull);
    f.store.failDelete.clear();
    await f.c.removeTask(f.task);
    expect(f.c.state.tasks, isEmpty);
    expect(f.store.secrets['task.${f.task.id}'], isNull);
  });

  test('same UID relogin preserves account and task ids and dispatch uses only new cookies', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    f.runtime.responses['login_state'] = expired;
    await f.c.checkAccount(f.account);
    final refreshed = await f.c.refreshAccount(
      f.account,
      name: '更新名称',
      cookies: credentials('new'),
      uid: '123',
    );
    expect(refreshed.id, f.account.id);
    expect(refreshed.name, '更新名称');
    expect(refreshed.authStatus, AccountAuthStatus.valid);
    expect(f.c.state.tasks.single.id, f.task.id);
    f.runtime.responses['login_state'] = valid;
    await f.c.dispatch(f.task, [machine('a')]);
    expect(f.gateway.submitted['a']!.cookieJson, contains('new'));
    expect(f.gateway.submitted['a']!.cookieJson, isNot(contains('old')));
    expect(f.gateway.submitted['a']!.configJson, isNot(contains('cookies')));
  });
  test('relogin rejects a different UID without changing original secrets or tasks', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final original = Map.of(f.store.secrets);
    await expectLater(
      f.c.refreshAccount(
        f.account,
        name: '不同账号',
        cookies: credentials('new', '456'),
        uid: '456',
      ),
      throwsA(isA<UserError>()),
    );
    expect(f.store.secrets, original);
    expect(f.c.state.accounts.single.uid, '123');
    expect(f.c.state.tasks.single.id, f.task.id);
  });
  test('new accounts require an explicit verified numeric UID without cookie inference', () async {
    final store = MemoryStore();
    final c = controller(store: store);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    for (final uid in ['', '0', '0123', 'abc']) {
      await expectLater(
        c.addAccount('账号', credentials(), uid: uid),
        throwsA(isA<UserError>()),
      );
    }
    expect(store.secrets, isEmpty);
    expect(c.state.accounts, isEmpty);
    final account = await c.addAccount('账号', [
      {'name': 'SESSDATA', 'value': 'test'},
    ], uid: '123');
    expect(account.uid, '123');
  });

  test('late expired response never deletes a refreshed credential', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final started = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    f.runtime.handler = (op, params) {
      started.complete();
      return reply.future;
    };
    final check = f.c.checkAccount(f.account);
    await started.future;
    await f.c.refreshAccount(
      f.account,
      name: '重新登录',
      cookies: credentials('new'),
      uid: '123',
    );
    reply.complete(expired);
    expect(await check, AccountAuthStatus.unknown);
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.valid);
    expect(f.store.secrets['account.${f.account.id}'], contains('new'));
    expect(f.c.checkingAccounts, isEmpty);
  });
  test('superseded valid response cannot authorize dispatch while a newer check is pending', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    var calls = 0;
    f.runtime.handler = (op, params) {
      if (++calls == 1) {
        firstStarted.complete();
        return first.future;
      }
      secondStarted.complete();
      return second.future;
    };
    final dispatch = f.c.dispatch(f.task, [machine('a')]);
    final rejected = expectLater(dispatch, throwsA(isA<UserError>()));
    await firstStarted.future;
    final newer = f.c.checkAccount(f.account);
    await secondStarted.future;
    first.complete(valid);
    await rejected;
    expect(f.gateway.submitted, isEmpty);
    second.complete(expired);
    expect(await newer, AccountAuthStatus.expired);
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
  });
  test(
    'late valid check cannot resurrect an account after a newer expiry',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final started = Completer<void>();
      final old = Completer<Map<String, dynamic>>();
      var calls = 0;
      f.runtime.handler = (op, params) {
        if (++calls == 1) {
          started.complete();
          return old.future;
        }
        return Future.value(expired);
      };
      final first = f.c.checkAccount(f.account);
      await started.future;
      expect(await f.c.checkAccount(f.account), AccountAuthStatus.expired);
      old.complete(valid);
      expect(await first, AccountAuthStatus.unknown);
      expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
      expect(f.store.secrets['account.${f.account.id}'], isNull);
    },
  );
  test(
    'failed refresh metadata save rolls back valid previous credential',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final original = f.store.secrets['account.${f.account.id}'];
      f.store.failSave = true;
      await expectLater(
        f.c.refreshAccount(
          f.account,
          name: 'new',
          cookies: credentials('new'),
          uid: '123',
        ),
        throwsA(isA<UserError>()),
      );
      expect(f.store.secrets['account.${f.account.id}'], original);
      expect(f.c.state.accounts.single.name, '原账号');
    },
  );
  test(
    'failed refresh never restores known expired leftover credentials',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final key = 'account.${f.account.id}';
      f.store.failDelete.add(key);
      f.runtime.responses['login_state'] = expired;
      await expectLater(f.c.checkAccount(f.account), throwsA(isA<UserError>()));
      f.store.failDelete.clear();
      f.store.failSave = true;
      await expectLater(
        f.c.refreshAccount(
          f.account,
          name: 'new',
          cookies: credentials('new'),
          uid: '123',
        ),
        throwsA(isA<UserError>()),
      );
      expect(f.store.secrets[key], isNull);
      expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
    },
  );
  test('failed expired metadata save cannot be undone by a concurrent machine save', () async {
    final f = await fixture();
    addTearDown(f.c.dispose);
    final entered = Completer<void>();
    final release = Completer<void>();
    var failed = false;
    f.store.beforeSave = (value) async {
      if (!failed &&
          value.accounts.single.authStatus == AccountAuthStatus.expired) {
        failed = true;
        entered.complete();
        await release.future;
        throw const UserError('metadata failure');
      }
    };
    f.store.failDelete.add('account.${f.account.id}');
    f.runtime.responses['login_state'] = expired;
    final check = f.c.checkAccount(f.account);
    final rejected = expectLater(check, throwsA(isA<UserError>()));
    await entered.future;
    final added = f.c.addMachine(machine('a'));
    release.complete();
    await rejected;
    await added;
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.expired);
    expect(f.c.state.machines, hasLength(1));
    await expectLater(f.c.cookies(f.account), throwsA(isA<UserError>()));
  });
  test(
    'dispatch rechecks credential revision after reading task config',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      final reading = Completer<void>();
      final release = Completer<void>();
      f.store.beforeRead = (key) async {
        if (key == 'task.${f.task.id}') {
          reading.complete();
          await release.future;
        }
      };
      final dispatch = f.c.dispatch(f.task, [machine('a')]);
      final rejected = expectLater(dispatch, throwsA(isA<UserError>()));
      await reading.future;
      final refreshed = f.c.refreshAccount(
        f.account,
        name: 'new',
        cookies: credentials('new'),
        uid: '123',
      );
      release.complete();
      await refreshed;
      await rejected;
      expect(f.gateway.submitted, isEmpty);
    },
  );

  test(
    'removing an account while a check is pending cannot recreate it',
    () async {
      final f = await fixture();
      addTearDown(f.c.dispose);
      await f.c.removeTask(f.task);
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      f.runtime.handler = (op, params) {
        started.complete();
        return response.future;
      };
      final check = f.c.checkAccount(f.account);
      await started.future;
      await f.c.removeAccount(f.account);
      response.complete(expired);
      expect(await check, AccountAuthStatus.unknown);
      expect(f.c.state.accounts, isEmpty);
      expect(f.store.secrets, isEmpty);
    },
  );
  test(
    'concurrent account creation does not lose either metadata row',
    () async {
      final c = controller();
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await Future.wait([
        c.addAccount('a', credentials('a', '123'), uid: '123'),
        c.addAccount('b', credentials('b', '456'), uid: '456'),
      ]);
      expect(c.state.accounts, hasLength(2));
    },
  );
}
