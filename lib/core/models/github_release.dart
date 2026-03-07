class GithubReleaseAsset {
  const GithubReleaseAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;

  factory GithubReleaseAsset.fromJson(Map<String, dynamic> json) {
    return GithubReleaseAsset(
      name: json['name'] as String,
      downloadUrl: json['browser_download_url'] as String,
    );
  }
}

class GithubRelease {
  const GithubRelease({required this.tagName, required this.assets});

  final String tagName;
  final List<GithubReleaseAsset> assets;

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    return GithubRelease(
      tagName: json['tag_name'] as String,
      assets: (json['assets'] as List<dynamic>)
          .map((e) => GithubReleaseAsset.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
