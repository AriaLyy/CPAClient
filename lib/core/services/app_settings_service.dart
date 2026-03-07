import 'dart:convert';

import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';

class AppSettingsService {
  AppSettingsService(this._paths);

  final SandboxPathService _paths;

  Future<AppSettings> load() async {
    final file = await _paths.settingsFile();
    if (!file.existsSync()) {
      final defaults = AppSettings.defaults();
      await save(defaults);
      return defaults;
    }
    final text = await file.readAsString();
    final map = jsonDecode(text) as Map<String, dynamic>;
    return AppSettings.fromJson(map);
  }

  Future<void> save(AppSettings settings) async {
    final file = await _paths.settingsFile();
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
