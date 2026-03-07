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
    if (!target.existsSync()) {
      final found = await _findExecutable(binDir, executableName);
      if (found != null) {
        found.copySync(target.path);
      }
    }

    if (!target.existsSync()) {
      throw Exception('Executable not found after extraction: ${target.path}');
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', target.path]);
    }
  }

  Future<File?> _findExecutable(Directory root, String executableName) async {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path).toLowerCase();
      if (name == executableName.toLowerCase()) {
        return entity;
      }
      if (name == 'cli-proxy-api' || name == 'cli-proxy-api.exe') {
        return entity;
      }
    }
    return null;
  }
}
