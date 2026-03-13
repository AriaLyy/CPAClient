import 'package:cpaclient/features/settings/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SettingsController controller;

  setUp(() {
    controller = SettingsController();
  });

  group('startup usage import decision rules', () {
    test('download when local missing and remote exists', () {
      final action = controller.decideStartupUsageImportActionForTest(
        localMtimeMs: null,
        remoteVersionId: '20260311T010203Z',
      );
      expect(action, 'download');
    });

    test('download when remote newer than local mtime', () {
      final action = controller.decideStartupUsageImportActionForTest(
        localMtimeMs: DateTime.utc(2026, 3, 11, 1, 2, 2).millisecondsSinceEpoch,
        remoteVersionId: '20260311T010203Z',
      );
      expect(action, 'download');
    });

    test('local when remote older than local mtime', () {
      final action = controller.decideStartupUsageImportActionForTest(
        localMtimeMs: DateTime.utc(2026, 3, 11, 1, 2, 4).millisecondsSinceEpoch,
        remoteVersionId: '20260311T010203Z',
      );
      expect(action, 'local');
    });

    test('local when mtime equals remote time', () {
      final localMtimeMs =
          DateTime.utc(2026, 3, 11, 1, 2, 3).millisecondsSinceEpoch;
      final action = controller.decideStartupUsageImportActionForTest(
        localMtimeMs: localMtimeMs,
        remoteVersionId: '20260311T010203Z',
      );
      expect(action, 'local');
    });

    test('local when remote version cannot be parsed', () {
      final action = controller.decideStartupUsageImportActionForTest(
        localMtimeMs: DateTime.utc(2026, 3, 11, 1, 2, 4).millisecondsSinceEpoch,
        remoteVersionId: 'invalid-version',
      );
      expect(action, 'local');
    });
  });

  group('usage sync decision rules', () {
    test('noop when local and remote unchanged', () {
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'abc',
        localMtimeMs: 1000,
        remoteVersionId: '20260310T112233Z',
        lastLocalHash: 'abc',
        lastLocalMtimeMs: 900,
        lastRemoteVersionId: '20260310T112233Z',
      );
      expect(action, 'noop');
    });

    test('upload when local changed and remote unchanged', () {
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'new',
        localMtimeMs: 2000,
        remoteVersionId: '20260310T112233Z',
        lastLocalHash: 'old',
        lastLocalMtimeMs: 1000,
        lastRemoteVersionId: '20260310T112233Z',
      );
      expect(action, 'upload');
    });

    test('download when remote changed and local unchanged', () {
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'same',
        localMtimeMs: 1000,
        remoteVersionId: '20260311T000000Z',
        lastLocalHash: 'same',
        lastLocalMtimeMs: 1000,
        lastRemoteVersionId: '20260310T235959Z',
      );
      expect(action, 'download');
    });

    test('conflict picks newer local timestamp', () {
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'local-new',
        localMtimeMs: DateTime.utc(2026, 3, 11, 1, 2, 4).millisecondsSinceEpoch,
        remoteVersionId: '20260311T010203Z',
        lastLocalHash: 'old',
        lastLocalMtimeMs: 0,
        lastRemoteVersionId: '20260310T235959Z',
      );
      expect(action, 'upload');
    });

    test('conflict picks remote when newer', () {
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'local-new',
        localMtimeMs: DateTime.utc(2026, 3, 11, 1, 2, 2).millisecondsSinceEpoch,
        remoteVersionId: '20260311T010203Z',
        lastLocalHash: 'old',
        lastLocalMtimeMs: 0,
        lastRemoteVersionId: '20260310T235959Z',
      );
      expect(action, 'download');
    });

    test('conflict tie defaults to upload', () {
      final localMtimeMs =
          DateTime.utc(2026, 3, 11, 1, 2, 3).millisecondsSinceEpoch;
      final action = controller.decideUsageSyncActionForTest(
        localHash: 'local-new',
        localMtimeMs: localMtimeMs,
        remoteVersionId: '20260311T010203Z',
        lastLocalHash: 'old',
        lastLocalMtimeMs: 0,
        lastRemoteVersionId: '20260310T235959Z',
      );
      expect(action, 'upload');
    });
  });
}
