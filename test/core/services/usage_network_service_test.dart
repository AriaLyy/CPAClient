import 'dart:convert';
import 'dart:io';

import 'package:cpaclient/core/services/usage_network_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageNetworkService.downloadUsageJson', () {
    late HttpServer server;
    late UsageNetworkService service;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      service = UsageNetworkService();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('sends X-Management-Key and downloads response to output path',
        () async {
      const expectedKey = '123456';
      final payload = jsonEncode(<String, dynamic>{
        'ok': true,
        'source': 'test',
      });

      server.listen((HttpRequest request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/v0/management/usage/export');
        expect(request.headers.value('X-Management-Key'), expectedKey);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(payload);
        await request.response.close();
      });

      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/v0/management/usage/export',
      );
      final tmpDir =
          await Directory.systemTemp.createTemp('usage_export_test_');
      final outputPath = '${tmpDir.path}/usage.json';

      try {
        await service.downloadUsageJson(
          uri: uri,
          secretKey: expectedKey,
          outputPath: outputPath,
        );

        expect(File(outputPath).existsSync(), isTrue);
        expect(await File(outputPath).readAsString(), payload);
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });

    test('throws DioException on unauthorized status', () async {
      const expectedKey = 'bad-key';

      server.listen((HttpRequest request) async {
        expect(request.headers.value('X-Management-Key'), expectedKey);
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('unauthorized');
        await request.response.close();
      });

      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/v0/management/usage/export',
      );

      final tmpDir =
          await Directory.systemTemp.createTemp('usage_export_test_');
      final outputPath = '${tmpDir.path}/usage.json';

      try {
        expect(
          () => service.downloadUsageJson(
            uri: uri,
            secretKey: expectedKey,
            outputPath: outputPath,
          ),
          throwsA(isA<DioException>()),
        );
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
