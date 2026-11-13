import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/encrypted_vault.dart';
import 'package:path/path.dart' as p;

class _KeyStore {
  String? value;
  int reads = 0, writes = 0;
  bool denyRead = false, denyWrite = false;
  Future<void>? readDelay;

  Future<String?> read() async {
    reads++;
    await readDelay;
    if (denyRead) throw StateError('private-keychain-details');
    return value;
  }

  Future<void> write(String value) async {
    writes++;
    if (denyWrite) throw StateError('private-keychain-details');
    this.value = value;
  }
}

Future<void> _protect(String path, String mode) async {
  if (Platform.isMacOS || Platform.isLinux) {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) throw const FileSystemException();
  }
}

void main() {
  late Directory temporary;
  late Directory directory;
  late _KeyStore keys;
  late EncryptedVault vault;
  File file() => File(p.join(directory.path, EncryptedVault.filename));
  EncryptedVault create({Future<void> Function(String, String)? protect}) =>
      EncryptedVault(
        directory: directory,
        readMasterKey: keys.read,
        writeMasterKey: keys.write,
        protect: protect ?? _protect,
      );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lastorder-vault-test-');
    directory = Directory(p.join(temporary.path, 'vault'));
    keys = _KeyStore();
    vault = create();
  });
  tearDown(() async => temporary.delete(recursive: true));

  test(
    'empty first open creates one 256-bit key and authenticated file',
    () async {
      await vault.open();
      expect(keys.reads, 1);
      expect(keys.writes, 1);
      expect(base64Decode(keys.value!), hasLength(32));
      expect(await file().exists(), isTrue);
      expect(await vault.read('absent'), isNull);
      await vault.delete('absent');
      await vault.open();
      expect(keys.reads, 1);
      expect(keys.writes, 1);
    },
  );

  test(
    'all secret types survive reopen without plaintext disk copies',
    () async {
      const values = {
        'account.example': '[{"name":"SESSDATA","value":"synthetic-cookie"}]',
        'task.example': '{"buyer":"虚构姓名","phone":"test-phone"}',
        'cloud.preview.v1': '{"secret":"synthetic-cloud-key"}',
        'cloud.ssh-identity.v1': 'synthetic-ssh-private-key',
      };
      for (final entry in values.entries) {
        await vault.write(entry.key, entry.value);
      }
      final key = keys.value;
      final reopened = create();
      for (final entry in values.entries) {
        expect(await reopened.read(entry.key), entry.value);
      }
      expect(keys.reads, 2);
      expect(keys.writes, 1);
      expect(keys.value, key);
      for (final entity in await directory.list().toList()) {
        final text = await File(entity.path).readAsString();
        for (final entry in values.entries) {
          expect(text, isNot(contains(entry.key)));
          expect(text, isNot(contains(entry.value)));
        }
        expect(text, isNot(contains(key!)));
      }
      expect(await File('${file().path}.tmp').exists(), isFalse);
    },
  );

  test('concurrent initial reads unlock once', () async {
    final release = Completer<void>();
    keys.readDelay = release.future;
    final reads = [for (var i = 0; i < 15; i++) vault.read('account.$i')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    expect(await Future.wait(reads), everyElement(isNull));
    expect(keys.reads, 1);
    expect(keys.writes, 1);
  });

  test(
    'concurrent writes and deletes preserve every unrelated record',
    () async {
      await Future.wait([
        for (var i = 0; i < 20; i++) vault.write('account.$i', 'value-$i'),
      ]);
      await Future.wait([
        for (var i = 0; i < 10; i++) vault.delete('account.$i'),
        for (var i = 20; i < 30; i++) vault.write('account.$i', 'value-$i'),
      ]);
      for (var i = 0; i < 30; i++) {
        expect(await vault.read('account.$i'), i < 10 ? null : 'value-$i');
      }
      expect(keys.reads, 1);
    },
  );

  test(
    'separate instances serialize changes and reload latest ciphertext',
    () async {
      final second = create();
      await Future.wait([
        for (var i = 0; i < 12; i++)
          (i.isEven ? vault : second).write('task.$i', 'value-$i'),
      ]);
      for (var i = 0; i < 12; i++) {
        expect(await vault.read('task.$i'), 'value-$i');
        expect(await second.read('task.$i'), 'value-$i');
      }
      expect(keys.writes, 1);
    },
  );

  test(
    'overwriting identical plaintext uses a fresh nonce and ciphertext',
    () async {
      await vault.write('account.a', 'same-value');
      final first = jsonDecode(await file().readAsString()) as Map;
      await vault.write('account.a', 'same-value');
      final second = jsonDecode(await file().readAsString()) as Map;
      expect(second['nonce'], isNot(first['nonce']));
      expect(second['ciphertext'], isNot(first['ciphertext']));
      expect(base64Decode(second['nonce'] as String), hasLength(12));
      expect(base64Decode(second['mac'] as String), hasLength(16));
      expect(await vault.read('account.a'), 'same-value');
    },
  );

  test(
    'deletion persists and repeated deletion does not replace the file',
    () async {
      await vault.write('account.a', 'cookie-a');
      await vault.write('task.b', 'task-b');
      await vault.delete('account.a');
      final afterDelete = await file().readAsBytes();
      await vault.delete('account.a');
      expect(await file().readAsBytes(), afterDelete);
      final reopened = create();
      expect(await reopened.read('account.a'), isNull);
      expect(await reopened.read('task.b'), 'task-b');
    },
  );

  test('keychain read denial is cached without a prompt retry storm', () async {
    keys.denyRead = true;
    for (var i = 0; i < 3; i++) {
      await expectLater(vault.open(), throwsA(isA<VaultException>()));
    }
    keys.denyRead = false;
    await expectLater(vault.write('a', 'b'), throwsA(isA<VaultException>()));
    expect(keys.reads, 1);
    expect(keys.writes, 0);
    expect(await file().exists(), isFalse);
    await create().open();
    expect(keys.reads, 2);
  });

  test(
    'keychain write failure caches the error and creates no vault',
    () async {
      keys.denyWrite = true;
      await expectLater(vault.write('a', 'b'), throwsA(isA<VaultException>()));
      await expectLater(vault.read('a'), throwsA(isA<VaultException>()));
      expect(keys.reads, 1);
      expect(keys.writes, 1);
      expect(await file().exists(), isFalse);
    },
  );

  test('missing master key never overwrites existing ciphertext', () async {
    await vault.write('a', 'saved');
    final original = await file().readAsBytes();
    keys.value = null;
    final reopened = create();
    await expectLater(reopened.read('a'), throwsA(isA<VaultException>()));
    await expectLater(
      reopened.write('b', 'new'),
      throwsA(isA<VaultException>()),
    );
    expect(keys.writes, 1);
    expect(await file().readAsBytes(), original);
  });

  for (final invalid in [
    'invalid-base64!',
    base64Encode([1, 2, 3]),
    '',
  ]) {
    test(
      'invalid master key is preserved and fails closed: ${invalid.length}',
      () async {
        await vault.write('a', 'saved');
        final original = await file().readAsBytes();
        keys.value = invalid;
        await expectLater(create().open(), throwsA(isA<VaultException>()));
        expect(keys.value, invalid);
        expect(keys.writes, 1);
        expect(await file().readAsBytes(), original);
      },
    );
  }

  test(
    'different valid key fails authentication without changing data',
    () async {
      await vault.write('a', 'saved');
      final original = await file().readAsBytes();
      keys.value = base64Encode(List<int>.filled(32, 17));
      await expectLater(create().open(), throwsA(isA<VaultException>()));
      expect(await file().readAsBytes(), original);
      expect(keys.writes, 1);
    },
  );

  test(
    'missing file with an existing key never starts an empty vault',
    () async {
      await vault.write('a', 'saved');
      await file().delete();
      for (final instance in [vault, create()]) {
        await expectLater(instance.read('a'), throwsA(isA<VaultException>()));
        await expectLater(
          instance.write('b', 'new'),
          throwsA(isA<VaultException>()),
        );
      }
      expect(await file().exists(), isFalse);
      expect(keys.writes, 1);
    },
  );

  for (final component in ['nonce', 'ciphertext', 'mac']) {
    test('tampered $component blocks reads writes and deletes', () async {
      await vault.write('a', 'saved');
      final envelope = jsonDecode(await file().readAsString()) as Map;
      final bytes = base64Decode(envelope[component] as String);
      bytes[0] ^= 1;
      envelope[component] = base64Encode(bytes);
      final corrupt = jsonEncode(envelope);
      await file().writeAsString(corrupt);
      await expectLater(vault.read('a'), throwsA(isA<VaultException>()));
      await expectLater(
        vault.write('b', 'new'),
        throwsA(isA<VaultException>()),
      );
      await expectLater(vault.delete('a'), throwsA(isA<VaultException>()));
      expect(await file().readAsString(), corrupt);
      expect(keys.reads, 1);
    });
  }

  for (final content in [
    'not-json',
    '{"a":"plaintext-is-not-a-vault"}',
    '{"version":2,"nonce":"","ciphertext":"","mac":""}',
    '{"version":1,"nonce":"!","ciphertext":"","mac":""}',
    '{"version":1,"nonce":"","ciphertext":"","mac":""}',
  ]) {
    test('malformed envelope fails closed: $content', () async {
      await vault.open();
      await file().writeAsString(content);
      await expectLater(vault.open(), throwsA(isA<VaultException>()));
      await expectLater(vault.write('a', 'b'), throwsA(isA<VaultException>()));
      expect(await file().readAsString(), content);
    });
  }

  test('authenticated plaintext must be a string map', () async {
    await vault.open();
    for (final plaintext in ['[]', '{"a":123}', '{"a":null}', 'not-json']) {
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(plaintext),
        secretKey: SecretKey(base64Decode(keys.value!)),
        aad: utf8.encode('MisakaNetwork.LastOrder.secrets-v1.AES-256-GCM'),
      );
      final original = jsonEncode({
        'version': 1,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      await file().writeAsString(original);
      await expectLater(vault.open(), throwsA(isA<VaultException>()));
      expect(await file().readAsString(), original);
    }
  });

  test(
    'permission failure preserves prior ciphertext and releases queue',
    () async {
      await vault.write('a', 'original');
      final original = await file().readAsBytes();
      var fail = true;
      final instance = create(
        protect: (path, mode) async {
          if (path.endsWith('.tmp') && fail) throw StateError('private-path');
          await _protect(path, mode);
        },
      );
      await expectLater(
        instance.write('a', 'new'),
        throwsA(isA<VaultException>()),
      );
      expect(await file().readAsBytes(), original);
      expect(await File('${file().path}.tmp').exists(), isFalse);
      expect(await instance.read('a'), 'original');
      fail = false;
      await instance.write('a', 'recovered');
      expect(await instance.read('a'), 'recovered');
    },
  );

  test(
    'interrupted first bootstrap never silently resets on next launch',
    () async {
      final instance = create(
        protect: (path, mode) async {
          if (path.endsWith('.tmp')) throw const FileSystemException();
          await _protect(path, mode);
        },
      );
      await expectLater(instance.open(), throwsA(isA<VaultException>()));
      expect(keys.value, isNotNull);
      expect(await file().exists(), isFalse);
      await expectLater(create().open(), throwsA(isA<VaultException>()));
      expect(keys.writes, 1);
    },
  );

  test(
    'orphan ciphertext temp is replaced only after verifying main file',
    () async {
      await vault.write('a', 'saved');
      final temp = File('${file().path}.tmp');
      await temp.writeAsString('abandoned-ciphertext');
      await vault.write('b', 'next');
      expect(await vault.read('a'), 'saved');
      expect(await vault.read('b'), 'next');
      expect(await temp.exists(), isFalse);
      await temp.writeAsString('recoverable-temporary-file');
      await file().writeAsString('damaged');
      await expectLater(
        vault.write('c', 'blocked'),
        throwsA(isA<VaultException>()),
      );
      expect(await temp.readAsString(), 'recoverable-temporary-file');
    },
  );

  test('files and directory receive private permissions', () async {
    await vault.write('a', 'saved');
    if (Platform.isMacOS || Platform.isLinux) {
      expect((await directory.stat()).mode & 0x1ff, 0x1c0);
      for (final entity in await directory.list().toList()) {
        expect((await entity.stat()).mode & 0x1ff, 0x180);
      }
    }
  });

  test('orphan temp alone cannot be discarded by a fresh bootstrap', () async {
    await directory.create();
    final temp = File('${file().path}.tmp');
    await temp.writeAsString('only-surviving-ciphertext');
    await expectLater(vault.open(), throwsA(isA<VaultException>()));
    await expectLater(vault.write('a', 'new'), throwsA(isA<VaultException>()));
    expect(keys.reads, 0);
    expect(keys.writes, 0);
    expect(await file().exists(), isFalse);
    expect(await temp.readAsString(), 'only-surviving-ciphertext');
  });

  test(
    'existing metadata blocks recreation when both key and vault are gone',
    () async {
      await directory.create();
      final metadata = File(p.join(directory.path, 'state-v2.json'));
      await metadata.writeAsString('{"schema":2,"account":"existing"}');
      final original = await metadata.readAsString();
      final instance = EncryptedVault(
        directory: directory,
        metadataFile: metadata,
        readMasterKey: keys.read,
        writeMasterKey: keys.write,
        protect: _protect,
      );
      await expectLater(instance.open(), throwsA(isA<VaultException>()));
      await expectLater(
        instance.write('a', 'new'),
        throwsA(isA<VaultException>()),
      );
      expect(keys.reads, 0);
      expect(keys.writes, 0);
      expect(await file().exists(), isFalse);
      expect(await metadata.readAsString(), original);
    },
  );

  test('nonregular metadata also blocks a fresh bootstrap', () async {
    await directory.create();
    final metadata = File(p.join(directory.path, 'state-v2.json'));
    await Directory(metadata.path).create();
    final instance = EncryptedVault(
      directory: directory,
      metadataFile: metadata,
      readMasterKey: keys.read,
      writeMasterKey: keys.write,
      protect: _protect,
    );
    await expectLater(instance.open(), throwsA(isA<VaultException>()));
    expect(keys.reads, 0);
    expect(keys.writes, 0);
    expect(await file().exists(), isFalse);
  });

  test(
    'another process holding the vault lock produces a bounded error',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      await vault.open();
      final process = await Process.start('python3', [
        '-c',
        'import fcntl, sys\n'
            'handle = open(sys.argv[1], "a")\n'
            'fcntl.lockf(handle, fcntl.LOCK_EX)\n'
            'print("locked", flush=True)\n'
            'sys.stdin.read()\n',
        '${file().path}.lock',
      ]);
      try {
        final ready = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        expect(ready, 'locked');
        final contended = EncryptedVault(
          directory: directory,
          readMasterKey: keys.read,
          writeMasterKey: keys.write,
          protect: _protect,
          lockTimeout: const Duration(milliseconds: 100),
        );
        await expectLater(
          contended.open(),
          throwsA(
            isA<VaultException>().having(
              (error) => error.message,
              'message',
              contains('另一个 LastOrder'),
            ),
          ),
        );
        expect(keys.reads, 1);
      } finally {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      await vault.write('after-lock', 'ok');
      expect(await vault.read('after-lock'), 'ok');
    },
  );

  for (final suffix in ['', '.tmp', '.lock']) {
    test(
      'symlink $suffix is rejected without reading or changing target',
      () async {
        if (!Platform.isMacOS && !Platform.isLinux) return;
        await vault.write('a', 'saved');
        final target = File(p.join(temporary.path, 'target'));
        await target.writeAsString('private-target');
        final unsafePath = '${file().path}$suffix';
        final existing = File(unsafePath);
        if (await existing.exists()) await existing.delete();
        await Link(unsafePath).create(target.path);
        await expectLater(
          vault.write('a', 'blocked'),
          throwsA(isA<VaultException>()),
        );
        expect(await target.readAsString(), 'private-target');
        expect(await FileSystemEntity.isLink(unsafePath), isTrue);
      },
    );
  }

  test('directory symlink is rejected before accessing keychain', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final target = Directory(p.join(temporary.path, 'other'));
    await target.create();
    await Link(directory.path).create(target.path);
    await expectLater(vault.open(), throwsA(isA<VaultException>()));
    expect(keys.reads, 0);
    expect(await target.list().toList(), isEmpty);
  });

  test('nonregular ciphertext target is rejected', () async {
    await directory.create();
    await Directory(file().path).create();
    await expectLater(vault.open(), throwsA(isA<VaultException>()));
    expect(keys.reads, 0);
  });

  test(
    'error messages contain no secrets, paths, or underlying exceptions',
    () async {
      keys.denyRead = true;
      try {
        await vault.open();
        fail('expected a storage failure');
      } on VaultException catch (error) {
        expect(error.message, isNot(contains('private-keychain-details')));
        expect(error.message, isNot(contains(temporary.path)));
        expect(error.toString(), error.message);
      }
    },
  );
}
