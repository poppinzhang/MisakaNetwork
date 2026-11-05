import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/services.dart';
import 'package:last_order/src/models.dart';

void main() {
  if (Platform.isWindows) return;
  test('process bridge ignores progress and decodes terminal result', () async {
    final result = await runJsonProcess(
      '/bin/sh',
      [
        '-c',
        '''cat >/dev/null
printf '%s\\n' '{"type":"progress","message":"ready"}' '{"type":"result","ok":true,"data":{"ready":true}}'
''',
      ],
      {},
      bridge: true,
    );
    expect(result, {'ready': true});
  });
  test('nonzero exit never reports success', () async {
    await expectLater(
      runJsonProcess('/bin/sh', [
        '-c',
        '''cat >/dev/null
printf '%s\\n' '{"ok":true,"result":{}}'
exit 2
''',
      ], {}),
      throwsA(isA<UserError>()),
    );
  });
  test('helper fingerprint is a confirmation request, never success', () async {
    final result = await runJsonProcess('/bin/sh', [
      '-c',
      '''cat >/dev/null
printf '%s\\n' '{"ok":false,"error":"confirm","fingerprint":"SHA256:test"}'
exit 1
''',
    ], {});
    expect(result, {'fingerprint': 'SHA256:test', 'needs_confirmation': true});
  });
  test('missing result and process timeout return actionable error', () async {
    await expectLater(
      runJsonProcess('/bin/sh', ['-c', 'cat >/dev/null'], {}, bridge: true),
      throwsA(isA<UserError>()),
    );
    await expectLater(
      runJsonProcess(
        '/bin/sh',
        ['-c', 'cat >/dev/null; exec sleep 20'],
        {},
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<UserError>()),
    );
  });
  test('oversized response is killed without buffering beyond limit', () async {
    await expectLater(
      runJsonProcess('/bin/sh', [
        '-c',
        'cat >/dev/null; head -c 8388609 /dev/zero',
      ], {}),
      throwsA(isA<UserError>()),
    );
  });
  test(
    'deadline also covers a child that never reads a large stdin request',
    () async {
      final timer = Stopwatch()..start();
      await expectLater(
        runJsonProcess(
          '/bin/sh',
          ['-c', 'exec sleep 20'],
          {'payload': 'x' * (2 * 1024 * 1024)},
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<UserError>()),
      );
      expect(timer.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );
  test('application exit stops only tracked local child processes', () async {
    final request = runJsonProcess('/bin/sh', [
      '-c',
      'cat >/dev/null; exec sleep 20',
    ], {});
    final completed = expectLater(request, throwsA(isA<UserError>()));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (activeChildProcessCount == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(activeChildProcessCount, 1);
    await terminateAllChildProcesses();
    await completed;
    expect(activeChildProcessCount, 0);
  });
  test(
    'timeout releases output pipes inherited by a surviving descendant',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'misaka-pipe-test-',
      );
      final pidFile = File('${directory.path}/child.pid');
      try {
        final timer = Stopwatch()..start();
        await expectLater(
          runJsonProcess(
            '/bin/sh',
            [
              '-c',
              'cat >/dev/null; sleep 20 & echo \$! > "\$1"; exit 0',
              'fixture',
              pidFile.path,
            ],
            {},
            timeout: const Duration(milliseconds: 100),
          ),
          throwsA(isA<UserError>()),
        );
        expect(timer.elapsed, lessThan(const Duration(seconds: 2)));
        expect(activeChildProcessCount, 0);
      } finally {
        if (await pidFile.exists()) {
          Process.killPid(
            int.parse((await pidFile.readAsString()).trim()),
            ProcessSignal.sigkill,
          );
        }
        await directory.delete(recursive: true);
      }
    },
  );
}
