import 'dart:convert';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/models/github_release.dart';
import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:http/http.dart' as http;

class GithubReleaseService {
  GithubReleaseService(this._log);

  final AppLogService _log;

  Map<String, String> _headers({String? githubToken}) {
    return {
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'CPAClient/1.0',
      if (githubToken != null && githubToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${githubToken.trim()}',
    };
  }

  Future<List<String>> fetchRecentVersions({
    required String githubToken,
    int limit = 20,
  }) async {
    await _log.info('GitHub release versions lookup start: limit=$limit');
    final uri = Uri.parse(CoreDefaults.releaseApi);
    final response = await http.get(uri, headers: _headers(githubToken: githubToken));
    await _log.info('GitHub release versions response: status=${response.statusCode}');

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _log.error('GitHub release versions failed: status=${response.statusCode}');
      throw Exception('GitHub releases request failed: ${response.statusCode}');
    }

    final payload = jsonDecode(response.body) as List<dynamic>;
    final versions = <String>[];
    for (final item in payload) {
      final raw = (item as Map<String, dynamic>)['tag_name'] as String?;
      if (raw == null || raw.trim().isEmpty) {
        continue;
      }
      final normalized = raw.replaceFirst(RegExp(r'^[vV]'), '').trim();
      if (normalized.isEmpty || versions.contains(normalized)) {
        continue;
      }
      versions.add(normalized);
      if (versions.length >= limit) {
        break;
      }
    }

    await _log.info('GitHub release versions resolved: count=${versions.length}');
    return versions;
  }

  Future<GithubReleaseAsset> findAssetByName(
    String assetName, {
    required String githubToken,
  }) async {
    await _log.info('GitHub release lookup start: asset=$assetName');
    final uri = Uri.parse(CoreDefaults.releaseApi);
    final response = await http.get(uri, headers: _headers(githubToken: githubToken));

    await _log.info('GitHub release lookup response: status=${response.statusCode}');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 403) {
        await _log.error('GitHub release lookup 403 for $assetName');
        throw Exception('GitHub releases request failed: 403 (可能触发限流，请稍后再试或配置 GITHUB_TOKEN)');
      }
      await _log.error('GitHub release lookup failed: status=${response.statusCode}');
      throw Exception('GitHub releases request failed: ${response.statusCode}');
    }

    final payload = jsonDecode(response.body) as List<dynamic>;
    for (final item in payload) {
      final release = GithubRelease.fromJson(item as Map<String, dynamic>);
      for (final asset in release.assets) {
        if (asset.name == assetName) {
          await _log.info('GitHub release asset matched: $assetName');
          return asset;
        }
      }
    }

    await _log.error('GitHub release asset not found: $assetName');
    throw Exception('Asset not found: $assetName');
  }
}
