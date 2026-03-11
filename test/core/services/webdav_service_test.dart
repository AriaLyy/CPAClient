import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/management_access_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/usage_network_service.dart';
import 'package:cpaclient/core/services/webdav_service.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

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
  });

  group('WebdavService remote path candidates', () {
    test('buildRemotePathCandidates returns both no-slash and slash forms', () {
      expect(
        service.buildRemotePathCandidates('versions/abc/backup.tar.gz'),
        ['versions/abc/backup.tar.gz', '/versions/abc/backup.tar.gz'],
      );
      expect(
        service.buildRemotePathCandidates('/versions/abc/backup.tar.gz'),
        ['versions/abc/backup.tar.gz', '/versions/abc/backup.tar.gz'],
      );
    });

    test('buildRestoreUsageRemoteArchiveCandidates prefers usage then backup',
        () {
      expect(
        service.buildRestoreUsageRemoteArchiveCandidates('20260310T112233Z'),
        [
          'backups/20260310T112233Z/${CoreDefaults.webdavUsageArchiveName}',
          '/backups/20260310T112233Z/${CoreDefaults.webdavUsageArchiveName}',
          'backups/20260310T112233Z/backup.tar.gz',
          '/backups/20260310T112233Z/backup.tar.gz',
        ],
      );
    });
  });

  group('WebdavService archive extraction validation', () {
    test('buildUsageOnlyArchive creates tar.gz with usage.json only', () async {
      final tmpDir =
          await Directory.systemTemp.createTemp('webdav_usage_only_');
      final usagePath = p.join(tmpDir.path, 'usage.json');
      await File(usagePath).writeAsString('{"hello":"world"}', flush: true);

      final archivePath = await service.buildUsageOnlyArchive(
        localUsageJsonPath: usagePath,
      );

      expect(p.basename(archivePath), CoreDefaults.webdavUsageArchiveName);
      expect(archivePath.endsWith('.tar.gz'), isTrue);

      final compressed = File(archivePath).readAsBytesSync();
      final tarData = GZipDecoder().decodeBytes(compressed);
      final archive = TarDecoder().decodeBytes(tarData);
      final names = archive.files
          .where((entry) => entry.isFile)
          .map((entry) => entry.name)
          .toList(growable: false);

      expect(names, contains('usage.json'));
      expect(names, isNot(contains('config.yaml')));
      expect(
        names.any((name) =>
            name.startsWith('${CoreDefaults.webdavAuthJsonDirName}/')),
        isFalse,
      );

      File(archivePath).deleteSync();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('extractUsageFromBackupArchive throws when usage.json is missing',
        () async {
      final archivePath = await _createArchive(
        files: [
          ArchiveFile('config.yaml', 3, 'x:1'.codeUnits),
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

      File(archivePath).deleteSync();
      if (outputUsage.existsSync()) {
        outputUsage.deleteSync();
      }
    });

    test('extractBackupArchive throws when config.yaml is missing', () async {
      final archivePath = await _createArchive(
        files: [
          ArchiveFile('usage.json', 2, '{}'.codeUnits),
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

      File(archivePath).deleteSync();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

Future<String> _createArchive({required List<ArchiveFile> files}) async {
  final tmpDir = await Directory.systemTemp.createTemp('webdav_service_test_');
  final archivePath = p.join(tmpDir.path, 'backup.tar.gz');
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  final tarData = TarEncoder().encode(archive);
  final gzipData = GZipEncoder().encode(tarData);
  await File(archivePath).writeAsBytes(gzipData, flush: true);
  return archivePath;
}
