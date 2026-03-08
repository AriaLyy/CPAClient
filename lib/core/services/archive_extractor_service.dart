import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class ArchiveExtractorService {
  Future<void> extractToDirectory({
    required File archiveFile,
    required Directory outputDir,
  }) async {
    if (!outputDir.existsSync()) {
      outputDir.createSync(recursive: true);
    }
    extractFileToDisk(archiveFile.path, outputDir.path);
  }

  Future<void> ensureExecutablePresent({
    required Directory binDir,
    required String executableName,
  }) async {
    final target = File(p.join(binDir.path, executableName));
    const maxAttempts = 12;
    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      if (target.existsSync()) {
        break;
      }
      final found = await _findExecutable(binDir, executableName);
      if (found != null) {
        found.copySync(target.path);
      }
      if (target.existsSync()) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (!target.existsSync()) {
      final files = _listExtractedFiles(binDir);
      throw Exception(
        'Executable not found after extraction: ${target.path}; extracted=${files.isEmpty ? '(empty)' : files.join(', ')}',
      );
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', target.path]);
    }
  }

  List<String> _listExtractedFiles(Directory root) {
    if (!root.existsSync()) {
      return const <String>[];
    }
    return root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => p.relative(file.path, from: root.path))
        .toList(growable: false);
  }

  Future<File?> _findExecutable(Directory root, String executableName) async {
    final target = executableName.toLowerCase();
    final legacyNames = <String>{
      'cli-proxy-api',
      'cli-proxy-api.exe',
      'cliproxyapi',
      'cliproxyapi.exe',
    };
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path).toLowerCase();
      if (name == target || legacyNames.contains(name)) {
        return entity;
      }
    }
    return null;
  }
}
