import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';
import 'package:path/path.dart' as p;

Future<void> protectTestPath(String path, String mode) async {
  // Windows ACL enforcement is covered by native helper tests. Unit tests must
  // not depend on a packaged helper beside the Flutter test runner.
  if (Platform.isMacOS || Platform.isLinux) {
    await restrictPermissions(path, mode);
  }
}

class TestLocalStore extends LocalStore {
  TestLocalStore(this.path, {super.protect = protectTestPath})
    : super(useEncryptedVault: false);
  final String path;
  @override
  Future<String> directory() async => path;
}

class CountingSecureStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  final reads = <String>[];
  final writes = <String>[];
  bool denyRead = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads.add(key);
    if (denyRead) throw PlatformException(code: 'synthetic-denial');
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add(key);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late TestLocalStore store;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lastorder-storage-');
    store = TestLocalStore(temporary.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async => temporary.delete(recursive: true));

  test(
    'first launch starts empty and leaves the previous state file untouched',
    () async {
      final oldFile = File('${temporary.path}/state.json');
      const previous = '{"schema":1,"unread":"previous-data"}';
      await oldFile.writeAsString(previous);
      final loaded = await store.load();
      expect(loaded.accounts, isEmpty);
      expect(loaded.machines, isEmpty);
      expect(loaded.tasks, isEmpty);
      expect(loaded.themeMode, AppThemeMode.system);
      expect(await oldFile.readAsString(), previous);
      expect(await File('${temporary.path}/state-v2.json').exists(), false);
    },
  );

  test('theme preference survives a fresh local store instance', () async {
    for (final mode in AppThemeMode.values) {
      await store.save(SavedState(themeMode: mode));
      final reopened = TestLocalStore(temporary.path);
      expect((await reopened.load()).themeMode, mode);
      final saved = jsonDecode(
        await File('${temporary.path}/state-v2.json').readAsString(),
      );
      expect(saved['theme_mode'], mode.name);
    }
  });

  test(
    'credential pruning only removes unreferenced imported copies',
    () async {
      final credentials = Directory('${temporary.path}/credentials')
        ..createSync();
      final kept = File('${credentials.path}/kept')..writeAsStringSync('cert');
      final orphan = File('${credentials.path}/orphan')
        ..writeAsStringSync('ssh key');
      final pki = File('${temporary.path}/ca.key')..writeAsStringSync('ca');
      await store.pruneCredentials({kept.path});
      expect(kept.existsSync(), isTrue);
      expect(orphan.existsSync(), isFalse);
      expect(pki.existsSync(), isTrue);
      await TestLocalStore('${temporary.path}/fresh').pruneCredentials({});
    },
  );
  test('only picker copies inside the app cache are discarded', () async {
    final cache = Directory('${temporary.path}/cache')..createSync();
    final folder = Directory('${cache.path}/picked')..createSync();
    final copy = File('${folder.path}/id_ed25519')..writeAsStringSync('key');
    final shared = Directory('${cache.path}/shared')..createSync();
    final first = File('${shared.path}/a')..writeAsStringSync('a');
    File('${shared.path}/b').writeAsStringSync('b');
    final own = File('${temporary.path}/id_ed25519')..writeAsStringSync('key');
    await discardPickerCopy(copy.path, cache.path);
    await discardPickerCopy(first.path, cache.path);
    await discardPickerCopy(own.path, cache.path);
    expect(copy.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    expect(first.existsSync(), isFalse);
    expect(shared.existsSync(), isTrue);
    expect(cache.existsSync(), isTrue);
    expect(own.existsSync(), isTrue);
  });

  test('secret CRUD exclusively uses the v2 namespace', () async {
    FlutterSecureStorage.setMockInitialValues({
      'account.probe': 'previous-account',
      'task.probe': 'previous-task',
    });
    for (final key in ['account.probe', 'task.probe']) {
      expect(await store.readSecret(key), isNull);
      await store.writeSecret(key, 'current-data');
      expect(await store.readSecret(key), 'current-data');
      expect(await store.secure.read(key: 'v2.$key'), 'current-data');
      await store.deleteSecret(key);
      expect(await store.readSecret(key), isNull);
      await store.deleteSecret(key);
      expect(await store.readSecret(key), isNull);
    }
    expect(await store.secure.readAll(), {
      'account.probe': 'previous-account',
      'task.probe': 'previous-task',
    });
  });

  test('schema 2 saves atomically without replacing previous data', () async {
    final previous = File('${temporary.path}/state.json');
    await previous.writeAsString('previous-data');
    final current = File('${temporary.path}/state-v2.json');
    final original = SavedState(
      accounts: [Account(id: 'old', name: 'previous account', uid: '456')],
    ).encode();
    await current.writeAsString(original);
    final value = SavedState(
      accounts: [Account(id: 'a', name: '账号', uid: '123')],
    );
    var protected = false;
    store = TestLocalStore(
      temporary.path,
      protect: (path, mode) async {
        expect(p.equals(path, '${current.path}.tmp'), isTrue);
        expect(mode, '600');
        expect(await File(path).readAsString(), value.encode());
        expect(await current.readAsString(), original);
        await protectTestPath(path, mode);
        protected = true;
      },
    );
    await store.save(value);
    expect(protected, isTrue);
    expect(jsonDecode(await current.readAsString())['schema'], 2);
    expect((await store.load()).encode(), value.encode());
    expect(await previous.readAsString(), 'previous-data');
    expect(await File('${current.path}.tmp').exists(), false);
    if (Platform.isMacOS || Platform.isLinux) {
      expect((await current.stat()).mode & 0x1ff, 0x180);
    }
  });

  test('permission failure cannot replace the saved state', () async {
    final current = File('${temporary.path}/state-v2.json');
    final original = SavedState(
      accounts: [Account(id: 'old', name: 'previous account', uid: '456')],
    ).encode();
    await current.writeAsString(original);
    final next = SavedState(
      accounts: [Account(id: 'new', name: 'next account', uid: '789')],
    );
    var attempted = false;
    store = TestLocalStore(
      temporary.path,
      protect: (path, mode) async {
        expect(p.equals(path, '${current.path}.tmp'), isTrue);
        expect(mode, '600');
        expect(await File(path).readAsString(), next.encode());
        attempted = true;
        throw const UserError('synthetic permission failure');
      },
    );
    await expectLater(
      store.save(next),
      throwsA(
        isA<UserError>().having(
          (error) => error.message,
          'message',
          'synthetic permission failure',
        ),
      ),
    );
    expect(attempted, isTrue);
    expect(await current.readAsString(), original);
    expect((await store.load()).encode(), original);
  });

  test(
    'invalid current state is retained and never falls back to previous data',
    () async {
      final current = File('${temporary.path}/state-v2.json');
      final previous = File('${temporary.path}/state.json');
      await previous.writeAsString('previous-data');
      for (final invalid in ['invalid-json', '{"schema":1}']) {
        await current.writeAsString(invalid);
        await expectLater(
          store.load(),
          throwsA(
            isA<UserError>().having(
              (e) => e.message,
              'message',
              contains('state-v2.json'),
            ),
          ),
        );
        expect(await current.readAsString(), invalid);
        expect(await previous.readAsString(), 'previous-data');
      }
    },
  );

  group('macOS vault routing', () {
    late CountingSecureStorage keychain;
    late LocalStore mac;

    LocalStore newStore() => LocalStore(
      protect: protectTestPath,
      supportDirectory: () async => temporary,
      useEncryptedVault: true,
      secure: keychain,
    );

    setUp(() {
      keychain = CountingSecureStorage();
      mac = newStore();
    });

    test('accounts, tasks and cloud records share one session key', () async {
      await mac.load();
      final entries = {
        'account.a': 'synthetic-cookie-secret',
        'task.a': 'synthetic-buyer-secret',
        'cloud.preview.v1': 'synthetic-cloud-secret',
        'cloud.ssh-identity.v1': 'synthetic-ssh-secret',
      };
      await Future.wait([
        for (final entry in entries.entries)
          mac.writeSecret(entry.key, entry.value),
      ]);
      final another = newStore();
      await another.load();
      for (final entry in entries.entries) {
        expect(await another.readSecret(entry.key), entry.value);
      }
      await another.deleteSecret('account.a');
      await another.deleteSecret('account.a');
      expect(await mac.readSecret('account.a'), isNull);
      expect(await mac.readSecret('task.a'), entries['task.a']);
      expect(keychain.reads, [LocalStore.masterKeyName]);
      expect(keychain.writes, [LocalStore.masterKeyName]);
      expect(keychain.values.keys, [LocalStore.masterKeyName]);
      await for (final file in temporary.list(recursive: true)) {
        if (file is! File) continue;
        final bytes = await file.readAsString();
        for (final value in entries.values) {
          expect(bytes, isNot(contains(value)));
        }
        expect(
          bytes,
          isNot(contains(keychain.values[LocalStore.masterKeyName]!)),
        );
      }
    });

    test(
      'old state, secrets and imported credentials are left untouched',
      () async {
        final oldDirectory = Directory(p.join(temporary.path, 'MisakaNetwork'));
        final credentials = Directory(p.join(oldDirectory.path, 'credentials'));
        await credentials.create(recursive: true);
        final oldKey = File(p.join(credentials.path, 'old-key'));
        await oldKey.writeAsString('synthetic-old-private-key');
        final oldState = File(
          p.join(oldDirectory.path, LocalStore.stateFilename),
        );
        final original = SavedState(
          accounts: [Account(id: 'old', name: 'old', uid: '123')],
        ).encode();
        await oldState.writeAsString(original);
        keychain.values['v2.account.old'] = 'synthetic-old-cookie';
        final state = await mac.load();
        expect(state.accounts, isEmpty);
        expect(await mac.readSecret('account.old'), isNull);
        await mac.pruneCredentials({});
        await mac.save(SavedState(themeMode: AppThemeMode.dark));
        expect((await newStore().load()).themeMode, AppThemeMode.dark);
        expect(await oldState.readAsString(), original);
        expect(await oldKey.readAsString(), 'synthetic-old-private-key');
        expect(keychain.values['v2.account.old'], 'synthetic-old-cookie');
        expect(keychain.reads, [LocalStore.masterKeyName]);
        expect(
          await mac.directory(),
          p.join(oldDirectory.path, LocalStore.macosStorageDirectory),
        );
      },
    );

    test(
      'denied unlock fails startup without repeated background prompts',
      () async {
        keychain.denyRead = true;
        await expectLater(mac.load(), throwsA(isA<UserError>()));
        await expectLater(newStore().load(), throwsA(isA<UserError>()));
        await expectLater(
          mac.readSecret('account.a'),
          throwsA(isA<UserError>()),
        );
        await expectLater(
          mac.writeSecret('task.a', 'secret'),
          throwsA(isA<UserError>()),
        );
        expect(keychain.reads, [LocalStore.masterKeyName]);
        expect(keychain.writes, isEmpty);
      },
    );

    test(
      'a linked storage root is rejected before accessing the keychain',
      () async {
        if (!Platform.isMacOS && !Platform.isLinux) return;
        final other = await Directory.systemTemp.createTemp(
          'lastorder-unrelated-',
        );
        try {
          await Link(p.join(temporary.path, 'MisakaNetwork'))
              .create(other.path);
          await expectLater(mac.load(), throwsA(isA<UserError>()));
          expect(keychain.reads, isEmpty);
          expect(await other.list().toList(), isEmpty);
        } finally {
          await other.delete(recursive: true);
        }
      },
    );
  });
}
