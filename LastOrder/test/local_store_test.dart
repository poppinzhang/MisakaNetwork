import 'dart:convert';
import 'dart:io';

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
  TestLocalStore(this.path, {super.protect = protectTestPath});
  final String path;
  @override
  Future<String> directory() async => path;
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
      expect(await oldFile.readAsString(), previous);
      expect(await File('${temporary.path}/state-v2.json').exists(), false);
    },
  );

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
}
