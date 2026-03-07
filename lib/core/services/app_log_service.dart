import 'dart:io';

import 'package:cpaclient/core/services/sandbox_path_service.dart';

class AppLogService {
  AppLogService(this._paths);

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
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [$level] $message\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }
}
