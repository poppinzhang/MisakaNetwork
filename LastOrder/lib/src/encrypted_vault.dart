import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// A storage error safe to display: never contains secrets or local paths.
class VaultException implements Exception {
  const VaultException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One session's key, protecting a local map of secret strings.
///
/// The caller shares this instance for the app session. Only the master key is
/// cached; each operation authenticates the file again while holding its lock.
/// Neither the old keychain namespace nor plaintext files are consulted.
class EncryptedVault {
  EncryptedVault({
    required this.directory,
    required this.readMasterKey,
    required this.writeMasterKey,
    required this.protect,
    this.metadataFile,
    this.lockTimeout = const Duration(seconds: 10),
  });

  static const filename = 'secrets-v1.json';
  static const formatVersion = 1;
  static const _maxFileBytes = 32 * 1024 * 1024;
  static final _aad = utf8.encode(
    'MisakaNetwork.LastOrder.secrets-v1.AES-256-GCM',
  );
  static final _queues = <String, Future<void>>{};
  final Directory directory;
  final Future<String?> Function() readMasterKey;
  final Future<void> Function(String value) writeMasterKey;
  final Future<void> Function(String path, String mode) protect;

  /// Existing application state means this is not a fresh installation, even
  /// if both its ciphertext and master key have gone missing.
  final File? metadataFile;
  final Duration lockTimeout;
  final AesGcm _cipher = AesGcm.with256bits();
  Future<SecretKey>? _key;
  bool _newKey = false;
  bool _sawFile = false;

  File get _file => File(p.join(directory.path, filename));
  File get _temporary => File('${_file.path}.tmp');
  File get _lockFile => File('${_file.path}.lock');

  Future<void> open() => _serialized(() async {
    await _readValues();
  });

  Future<String?> read(String key) =>
      _serialized(() async => (await _readValues())[key]);

  Future<void> write(String key, String value) => _serialized(() async {
    final values = await _readValues();
    values[key] = value;
    await _writeValues(values);
  });

  Future<void> delete(String key) => _serialized(() async {
    final values = await _readValues();
    if (values.remove(key) != null) await _writeValues(values);
  });

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    // POSIX locks alone do not serialize separate handles in one process.
    final queueKey = p.normalize(p.absolute(directory.path));
    final previous = _queues[queueKey] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[queueKey] = done.future;
    await previous;
    RandomAccessFile? handle;
    var locked = false;
    try {
      await _prepareDirectory();
      await _requireRegular(_lockFile, allowMissing: true);
      // File.create does not truncate an existing lock file. A second process
      // may create it after the preceding check; both must lock the same inode.
      await _lockFile.create();
      await _requireRegular(_lockFile);
      await protect(_lockFile.path, '600');
      handle = await _lockFile.open(mode: FileMode.append);
      await _lock(handle);
      locked = true;
      return await operation();
    } on VaultException {
      rethrow;
    } catch (_) {
      throw const VaultException('本地加密资料无法读取或保存。现有资料未重置，请检查存储权限后重试。');
    } finally {
      try {
        if (locked) await handle!.unlock();
      } catch (_) {
        // Closing the handle also releases its lock. Never leak OS diagnostics.
      }
      try {
        await handle?.close();
      } catch (_) {
        // This handle only owns an empty advisory lock, not pending file data.
      }
      done.complete();
      if (identical(_queues[queueKey], done.future)) {
        _queues.remove(queueKey);
      }
    }
  }

