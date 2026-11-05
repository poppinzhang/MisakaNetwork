import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';
import 'package:path/path.dart' as p;

void main() {
  if (!Platform.isWindows) return;
  final powershell = p.windows.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  List<String> script(String command) => [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ];

  test('Windows helper decodes success and rejects nonzero exit', () async {
    const response = r'''$null = [Console]::In.ReadToEnd();
[Console]::WriteLine('{"ok":true,"result":{"ready":true}}');''';
    expect(await runJsonProcess(powershell, script(response), {}), {
      'ready': true,
    });
    await expectLater(
      runJsonProcess(powershell, script('$response exit 2;'), {}),
      throwsA(isA<UserError>()),
    );
    expect(activeChildProcessCount, 0);
  });

  test('Windows deadline covers blocked stdin', () async {
    final timer = Stopwatch()..start();
    await expectLater(
      runJsonProcess(powershell, script('Start-Sleep -Seconds 60'), {
        'payload': 'x' * (2 * 1024 * 1024),
      }, timeout: const Duration(milliseconds: 200)),
      throwsA(isA<UserError>()),
    );
    expect(timer.elapsed, lessThan(const Duration(seconds: 8)));
    expect(activeChildProcessCount, 0);
  });

  test('Windows timeout terminates helper descendants', () async {
    final directory = await Directory.systemTemp.createTemp(
      'misaka-tree-test-',
    );
    final pidFile = File(p.join(directory.path, 'child.pid'));
    int? childPid;
    try {
      await expectLater(
        runJsonProcess(
          powershell,
          script(r'''
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json;
$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru;
[System.IO.File]::WriteAllText($request.pid_file, $child.Id.ToString());
Start-Sleep -Seconds 60;
'''),
          {'pid_file': pidFile.path},
          timeout: const Duration(seconds: 3),
        ),
        throwsA(isA<UserError>()),
      );
      expect(await pidFile.exists(), isTrue, reason: 'descendant must start');
      childPid = int.parse((await pidFile.readAsString()).trim());
      final check = await Process.run(
        powershell,
        script(
          '[Console]::Write((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -ne \$null)',
        ),
      );
      expect((check.stdout as String).trim(), 'False');
      expect(activeChildProcessCount, 0);
    } finally {
      if (childPid != null) Process.killPid(childPid, ProcessSignal.sigkill);
      await directory.delete(recursive: true);
    }
  });
}
