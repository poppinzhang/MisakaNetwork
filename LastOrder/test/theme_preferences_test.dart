import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

class DeferredLoadStore extends MemoryStore {
  final loaded = Completer<void>();

  @override
  Future<SavedState> load() async {
    await loaded.future;
    return super.load();
  }
}

void main() {
  test('theme preference defaults to system and roundtrips all choices', () {
    expect(SavedState().themeMode, AppThemeMode.system);
    for (final mode in AppThemeMode.values) {
      final saved = SavedState(themeMode: mode).encode();
      expect(jsonDecode(saved)['theme_mode'], mode.name);
      expect(SavedState.decode(saved).themeMode, mode);
    }
  });

  test('missing or invalid theme preference falls back to system', () {
    final saved = jsonDecode(SavedState().encode()) as Map<String, dynamic>;
    saved.remove('theme_mode');
    expect(SavedState.decode(jsonEncode(saved)).themeMode, AppThemeMode.system);
    for (final invalid in [null, '', 'unknown', 'DARK', 1, false, [], {}]) {
      saved['theme_mode'] = invalid;
      expect(
        SavedState.decode(jsonEncode(saved)).themeMode,
        AppThemeMode.system,
      );
    }
  });

  test('theme preference persists and is restored on restart', () async {
    final store = MemoryStore();
    final c = controller(store: store);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    final notifications = <AppThemeMode>[];
    c.addListener(() => notifications.add(c.state.themeMode));

    for (final mode in [
      AppThemeMode.dark,
      AppThemeMode.light,
      AppThemeMode.system,
    ]) {
      await c.setThemeMode(mode);
      expect(c.state.themeMode, mode);
      expect(store.state.themeMode, mode);
      expect(notifications.last, mode);
      final restarted = controller(store: store);
      await restarted.initialize(poll: false);
      expect(restarted.state.themeMode, mode);
      restarted.dispose();
    }
  });

  test(
    'failed theme persistence keeps the previous mode and can retry',
    () async {
      final store = MemoryStore()
        ..state = SavedState(themeMode: AppThemeMode.dark);
      final c = controller(store: store);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      var notifications = 0;
      c.addListener(() => notifications++);
      store.failSave = true;

      await expectLater(
        c.setThemeMode(AppThemeMode.light),
        throwsA(isA<UserError>()),
      );
      expect(c.state.themeMode, AppThemeMode.dark);
      expect(store.state.themeMode, AppThemeMode.dark);
      expect(notifications, 0);

      store.failSave = false;
      await c.setThemeMode(AppThemeMode.light);
      expect(c.state.themeMode, AppThemeMode.light);
      expect(store.state.themeMode, AppThemeMode.light);
      expect(notifications, 1);
    },
  );

  test(
    'theme cannot overwrite state while initial loading is pending',
    () async {
      final store = DeferredLoadStore()
        ..state = SavedState(
          themeMode: AppThemeMode.dark,
          machines: [machine('a')],
        );
      final c = controller(store: store);
      addTearDown(c.dispose);
      final initialize = c.initialize(poll: false);

      await expectLater(
        c.setThemeMode(AppThemeMode.light),
        throwsA(isA<UserError>()),
      );
      expect(store.state.themeMode, AppThemeMode.dark);
      expect(store.state.machines.single.id, 'a');
      store.loaded.complete();
      await initialize;
      expect(c.state.themeMode, AppThemeMode.dark);
      expect(c.state.machines.single.id, 'a');
    },
  );

  test('theme mutation remains blocked after startup failure', () async {
    final store = MemoryStore()..failLoad = true;
    final c = controller(store: store);
    addTearDown(c.dispose);
    await c.initialize(poll: false);

    await expectLater(
      c.setThemeMode(AppThemeMode.dark),
      throwsA(isA<UserError>()),
    );
    expect(c.state.themeMode, AppThemeMode.system);
    expect(store.state.themeMode, AppThemeMode.system);
    expect(c.startupError, '配置无法读取');
  });

  test(
    'queued theme and machine changes preserve each other in order',
    () async {
      final store = MemoryStore();
      final c = controller(store: store);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final started = Completer<void>();
      final release = Completer<void>();
      final saves = <SavedState>[];
      store.beforeSave = (value) async {
        saves.add(value);
        if (saves.length == 1) {
          started.complete();
          await release.future;
        }
      };

      final first = c.setThemeMode(AppThemeMode.dark);
      await started.future;
      final second = c.addMachine(machine('a'));
      final third = c.setThemeMode(AppThemeMode.system);
      expect(c.state.themeMode, AppThemeMode.system);
      release.complete();
      await Future.wait([first, second, third]);

      expect(saves.map((s) => s.themeMode), [
        AppThemeMode.dark,
        AppThemeMode.dark,
        AppThemeMode.system,
      ]);
      expect(c.state.themeMode, AppThemeMode.system);
      expect(c.state.machines.single.id, 'a');
      expect(store.state.themeMode, AppThemeMode.system);
      expect(store.state.machines.single.id, 'a');
    },
  );

  test('account and task mutations preserve the selected theme', () async {
    final store = MemoryStore()
      ..state = SavedState(themeMode: AppThemeMode.dark);
    final c = controller(store: store);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    final modes = <AppThemeMode>[];
    store.beforeSave = (value) async => modes.add(value.themeMode);

    final account = await c.addAccount('测试账号', [
      {'name': 'session', 'value': 'mock-session'},
    ], uid: '123');
    final task = await c.addTask('测试任务', account, {});
    await c.removeTask(task);
    await c.removeAccount(account);

    expect(modes, isNotEmpty);
    expect(modes, everyElement(AppThemeMode.dark));
    expect(c.state.themeMode, AppThemeMode.dark);
    expect(store.state.themeMode, AppThemeMode.dark);
  });
}
