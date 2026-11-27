import 'dart:convert';
import 'dart:io';

import '../../core/constants/app_constants.dart';
import '../core/logging_service.dart';
import 'ytdlp_service_windows.dart' show YtdlpException;

/// Shared GitHub latest-release lookup for yt-dlp (desktop + Android).
///
/// Enforces a 60-second request throttle and a 60-minute in-memory TTL cache,
/// supports optional `GITHUB_TOKEN` auth, and returns the cached version on
/// HTTP 403/429 rate-limit responses when available.
class YtdlpReleaseChecker {
  final String componentName;
  final HttpClient Function()? clientFactory;

  String? _cachedLatestVersion;
  DateTime? _cacheTime;
  DateTime? _lastFetchAttempt;
  HttpClient? _pinnedClient;

  static const Duration _cacheExpiry = Duration(minutes: 60);
  static const Duration _throttleWindow = Duration(seconds: 60);

  YtdlpReleaseChecker({
    required this.componentName,
    this.clientFactory,
  });

  String? _getGithubToken() {
    try {
      final env = Platform.environment['GITHUB_TOKEN'];
      if (env != null && env.isNotEmpty) return env;
    } catch (_) {}
    const fromEnv = String.fromEnvironment('GITHUB_TOKEN');
    if (fromEnv.isNotEmpty) return fromEnv;
    return null;
  }

  bool _isRateLimitError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('rate limit') ||
        msg.contains('403') ||
        msg.contains('429');
  }

  Future<String?> getLatestVersion({bool forceRefresh = false}) async {
    final now = DateTime.now();

    if (!forceRefresh &&
        _lastFetchAttempt != null &&
        now.difference(_lastFetchAttempt!) < _throttleWindow) {
      if (_cachedLatestVersion != null) {
        LoggingService().debug(
          'getLatestVersion throttled, returning cached $_cachedLatestVersion',
          component: componentName,
        );
        return _cachedLatestVersion;
      }
      LoggingService().debug(
        'getLatestVersion throttled, no cache yet',
        component: componentName,
      );
      return null;
    }

    if (!forceRefresh &&
        _cachedLatestVersion != null &&
        _cacheTime != null &&
        now.difference(_cacheTime!) < _cacheExpiry) {
      return _cachedLatestVersion;
    }

    _lastFetchAttempt = now;
    final token = _getGithubToken();

    Future<String?> tryFetch(HttpClient client) async {
      final request = await client.getUrl(
        Uri.parse(AppConstants.ytdlpLatestReleaseApiUrl),
      );
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'AeroTube-Updater');
      if (token != null && token.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
      }
      final httpResponse = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final responseBody = await httpResponse.transform(utf8.decoder).join();
      if (httpResponse.statusCode == 200) {
        final data = jsonDecode(responseBody);
        final tagName = data['tag_name'] as String?;
        if (tagName != null && tagName.isNotEmpty) {
          _cachedLatestVersion = tagName;
          _cacheTime = DateTime.now();
          return tagName;
        }
        return null;
      } else if (httpResponse.statusCode == 403 ||
          httpResponse.statusCode == 429) {
        final snippet = responseBody.length > 300
            ? '${responseBody.substring(0, 300)}...'
            : responseBody;
        throw YtdlpException(
          'GitHub API rate limit (${httpResponse.statusCode}). $snippet Try again in a few minutes or check manually at https://github.com/yt-dlp/yt-dlp/releases',
        );
      } else {
        throw YtdlpException(
          'GitHub API error ${httpResponse.statusCode}: $responseBody',
        );
      }
    }

    if (clientFactory != null) {
      try {
        _pinnedClient ??= clientFactory!();
        return await tryFetch(_pinnedClient!);
      } catch (e) {
        if (_isRateLimitError(e)) {
          if (_cachedLatestVersion != null) {
            LoggingService().warning(
              'Rate limited but returning cached version $_cachedLatestVersion: $e',
              component: componentName,
            );
            return _cachedLatestVersion;
          }
          rethrow;
        }
        LoggingService().warning(
          'Pinned client failed, falling back to plain HttpClient: $e',
          component: componentName,
        );
      }
    }

    HttpClient? plain;
    try {
      plain = HttpClient();
      return await tryFetch(plain);
    } catch (e2) {
      if (_isRateLimitError(e2) && _cachedLatestVersion != null) {
        LoggingService().warning(
          'Rate limited but returning cached $_cachedLatestVersion',
          component: componentName,
        );
        return _cachedLatestVersion;
      }
      if (e2 is YtdlpException) rethrow;
      LoggingService().warning(
        'Failed to check latest version: $e2',
        component: componentName,
      );
      throw YtdlpException('Failed to check latest version: $e2');
    } finally {
      plain?.close(force: true);
    }
  }
}