  Future<void> _lock(RandomAccessFile handle) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        return;
      } on FileSystemException catch (error) {
        // Nonblocking POSIX lock contention: do not wait forever on another app.
        if (!{11, 13, 35}.contains(error.osError?.errorCode)) rethrow;
        if (elapsed.elapsed >= lockTimeout) {
          throw const VaultException('本地加密资料正在被另一个 LastOrder 使用，请稍后重试。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _prepareDirectory() async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const VaultException('本地加密资料目录无效。请检查存储位置，现有资料未重置。');
    }
    await protect(directory.path, '700');
  }

  Future<bool> _requireRegular(File file, {bool allowMissing = false}) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && allowMissing) return false;
    if (type != FileSystemEntityType.file) {
      throw const VaultException('本地加密资料文件类型无效。现有资料未重置，请检查后重试。');
    }
    return true;
  }

  Future<SecretKey> _unlock(bool fileExists) async {
    String? stored;
    try {
      stored = await readMasterKey();
    } catch (_) {
      throw const VaultException('无法取得本地资料加密密钥。请允许钥匙串访问后重新打开 LastOrder。');
    }
    if (stored == null) {
      if (fileExists || _sawFile) {
        throw const VaultException('本地资料加密密钥缺失。现有加密资料已保留，无法自动恢复或重置。');
      }
      final key = await _cipher.newSecretKey();
      try {
        await writeMasterKey(base64Encode(await key.extractBytes()));
      } catch (_) {
        throw const VaultException('无法保存本地资料加密密钥。请检查钥匙串权限后重新打开 LastOrder。');
      }
      _newKey = true;
      return key;
    }
    List<int> bytes;
    try {
      bytes = base64Decode(stored);
      if (bytes.length != 32) throw const FormatException();
    } catch (_) {
      throw const VaultException('本地资料加密密钥无效。现有资料已保留，请恢复原密钥后重新打开 LastOrder。');
    }
    if (!fileExists) {
      // A previous bootstrap may have been interrupted. Never interpret a
      // missing vault with an existing key as permission to discard old data.
      throw const VaultException('本地加密资料文件缺失。现有密钥已保留，请恢复资料后重新打开 LastOrder。');
    }
    return SecretKey(bytes);
  }

  Future<Map<String, String>> _readValues() async {
    final exists = await _requireRegular(_file, allowMissing: true);
    final metadata = metadataFile;
    if (!exists &&
        metadata != null &&
        await FileSystemEntity.type(metadata.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const VaultException('本地配置仍存在，但加密资料文件缺失。现有配置已保留，请恢复资料后重试。');
    }
    if (!exists && await _requireRegular(_temporary, allowMissing: true)) {
      // The temp may be the only surviving ciphertext after an interrupted
      // operation. Its presence is not authorization to discard it or re-key.
      throw const VaultException('本地加密资料尚未完整保存。临时文件已保留，请恢复资料后重试。');
    }
    final key = await (_key ??= _unlock(exists));
    if (!exists) {
      if (_sawFile || !_newKey) {
        throw const VaultException('本地加密资料文件缺失。现有密钥已保留，请恢复资料后重试。');
      }
      // Persist an authenticated empty vault even on the first read. A key
      // without a vault on a later launch is treated as a recovery problem.
      await _writeValues({});
      return {};
    }
    _sawFile = true;
    await protect(_file.path, '600');
    try {
      if (await _file.length() > _maxFileBytes) throw const FormatException();
      final envelope = jsonDecode(await _file.readAsString());
      if (envelope is! Map<String, dynamic> ||
          envelope.length != 4 ||
          envelope['version'] != formatVersion ||
          envelope['nonce'] is! String ||
          envelope['ciphertext'] is! String ||
          envelope['mac'] is! String) {
        throw const FormatException();
      }
      final nonce = base64Decode(envelope['nonce'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      if (nonce.length != 12 || mac.length != 16) {
        throw const FormatException();
      }
      final plaintext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad,
      );
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic> ||
          decoded.values.any((value) => value is! String)) {
        throw const FormatException();
      }
      return decoded.cast<String, String>();
    } catch (_) {
      throw const VaultException('本地加密资料损坏或无法通过校验。原文件已保留，请恢复资料后重试。');
    }
  }

  Future<void> _writeValues(Map<String, String> values) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(values)),
      secretKey: await _key!,
      nonce: _cipher.newNonce(),
      aad: _aad,
    );
    final encoded = utf8.encode(
      jsonEncode({
        'version': formatVersion,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
    );
    if (encoded.length > _maxFileBytes) {
      throw const VaultException('本地加密资料超出大小限制，现有资料未更改。');
    }
    // A stale temporary file is only discarded after the authoritative vault
    // was authenticated (or a brand-new key was successfully stored).
    if (await _requireRegular(_temporary, allowMissing: true)) {
      await _temporary.delete();
    }
    var created = false;
    try {
      await _temporary.create(exclusive: true);
      created = true;
      await protect(_temporary.path, '600');
      await _temporary.writeAsBytes(encoded, flush: true);
      await _requireRegular(_file, allowMissing: true);
      await _temporary.rename(_file.path);
      _sawFile = true;
      _newKey = false;
    } finally {
      if (created &&
          await FileSystemEntity.type(_temporary.path, followLinks: false) ==
              FileSystemEntityType.file) {
        await _temporary.delete();
      }
    }
  }
}
