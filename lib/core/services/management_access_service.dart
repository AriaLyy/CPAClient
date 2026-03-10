import 'package:cpaclient/core/services/app_log_service.dart';

class ManagementAccessService {
  ManagementAccessService({
    required AppLogService log,
  }) : _log = log;

  final AppLogService _log;

  Future<String> resolveUsageSecretKey({
    required String settingsWebuiSecretKey,
    required String defaultSecretKey,
  }) async {
    final settingsKey = settingsWebuiSecretKey.trim();
    if (settingsKey.isNotEmpty) {
      await _log.info('Usage key source: settings.webuiSecretKey');
      return settingsKey;
    }

    await _log.info('Usage key source: default WebUI password fallback');
    return defaultSecretKey;
  }
}
