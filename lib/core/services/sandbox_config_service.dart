import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
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
      final next = _rewriteDefaultAuthDir(content);
      await configFile.writeAsString(next);
      return configFile;
    }

    final content = await configFile.readAsString();
    final next = _ensureAuthDirCompatible(content);
    if (next != content) {
      await configFile.writeAsString(next);
    }
    return configFile;
  }

  String _rewriteDefaultAuthDir(String content) {
    const replacement = 'auth-dir: "${CoreDefaults.defaultAuthDir}"';
    final pattern = RegExp(r'^\s*auth-dir:\s*.*$', multiLine: true);
    if (pattern.hasMatch(content)) {
      return content.replaceFirst(pattern, replacement);
    }
    return '$content\n$replacement\n';
  }

  String _ensureAuthDirCompatible(String content) {
    final pattern = RegExp(r'^\s*auth-dir:\s*(.*)$', multiLine: true);
    final match = pattern.firstMatch(content);
    const replacement = 'auth-dir: "${CoreDefaults.defaultAuthDir}"';

    if (match == null) {
      return '$content\n$replacement\n';
    }

    final value = (match.group(1) ?? '').trim();
    final isEmpty = value.isEmpty || value == '""' || value == "''";
    if (!isEmpty) {
      return content;
    }
    return content.replaceFirst(pattern, replacement);
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

  Future<String> readAuthDir() async {
    final configFile = await ensureSandboxConfig();
    final content = await configFile.readAsString();
    final yaml = loadYaml(content);
    if (yaml is YamlMap && yaml['auth-dir'] != null) {
      final value = yaml['auth-dir'].toString().trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return CoreDefaults.defaultAuthDir;
  }
}
