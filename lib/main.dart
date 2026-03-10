import 'dart:io';
import 'dart:ui' as ui;

import 'package:cpaclient/app/app.dart';
import 'package:cpaclient/core/services/app_services.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _configureGoogleFonts();

  await windowManager.ensureInitialized();

  const fixedWindowSize = Size(860, 640);
  const options = WindowOptions(
    size: fixedWindowSize,
    minimumSize: fixedWindowSize,
    maximumSize: fixedWindowSize,
    center: true,
    title: 'CPAClient',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setResizable(false);
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

  final settings = await AppServices.settings.load();
  final initialThemeMode = switch (settings.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  runApp(CpaClientApp(initialThemeMode: initialThemeMode));
}

void _configureGoogleFonts() {
  GoogleFonts.config.allowRuntimeFetching = true;

  final modeDefine = const String.fromEnvironment(
    'CPA_GOOGLE_FONTS_MODE',
    defaultValue: 'auto',
  ).toLowerCase();

  final localeCountry =
      ui.PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
  final useCnMirror = switch (modeDefine) {
    'cn' => true,
    'global' => false,
    _ => localeCountry == 'CN',
  };

  final cssHost = const String.fromEnvironment(
    'CPA_GOOGLE_FONTS_CSS_HOST',
    defaultValue: '',
  );
  final assetHost = const String.fromEnvironment(
    'CPA_GOOGLE_FONTS_ASSET_HOST',
    defaultValue: '',
  );

  final resolvedCssHost = cssHost.isNotEmpty
      ? cssHost
      : (useCnMirror ? 'fonts.loli.net' : 'fonts.googleapis.com');
  final resolvedAssetHost = assetHost.isNotEmpty
      ? assetHost
      : (useCnMirror ? 'gstatic.loli.net' : 'fonts.gstatic.com');

  HttpOverrides.global = _GoogleFontsHostOverride(
    cssHost: resolvedCssHost,
    assetHost: resolvedAssetHost,
  );
}

class _GoogleFontsHostOverride extends HttpOverrides {
  _GoogleFontsHostOverride({required this.cssHost, required this.assetHost});

  final String cssHost;
  final String assetHost;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = super.createHttpClient(context);
    return _GoogleFontsHostRewritingHttpClient(
      inner,
      cssHost: cssHost,
      assetHost: assetHost,
    );
  }
}

class _GoogleFontsHostRewritingHttpClient implements HttpClient {
  _GoogleFontsHostRewritingHttpClient(
    this._inner, {
    required this.cssHost,
    required this.assetHost,
  });

  final HttpClient _inner;
  final String cssHost;
  final String assetHost;

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? value,
  ) =>
      _inner.authenticate = value;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        value,
  ) =>
      _inner.authenticateProxy = value;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? value,
  ) =>
      _inner.badCertificateCallback = value;

  @override
  set findProxy(String Function(Uri url)? value) => _inner.findProxy = value;

  @override
  set keyLog(void Function(String line)? callback) => _inner.keyLog = callback;

  Uri _rewrite(Uri uri) {
    if (uri.host == 'fonts.googleapis.com') {
      return uri.replace(host: cssHost);
    }
    if (uri.host == 'fonts.gstatic.com') {
      return uri.replace(host: assetHost);
    }
    return uri;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    return _inner.openUrl(method, _rewrite(url));
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    return _inner.getUrl(_rewrite(url));
  }

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) {
    return _inner.deleteUrl(_rewrite(url));
  }

  @override
  Future<HttpClientRequest> headUrl(Uri url) {
    return _inner.headUrl(_rewrite(url));
  }

  @override
  Future<HttpClientRequest> patchUrl(Uri url) {
    return _inner.patchUrl(_rewrite(url));
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) {
    return _inner.postUrl(_rewrite(url));
  }

  @override
  Future<HttpClientRequest> putUrl(Uri url) {
    return _inner.putUrl(_rewrite(url));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return (_inner as dynamic).noSuchMethod(invocation);
  }
}
