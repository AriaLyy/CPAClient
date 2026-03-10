import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

class UsageNetworkService {
  UsageNetworkService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<void> downloadUsageJson({
    required Uri uri,
    required String secretKey,
    required String outputPath,
  }) async {
    final parentDir = Directory(p.dirname(outputPath));
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }
    await _dio.downloadUri(
      uri,
      outputPath,
      options: Options(
              receiveTimeout: const Duration(seconds: 15), // 接收超时
      sendTimeout: const Duration(seconds: 15),   
        headers: <String, String>{'X-Management-Key': secretKey},
      ),
      deleteOnError: true,
    );
  }

  Future<void> importUsageJson({
    required Uri uri,
    required String secretKey,
    required String payload,
  }) async {
    await _dio.postUri<dynamic>(
      uri,
      data: payload,
      options: Options(
        headers: <String, String>{
          'X-Management-Key': secretKey,
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.plain,
      ),
    );
  }
}
