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
    final pidPathLiteral = pidFile.path.replaceAll("'", "''");
    int? childPid;
    try {
      await expectLater(
        runJsonProcess(
          powershell,
          script('''
\$null = [Console]::In.ReadToEnd();
\$child = [System.Diagnostics.Process]::Start('ping.exe', '-n 60 127.0.0.1');
[System.IO.File]::WriteAllText('$pidPathLiteral', \$child.Id.ToString());
[System.Threading.Thread]::Sleep(60000);
'''),
          {'pid_file': pidFile.path},
          timeout: const Duration(seconds: 5),
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
