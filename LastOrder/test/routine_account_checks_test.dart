import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

List<Map<String, String>> cookies(String value) => [
  {'name': 'SESSDATA', 'value': value},
];

Map<String, dynamic> get valid => {
  'status': 'valid',
  'logged_in': true,
  'username': '测试账号',
  'uid': '123',
};

class RoutineFixture {
  RoutineFixture({int accounts = 1}) {
    store.state = SavedState(
      accounts: [
        for (var i = 0; i < accounts; i++)
          Account(
            id: 'account-$i',
            name: '账号 $i',
            uid: '123',
            authStatus: AccountAuthStatus.valid,
            lastChecked: now,
          ),
      ],
    );
    for (final account in store.state.accounts) {
      store.secrets['account.${account.id}'] = jsonEncode(cookies(account.id));
    }
    c = AppController(
      store: store,
      runtime: runtime,
      gateway: gateway,
      helper: FakeHelper(),
      cloudTemplateLoader: () async => [],
      volcengineTemplateLoader: () async => [],
      aliyunTemplateLoader: () async => [],
      accountCheckClock: () => now,
    );
  }

  final store = MemoryStore();
  final runtime = FakeRuntime();
  final gateway = FakeGateway();
  late final AppController c;
  DateTime now = DateTime.utc(2026, 1, 1);

