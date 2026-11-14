import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:last_order/src/services.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'embedded helper inherits sandbox and creates a private mTLS identity',
    (tester) async {
      final directory = await Directory(await LocalStore().directory())
          .createTemp('integration-pki-');
      try {
        final identity = await LocalHelper().call({
          'action': 'init_pki',
          'directory': directory.path,
        });
        for (final name in ['ca_cert', 'client_cert', 'client_key']) {
          final file = File(identity[name] as String);
          expect(p.isWithin(directory.path, file.path), isTrue);
          expect(await file.exists(), isTrue);
          if (!Platform.isWindows) {
            expect((await file.stat()).mode & 0x1ff, 0x180);
          }
        }
        final repeated = await LocalHelper().call({
          'action': 'init_pki',
          'directory': directory.path,
        });
        expect(repeated, identity);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'embedded runtime reports the current release inside the sandbox',
    (tester) async {
      final result = await LocalRuntime().call('ping', {});
      expect(result['ready'], true);
      expect(result['version'], '0.3.2');
      expect(result['bili_version'], '2.15.18');
      expect(result['protocol'], 1);
      expect(activeChildProcessCount, 0);
    },
  );
}
