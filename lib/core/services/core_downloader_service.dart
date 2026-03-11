import 'dart:io';

import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:dio/dio.dart';

class CoreDownloaderService {
  CoreDownloaderService(this._log)
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            sendTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(minutes: 5),
          ),
        );

  final AppLogService _log;
  final Dio _dio;

  Future<void> downloadToFile({
    required String url,
    required File target,
  }) async {
    await _log.info('Core download start: url=$url -> ${target.path}');
    try {
      if (!target.parent.existsSync()) {
        target.parent.createSync(recursive: true);
      }
      await _dio.download(
        url,
        target.path,
        options: Options(
          headers: {
            'User-Agent': 'CPAClient/1.0',
            'Accept': 'application/octet-stream',
          },
        ),
      );
      await _log.info('Core download success: ${target.path}');
    } catch (e) {
      await _log.error('Core download failed: url=$url', e);
      rethrow;
    }
  }
}