  Future<void> initialize({bool poll = false}) => c.initialize(poll: poll);
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'startup revalidates persisted accounts even with a recent timestamp',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize(poll: true);
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['login_state']);
      expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.valid);
    },
  );

  test(
    'newly validated credentials postpone only routine checks for five minutes',
    () async {
      final f = RoutineFixture(accounts: 0);
      addTearDown(f.c.dispose);
      await f.initialize();
      final account = await f.c.addAccount('账号', cookies('new'), uid: '123');
      await f.c.checkAccounts();
      f.now = f.now.add(const Duration(minutes: 4, seconds: 59));
      await f.c.checkAccounts();
      expect(f.runtime.calls, isEmpty);

      f.now = f.now.add(const Duration(seconds: 1));
      await f.c.checkAccounts();
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['login_state']);

      await f.c.checkAccount(account);
      await f.c.ensureAccountValid(account);
      expect(f.runtime.calls, ['login_state', 'login_state', 'login_state']);
    },
  );

  test(
    'nested holds coalesce deferred checks and skip a newly refreshed account',
    () async {
      final f = RoutineFixture(accounts: 2);
      addTearDown(f.c.dispose);
      await f.initialize();
      f.c.holdRoutineAccountChecks();
      f.c.holdRoutineAccountChecks();
      await f.c.checkAccounts();
      await f.c.checkAccounts();
      await f.c.checkAccounts();
      expect(f.runtime.calls, isEmpty);
      await f.c.refreshAccount(
        f.c.state.accounts.first,
        name: '重新登录',
        cookies: cookies('new'),
        uid: '123',
      );
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.runtime.calls, isEmpty);
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.runtime.calls, ['login_state']);
      expect(f.runtime.parameters.single['cookies'], cookies('account-1'));
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.runtime.calls, ['login_state']);
    },
  );

  test(
    'manual and required pre-dispatch validation still run during a hold',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      final account = f.c.state.accounts.single;
      final task = await f.c.addTask('任务', account, {
        'ticket': {'id': 7},
      });
      f.runtime.calls.clear();
      f.runtime.parameters.clear();
      f.c.holdRoutineAccountChecks();
      await f.c.checkAccounts();
      await f.c.checkAccount(account);
      await f.c.dispatch(task, [machine('a')]);
      expect(f.runtime.calls, ['login_state', 'login_state']);
      expect(f.gateway.submitted, contains('a'));
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.runtime.calls, ['login_state', 'login_state']);
    },
  );

  test(
    'unknown pre-dispatch validation is not bypassed during a login hold',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      final account = f.c.state.accounts.single;
      final task = await f.c.addTask('任务', account, {
        'ticket': {'id': 7},
      });
      f.c.holdRoutineAccountChecks();
      f.runtime.responses['login_state'] = {'status': 'unknown'};
      await expectLater(
        f.c.dispatch(task, [machine('a')]),
        throwsA(isA<UserError>()),
      );
      expect(f.gateway.submitted, isEmpty);
      expect(f.store.secrets['account.${account.id}'], isNotNull);
    },
  );

  test('overlapping routine sweeps share one sequential batch', () async {
    final f = RoutineFixture(accounts: 2);
    addTearDown(f.c.dispose);
    await f.initialize();
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    f.runtime.handler = (op, params) {
      if (f.runtime.calls.length == 1) {
        started.complete();
        return response.future;
      }
      return Future.value(valid);
    };
    final first = f.c.checkAccounts();
    await started.future;
    final second = f.c.checkAccounts();
    final third = f.c.checkAccounts();
    expect(f.runtime.calls, ['login_state']);
    response.complete({'status': 'unknown'});
    await Future.wait([first, second, third]);
    expect(f.runtime.calls, ['login_state', 'login_state']);
    expect(f.runtime.parameters[1]['cookies'], cookies('account-1'));
  });

  test('a hold lets the in-flight check finish and resumes only the remaining account', () async {
    final f = RoutineFixture(accounts: 2);
    addTearDown(f.c.dispose);
    await f.initialize();
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    f.runtime.handler = (op, params) {
      if (f.runtime.calls.length == 1) {
        started.complete();
        return response.future;
      }
      return Future.value(valid);
    };
    final batch = f.c.checkAccounts();
    await started.future;
    f.c.holdRoutineAccountChecks();
    response.complete({'status': 'unknown'});
    await batch;
    expect(f.runtime.calls, ['login_state']);
    f.c.releaseRoutineAccountChecks();
    await settle();
    expect(f.runtime.calls, ['login_state', 'login_state']);
    expect(f.runtime.parameters.last['cookies'], cookies('account-1'));
  });

  test(
    'a hold acquired during secure storage read defers the network request',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      final reading = Completer<void>();
      final release = Completer<void>();
      f.store.beforeRead = (key) async {
        if (key == 'account.account-0') {
          reading.complete();
          await release.future;
        }
      };
      final batch = f.c.checkAccounts();
      await reading.future;
      f.c.holdRoutineAccountChecks();
      f.store.beforeRead = null;
      release.complete();
      await batch;
      expect(f.runtime.calls, isEmpty);
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.runtime.calls, ['login_state']);
    },
  );

  test(
    'unknown with a fresh lastChecked timestamp is not a successful validation',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      await f.c.checkAccounts();
      f.runtime.responses['login_state'] = {'status': 'unknown'};
      await f.c.checkAccount(f.c.state.accounts.single);
      expect(f.c.state.accounts.single.lastChecked, f.now);
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['login_state', 'login_state', 'login_state']);
      expect(f.store.secrets['account.account-0'], isNotNull);
    },
  );

  test(
    'a changed credential revision cannot reuse a recent successful validation',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      await f.c.checkAccounts();
      f.store.failSave = true;
      await expectLater(
        f.c.refreshAccount(
          f.c.state.accounts.single,
          name: '新凭据',
          cookies: cookies('new'),
          uid: '123',
        ),
        throwsA(isA<UserError>()),
      );
      f.store.failSave = false;
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['login_state', 'login_state']);
      expect(f.runtime.parameters.last['cookies'], cookies('account-0'));
    },
  );

  test(
    'a late expired routine response cannot invalidate a refreshed login',
    () async {
      final f = RoutineFixture();
      addTearDown(f.c.dispose);
      await f.initialize();
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      f.runtime.handler = (op, params) {
        started.complete();
        return response.future;
      };
      final batch = f.c.checkAccounts();
      await started.future;
      f.c.holdRoutineAccountChecks();
      await f.c.refreshAccount(
        f.c.state.accounts.single,
        name: '重新登录',
        cookies: cookies('new'),
        uid: '123',
      );
      response.complete({'status': 'expired', 'logged_in': false});
      await batch;
      f.c.releaseRoutineAccountChecks();
      await settle();
      expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.valid);
      expect(f.store.secrets['account.account-0'], contains('new'));
      expect(f.runtime.calls, ['login_state']);
    },
  );

  test(
    'disposing drops deferred checks without starting a runtime call',
    () async {
      final f = RoutineFixture(accounts: 2);
      await f.initialize();
      f.c.holdRoutineAccountChecks();
      await f.c.checkAccounts();
      f.c.dispose();
      f.c.releaseRoutineAccountChecks();
      await f.c.checkAccounts();
      expect(f.runtime.calls, isEmpty);
    },
  );

  test(
    'disposing during a runtime call prevents writes and further checks',
    () async {
      final f = RoutineFixture(accounts: 2);
      await f.initialize();
      final before = Map.of(f.store.secrets);
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      f.runtime.handler = (op, params) {
        started.complete();
        return response.future;
      };
      final batch = f.c.checkAccounts();
      await started.future;
      f.c.dispose();
      response.complete({'status': 'expired', 'logged_in': false});
      await batch;
      await f.c.checkAccounts();
      expect(f.runtime.calls, ['login_state']);
      expect(f.store.secrets, before);
    },
  );

  test('disposing during secure storage read prevents a late failure from changing state', () async {
    final f = RoutineFixture();
    await f.initialize();
    final reading = Completer<void>();
    final release = Completer<void>();
    f.store.beforeRead = (key) async {
      if (key == 'account.account-0') {
        reading.complete();
        await release.future;
        throw const UserError('读取失败');
      }
    };
    final check = f.c.checkAccount(f.c.state.accounts.single);
    await reading.future;
    f.c.dispose();
    release.complete();
    expect(await check, AccountAuthStatus.unknown);
    expect(f.c.state.accounts.single.authStatus, AccountAuthStatus.valid);
    expect(f.c.accountMessages, isEmpty);
    expect(f.runtime.calls, isEmpty);
  });
}
