import 'dart:io';

import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

class SandboxConfigService {
  SandboxConfigService(this._paths);

  final SandboxPathService _paths;

  Future<File> ensureSandboxConfig() async {
    final configFile = await _paths.sandboxConfigFile();
    if (!configFile.existsSync()) {
      final content = await rootBundle.loadString('configs/config.yaml');
      await configFile.writeAsString(content);
    }
    return configFile;
  }

  Future<int> readPort() async {
    final configFile = await ensureSandboxConfig();
    final content = await configFile.readAsString();
    final yaml = loadYaml(content);
    if (yaml is YamlMap && yaml['port'] != null) {
      final value = yaml['port'];
      if (value is int) {
        return value;
      }
      return int.tryParse(value.toString()) ?? 8317;
    }
    return 8317;
  }

  Future<String> readSecretKey() async {
    final configFile = await ensureSandboxConfig();
    final content = await configFile.readAsString();
    final yaml = loadYaml(content);
    if (yaml is YamlMap) {
      final remote = yaml['remote-management'];
      if (remote is YamlMap && remote['secret-key'] != null) {
        return remote['secret-key'].toString();
      }
    }
    return '';
  }

  Future<void> updateSecretKey(String secretKey) async {
    final configFile = await ensureSandboxConfig();
    final content = await configFile.readAsString();
    final escaped = secretKey.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final replacement = '  secret-key: "$escaped"';
    final pattern = RegExp(r'^\s*secret-key:.*$', multiLine: true);
    if (!pattern.hasMatch(content)) {
      throw Exception('config.yaml 中未找到 secret-key 字段');
    }
    final next = content.replaceFirst(pattern, replacement);
    await configFile.writeAsString(next);
  }
}
