import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';

Future<int> closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Machine node(int port, {String directory = '/missing'}) => Machine(
  id: 'node',
  name: 'node',
  host: '127.0.0.1',
  port: port,
  caCert: '$directory/ca',
  clientCert: '$directory/cert',
  clientKey: '$directory/key',
);

class RejectingSisters extends SistersServiceBase {
  GrpcError failure = const GrpcError.invalidArgument('private-task-detail');

  @override
  Future<AgentStatus> getStatus(ServiceCall call, Empty request) async =>
      throw failure;

  @override
  Future<TaskStatus> submitTask(ServiceCall call, TaskRequest request) async =>
      throw failure;

  @override
  Future<TaskStatus> cancelTask(ServiceCall call, TaskId request) async =>
      throw failure;
}

void main() {
  test(
    'only explicit submit rejection codes release an execution intent',
    () async {
      final service = RejectingSisters();
      final server = Server.create(services: [service]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      addTearDown(server.shutdown);
      final channel = ClientChannel(
        '127.0.0.1',
        port: server.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      addTearDown(channel.shutdown);
      final gateway = GrpcGateway(open: (_) async => channel);
      final machine = node(server.port!);
      const rejectedCodes = {
        StatusCode.invalidArgument,
        StatusCode.resourceExhausted,
        StatusCode.failedPrecondition,
        StatusCode.permissionDenied,
        StatusCode.unauthenticated,
      };
      for (final code in [
        ...rejectedCodes,
        StatusCode.unavailable,
        StatusCode.alreadyExists,
        StatusCode.deadlineExceeded,
        StatusCode.cancelled,
        StatusCode.unknown,
        StatusCode.internal,
        StatusCode.dataLoss,
      ]) {
        service.failure = GrpcError.custom(code, 'private-task-detail');
        await expectLater(
          gateway.submit(machine, TaskRequest(id: 'execution')),
          throwsA(
            isA<UserError>()
                .having(
                  (error) => error is TaskSubmissionRejected,
                  'explicit submission rejection',
                  rejectedCodes.contains(code),
                )
                .having(
                  (error) => error.message,
                  'safe message',
                  isNot(contains('private-task-detail')),
                ),
          ),
        );
        // The same RPC code on another operation never rolls back a submission.
        final ordinaryFailure = throwsA(
          allOf(isA<UserError>(), isNot(isA<TaskSubmissionRejected>())),
        );
        await expectLater(gateway.status(machine), ordinaryFailure);
        await expectLater(
          gateway.cancel(machine, 'execution'),
          ordinaryFailure,
        );
      }
    },
  );

  test(
    'a failed transport cannot establish that submission was rejected',
    () async {
      final channel = ClientChannel(
        '127.0.0.1',
        port: await closedPort(),
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          connectTimeout: Duration(seconds: 2),
        ),
      );
      addTearDown(channel.shutdown);
      final gateway = GrpcGateway(open: (_) async => channel);
      await expectLater(
        gateway.submit(node(1), TaskRequest(id: 'execution')),
        throwsA(allOf(isA<UserError>(), isNot(isA<TaskSubmissionRejected>()))),
      );
    },
  );

  test('calls reuse one channel per connection setting', () async {
    var opened = 0;
    final gateway = GrpcGateway(
      open: (m) async {
        opened++;
        return ClientChannel(
          m.host,
          port: m.port,
          options: const ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            connectTimeout: Duration(seconds: 2),
          ),
        );
      },
    );
    final down = node(await closedPort());
    for (var i = 0; i < 2; i++) {
      await expectLater(gateway.status(down), throwsA(isA<UserError>()));
    }
    expect(opened, 1);
    await expectLater(
      gateway.status(node(await closedPort())),
      throwsA(isA<UserError>()),
    );
    expect(opened, 2);
  });

  test('unreadable credentials are read again instead of cached', () async {
    var opened = 0;
    final gateway = GrpcGateway(
      open: (m) async {
        opened++;
        throw const FileSystemException('missing');
      },
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(gateway.status(node(1)), throwsA(isA<UserError>()));
    }
    expect(opened, 2);
  });

  test('channels bound the TCP connect, not connection reuse', () async {
    final directory = await Directory.systemTemp.createTemp('lastorder-grpc-');
    addTearDown(() => directory.delete(recursive: true));
    for (final name in ['ca', 'cert', 'key']) {
      File('${directory.path}/$name').writeAsStringSync(name);
    }
    final channel = await openSistersChannel(
      node(defaultSistersPort, directory: directory.path),
    );
    addTearDown(channel.shutdown);
    expect(channel.options.connectTimeout, const Duration(seconds: 8));
    expect(
      channel.options.connectionTimeout,
      greaterThan(const Duration(minutes: 1)),
    );
  });

  test('changed task payload explains conflict without claiming an update', () {
    final message = describeGrpcFailure(
      const GrpcError.alreadyExists('private-cookie-and-config'),
    );

    expect(message, contains('另一份配置或登录凭据'));
    expect(message, contains('原任务未更新'));
    expect(message, contains('请新建任务后分发'));
    expect(message, contains('若原任务仍在运行，请先查看状态'));
    expect(message, isNot(contains('private-cookie-and-config')));
  });

  test(
    'other RPC failures retain safe diagnostics and do not suggest new tasks',
    () {
      for (final error in [
        const GrpcError.unavailable('private-network-detail'),
        const GrpcError.unauthenticated('private-certificate-detail'),
        const GrpcError.resourceExhausted('private-task-detail'),
      ]) {
        final message = describeGrpcFailure(error);
        expect(message, contains(error.codeName));
        expect(message, contains('请检查机器状态'));
        expect(message, isNot(contains('请新建任务')));
        expect(message, isNot(contains('private-')));
      }
    },
  );
}
