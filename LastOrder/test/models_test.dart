import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';

void main() {
  final machine = Machine(
    id: 'node',
    name: 'Sisters',
    host: 'node.example',
    caCert: 'ca.pem',
    clientCert: 'client.pem',
    clientKey: 'client.key',
  );

  test('new machines use the commemorative default port', () {
    expect(machine.port, 20001);
    expect(machine.toJson()['port'], 20001);
  });

  test('machines without a saved port use the default port', () {
    final json = machine.toJson()..remove('port');
    expect(Machine.fromJson(json).port, 20001);
  });

  test('explicit machine ports survive serialization', () {
    final custom = Machine(
      id: 'custom',
      name: 'Custom Sisters',
      host: 'node.example',
      port: 24443,
      caCert: 'ca.pem',
      clientCert: 'client.pem',
      clientKey: 'client.key',
    );
    expect(custom.port, 24443);
    expect(Machine.fromJson(custom.toJson()).port, 24443);
  });
}
