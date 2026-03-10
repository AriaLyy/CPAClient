import 'dart:convert';
import 'dart:io';

import 'package:cpaclient/core/services/sandbox_path_service.dart';

class AppLogService {
  AppLogService(this._paths);

  static const int _maxLogSizeBytes = 1024 * 1024;

  final SandboxPathService _paths;

  Future<void> info(String message) async {
    await _write('INFO', message);
  }

  Future<void> error(String message, [Object? error]) async {
    final suffix = error == null ? '' : ' | error=$error';
    await _write('ERROR', '$message$suffix');
  }

  Future<String> tail({int maxLines = 200}) async {
    final file = await _paths.logFile();
    if (!file.existsSync()) {
      return '';
    }
    final lines = await file.readAsLines();
    if (lines.length <= maxLines) {
      return lines.join('\n');
    }
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  Future<String> logFilePath() async {
    final file = await _paths.logFile();
    return file.path;
  }

  Future<void> _write(String level, String message) async {
    final file = await _paths.logFile();
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await _truncateIfNeeded(file);
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [$level] $message\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> _truncateIfNeeded(File file) async {
    if (!file.existsSync()) {
      return;
    }
    final length = await file.length();
    if (length < _maxLogSizeBytes) {
      return;
    }

    final bytes = await file.readAsBytes();
    final start = bytes.length - (_maxLogSizeBytes ~/ 2);
    final truncated = utf8.decode(bytes.sublist(start), allowMalformed: true);
    final marker =
        '[${DateTime.now().toIso8601String()}] [INFO] log truncated to keep within 1MB\n';
    await file.writeAsString('$marker$truncated', flush: true);
  }
}
