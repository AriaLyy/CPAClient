import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/management_access_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/usage_network_service.dart';
import 'package:archive/archive_io.dart';
import 'package:cpaclient/core/services/webdav_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late WebdavService service;

  setUp(() {
    final paths = SandboxPathService();
    final log = AppLogService(paths);
    service = WebdavService(
      paths: paths,
      sandboxConfig: SandboxConfigService(paths),
      log: log,
      usageNetwork: UsageNetworkService(),
      managementAccess: ManagementAccessService(log: log),
      process: CoreProcessManager(paths, log),
    );
  });

  group('WebdavService version helpers', () {
    test('parseBackupVersionTime parses valid UTC version id', () {
      final parsed = service.parseBackupVersionTime('20260310T112233Z');
      expect(parsed, DateTime.utc(2026, 3, 10, 11, 22, 33));
    });

    test('formatBackupVersionLabel returns original id for invalid value', () {
      const invalid = 'not-a-version';
      expect(service.formatBackupVersionLabel(invalid), invalid);
    });

    test('latestUsageVersionIdFromCandidatesForTest returns latest valid id',
        () {
      final latest = service.latestUsageVersionIdFromCandidatesForTest([
        '20260310T112233Z',
        'not-a-version',
        '20260311T010203Z',
      ]);
      expect(latest, '20260311T010203Z');
    });

    test('latestUsageVersionIdFromCandidatesForTest deduplicates and sorts',
        () {
      final latest = service.latestUsageVersionIdFromCandidatesForTest([
        '20260311T010203Z',
        '20260310T112233Z',
        '20260311T010203Z',
      ]);
      expect(latest, '20260311T010203Z');
    });

    test('latestUsageVersionIdFromCandidatesForTest returns null on empty', () {
      final latest = service.latestUsageVersionIdFromCandidatesForTest(
        const <String>[],
      );
      expect(latest, isNull);
    });
  });

  group('WebdavService remote path candidates', () {
    test('buildRemotePathCandidates returns both no-slash and slash forms', () {
      expect(
        service.buildRemotePathCandidates('versions/abc/backup.zip'),
        ['versions/abc/backup.zip', '/versions/abc/backup.zip'],
      );
      expect(
        service.buildRemotePathCandidates('/versions/abc/backup.zip'),
        ['versions/abc/backup.zip', '/versions/abc/backup.zip'],
      );
    });

    test('buildRestoreUsageRemoteArchiveCandidates uses usage archive only',
        () {
      expect(
        service.buildRestoreUsageRemoteArchiveCandidates('20260310T112233Z'),
        [
          'sync/20260310T112233Z/${CoreDefaults.webdavUsageArchiveName}',
          '/sync/20260310T112233Z/${CoreDefaults.webdavUsageArchiveName}',
        ],
      );
    });
  });

  group('WebdavService archive extraction validation', () {
    test('buildUsageOnlyArchive creates zip with usage.json only', () async {
      final tmpDir =
          await Directory.systemTemp.createTemp('webdav_usage_only_');
      final usagePath = p.join(tmpDir.path, 'usage.json');
      await File(usagePath).writeAsString('{"hello":"world"}', flush: true);

      final archivePath = await service.buildUsageOnlyArchive(
        localUsageJsonPath: usagePath,
      );

      expect(p.basename(archivePath), CoreDefaults.webdavUsageArchiveName);
      expect(archivePath.endsWith('.zip'), isTrue);

      final extractDir =
          await Directory.systemTemp.createTemp('webdav_usage_extract_');
      extractFileToDisk(archivePath, extractDir.path);
      final names = extractDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((entry) => p.basename(entry.path))
          .toList(growable: false);

      expect(names, contains('usage.json'));
      expect(names, isNot(contains('config.yaml')));
      expect(names, isNot(contains(CoreDefaults.webdavAuthJsonDirName)));

      await _deleteFileWithRetry(archivePath);
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test('extractUsageFromBackupArchive throws when usage.json is missing',
        () async {
      final archivePath = await _createArchive(
        files: [
          _ArchiveInput('config.yaml', 'x:1'.codeUnits),
        ],
      );
      final outputUsage =
          File(p.join(Directory.systemTemp.path, 'usage_out.json'));
      if (outputUsage.existsSync()) {
        outputUsage.deleteSync();
      }

      expect(
        () => service.extractUsageFromBackupArchive(
          localArchivePath: archivePath,
          localUsageJsonPath: outputUsage.path,
        ),
        throwsA(isA<Exception>()),
      );

      await _deleteFileWithRetry(archivePath);
      if (outputUsage.existsSync()) {
        outputUsage.deleteSync();
      }
    });

    test('extractBackupArchive throws when config.yaml is missing', () async {
      final archivePath = await _createArchive(
        files: [
          _ArchiveInput('usage.json', '{}'.codeUnits),
        ],
      );
      final tempDir =
          await Directory.systemTemp.createTemp('webdav_extract_test_');

      expect(
        () => service.extractBackupArchive(
          localArchivePath: archivePath,
          localConfigPath: p.join(tempDir.path, 'config.yaml'),
          localUsageJsonPath: p.join(tempDir.path, 'usage.json'),
          localAuthDir: Directory(p.join(tempDir.path, 'auth')),
        ),
        throwsA(isA<Exception>()),
      );

      await _deleteFileWithRetry(archivePath);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('extractBackupArchive supports nested top-level directory', () async {
      final archivePath = await _createArchive(
        files: [
          _ArchiveInput('config.yaml', 'port: 1234'.codeUnits),
          _ArchiveInput('usage.json', '{}'.codeUnits),
        ],
      );
      final tempDir =
          await Directory.systemTemp.createTemp('webdav_extract_nested_');
      final outputConfig = p.join(tempDir.path, 'config.yaml');
      final outputUsage = p.join(tempDir.path, 'usage.json');

      final restored = service.extractBackupArchive(
        localArchivePath: archivePath,
        localConfigPath: outputConfig,
        localUsageJsonPath: outputUsage,
        localAuthDir: Directory(p.join(tempDir.path, 'auth')),
      );

      expect(restored, 0);
      expect(File(outputConfig).existsSync(), isTrue);
      expect(File(outputUsage).existsSync(), isTrue);

      await _deleteFileWithRetry(archivePath);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

Future<void> _deleteFileWithRetry(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    return;
  }
  const attempts = 5;
  for (var i = 1; i <= attempts; i++) {
    try {
      await file.delete();
      return;
    } catch (_) {
      if (i == attempts) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

Future<String> _createArchive({required List<_ArchiveInput> files}) async {
  final tmpDir = await Directory.systemTemp.createTemp('webdav_service_test_');
  final stageDir = await Directory.systemTemp.createTemp('webdav_stage_');
  final archivePath = p.join(tmpDir.path, 'backup.zip');
  try {
    for (final file in files) {
      final target = File(p.join(stageDir.path, file.path));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(file.bytes, flush: true);
    }
    final archive = Archive();
    final stagedFiles = stageDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>();
    for (final stagedFile in stagedFiles) {
      final relativePath = p.relative(stagedFile.path, from: stageDir.path);
      final bytes = stagedFile.readAsBytesSync();
      archive.addFile(ArchiveFile(relativePath, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    File(archivePath).writeAsBytesSync(encoded, flush: true);
    return archivePath;
  } finally {
    if (stageDir.existsSync()) {
      stageDir.deleteSync(recursive: true);
    }
  }
}

class _ArchiveInput {
  const _ArchiveInput(this.path, this.bytes);

  final String path;
  final List<int> bytes;
}
