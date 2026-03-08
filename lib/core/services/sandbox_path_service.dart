import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SandboxPathService {
  Future<Directory> _appSupportDir() async {
    return getApplicationSupportDirectory();
  }

  Future<Directory> sandboxRoot() async {
    final base = await _appSupportDir();
    final dir = Directory(p.join(base.path, CoreDefaults.sandboxDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> binDir() async {
    final root = await sandboxRoot();
    final dir = Directory(p.join(root.path, CoreDefaults.binDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> configDir() async {
    final root = await sandboxRoot();
    final dir = Directory(p.join(root.path, CoreDefaults.configDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> tmpDir() async {
    final root = await sandboxRoot();
    final dir = Directory(p.join(root.path, CoreDefaults.tmpDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<File> sandboxConfigFile() async {
    final config = await configDir();
    return File(
      p.join(config.path, CoreDefaults.sandboxConfigFileName),
    );
  }

  Future<File> settingsFile() async {
    final root = await sandboxRoot();
    return File(p.join(root.path, CoreDefaults.sandboxSettingsName));
  }

  Future<File> logFile() async {
    final root = await sandboxRoot();
    return File(p.join(root.path, CoreDefaults.sandboxLogFileName));
  }

  String homeDirPath() {
    final env = Platform.environment;
    final home = env['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return home;
    }
    final userProfile = env['USERPROFILE'];
    if (userProfile != null && userProfile.trim().isNotEmpty) {
      return userProfile;
    }
    final homeDrive = env['HOMEDRIVE'];
    final homePath = env['HOMEPATH'];
    if (homeDrive != null && homePath != null && homeDrive.isNotEmpty && homePath.isNotEmpty) {
      return '$homeDrive$homePath';
    }
    return Directory.current.path;
  }

  String expandHomePath(String path) {
    final value = path.trim();
    if (value == '~') {
      return homeDirPath();
    }
    if (value.startsWith('~/') || value.startsWith('~\\')) {
      final suffix = value.substring(2);
      return p.normalize(p.join(homeDirPath(), suffix));
    }
    return p.normalize(value);
  }

  Directory resolveAuthDir(String authDir) {
    return Directory(expandHomePath(authDir));
  }

  List<File> listJsonFilesRecursively(Directory root) {
    if (!root.existsSync()) {
      return const <File>[];
    }
    return root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .toList(growable: false);
  }

  Future<String> coreExecutablePath() async {
    final bin = await binDir();
    final exe = Platform.isWindows ? 'cli-proxy-api.exe' : 'cli-proxy-api';
    return p.join(bin.path, exe);
  }
}
