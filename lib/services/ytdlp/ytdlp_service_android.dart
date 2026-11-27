import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/video_info.dart';
import '../../models/playlist_info.dart';
import '../notification/notification_service.dart';
import '../core/logging_service.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/version_utils.dart';
import '../../core/utils/error_helper.dart';
import '../../core/utils/url_validator.dart';
import 'native_ytdlp_android.dart';
import 'video_info_cache.dart';
import 'ytdlp_release_checker.dart';
import 'ytdlp_tool_service.dart';

export 'ytdlp_tool_service.dart' show YtdlpUpdateInfo;

/// Android yt-dlp service powered by youtubedl-android native library
class YtdlpServiceAndroid implements YtdlpToolService {
  String? _cookiePath;
  String? _webViewPath;
  String? _ffmpegPath;
  String? _userAgent;
  bool _enableCookies = false;
  bool _isInitialized = false;
  String? _installedVersion;
  Future<String?>? _versionProbe;
  final YtdlpReleaseChecker _releaseChecker = YtdlpReleaseChecker(
    componentName: 'YtdlpServiceAndroid',
  );

  final LoggingService _logger = LoggingService();

  // Cancellation support (mirrors Windows) + native request ID tracking
  int _fetchGen = 0;
  int _requestSeq = 0;
  final Set<String> _activeFetchRequestIds = {};

  @override
  Future<void> cancelFetch() async {
    _fetchGen++;
    final reqIds = _activeFetchRequestIds.toList();
    _activeFetchRequestIds.clear();
    _videoCache.clearInFlight();
    _playlistCache.clearInFlight();
    if (reqIds.isEmpty) {
      await NativeYtdlpAndroid.cancelFetch();
    } else {
      for (final reqId in reqIds) {
        await NativeYtdlpAndroid.cancelFetch(requestId: reqId);
      }
    }
    _logger.info(
      'Android fetch cancelled by user (gen $_fetchGen, reqIds=$reqIds)',
      component: 'YtdlpServiceAndroid',
    );
  }

  /// Default concurrent fragment count for yt-dlp `-N`. Overridable via
  /// downloadVideo's [concurrentFragments] parameter.
  /// Tuned to 8 (down from 16) with native shared cap across active downloads
  /// to preserve throughput while reducing socket/thermal contention.
  static const int defaultConcurrentFragments = 8;

  /// In-memory getVideoInfo cache keyed by normalized URL + auth context
  /// with a 10-minute TTL and 30-entry LRU cap.
  static final MetadataCache<VideoInfo> _videoCache = MetadataCache<VideoInfo>();
  static final MetadataCache<PlaylistInfo> _playlistCache =
      MetadataCache<PlaylistInfo>();

  /// Build cache key including normalized URL and authentication context.
  String _buildVideoInfoCacheKey(String url) {
    final normalized = UrlValidator.normalizeVideoUrl(url);
    return [
      normalized,
      _enableCookies.toString(),
      _enableCookies ? (_cookiePath ?? '') : '',
      _userAgent ?? '',
    ].join('|');
  }

  /// Returns true when a non-expired cached [VideoInfo] exists for [url]
  /// under the current authentication context.
  @override
  bool hasCachedVideoInfo(String url) =>
      _videoCache.hasValid(_buildVideoInfoCacheKey(url));

  /// Drop cached video info (all URLs, or a single URL across auth variants).
  @visibleForTesting
  void invalidateVideoInfoCache([String? url]) {
    if (url == null) {
      _videoCache.clear();
    } else {
      final normalized = UrlValidator.normalizeVideoUrl(url);
      _videoCache.removeWhere(
        (key) => key == url || key.startsWith('$normalized|'),
      );
    }
  }

  void _checkFetchGeneration(int gen) {
    if (gen != _fetchGen) {
      throw YtdlpFetchCancelledException('Fetch cancelled by user');
    }
  }

  YtdlpServiceAndroid({
    String? cookiePath,
    String? webViewPath,
    String? ffmpegPath,
    NotificationService? notificationService,
  }) : _cookiePath = cookiePath,
       _webViewPath = webViewPath,
       _ffmpegPath = ffmpegPath;

  @override
  String get ytdlpPath => 'yt-dlp';
  @override
  set ytdlpPath(String v) {}
  @override
  void markReady(String version) {
    if (version.trim().isEmpty || version == 'Unknown') return;
    _installedVersion = version;
    _isInitialized = true;
  }

  @override
  set cookiePath(String? path) => _cookiePath = path;
  @override
  String? get cookiePath => _cookiePath;
  @override
  String? get cookieBrowser => null;
  @override
  set cookieBrowser(String? v) {}
  @override
  set webViewPath(String? path) => _webViewPath = path;
  @override
  String? get webViewPath => _webViewPath;
  @override
  set ffmpegPath(String? path) => _ffmpegPath = path;
  @override
  String? get ffmpegPath => _ffmpegPath;
  @override
  set userAgent(String? ua) => _userAgent = ua;
  @override
  String? get userAgent => _userAgent;
  @override
  set enableCookies(bool value) => _enableCookies = value;
  @override
  bool get enableCookies => _enableCookies;

  bool get isUsingCookies => _enableCookies && _cookiePath != null;
  String? get activeCookieSource => null;

  /// Initialize the service
  @override
  Future<void> initialize({bool force = false}) async {
    if (_isInitialized && !force) return;
    if (force) {
      _installedVersion = null;
      _isInitialized = false;
    }

    _logger.info(
      'Starting Android yt-dlp initialization (native library)',
      component: 'YtdlpServiceAndroid',
    );

    try {
      // Check if we have a cookie file path
      // Note: On Android, we often use NativeYtdlpAndroid which handles its own initialization

      // Log the current yt-dlp version for debugging
      final version = await getVersion();
      if (version == null || version.trim().isEmpty || version == 'Unknown') {
        throw YtdlpAndroidException('Native yt-dlp is not ready');
      }
      _logger.info(
        'yt-dlp version: $version',
        component: 'YtdlpServiceAndroid',
      );

      _isInitialized = true;
      _logger.info(
        'Android yt-dlp service initialized',
        component: 'YtdlpServiceAndroid',
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to initialize Android yt-dlp service',
        component: 'YtdlpServiceAndroid',
        error: e,
        stackTrace: stackTrace,
      );
      throw YtdlpAndroidException('Initialization failed: $e');
    }
  }

  /// Check if yt-dlp is available
  @override
  Future<bool> isAvailable() async {
    if (_isInitialized) return true;
    try {
      final version = await getVersion();
      return version != null && version.isNotEmpty && version != 'Unknown';
    } catch (e) {
      _logger.error(
        'Error checking yt-dlp availability',
        component: 'YtdlpServiceAndroid',
        error: e,
      );
      return false;
    }
  }

  /// Get yt-dlp version
  @override
  Future<String?> getVersion() {
    if (_installedVersion != null) return Future.value(_installedVersion);
    return _versionProbe ??= _probeInstalledVersion();
  }

  Future<String?> _probeInstalledVersion() async {
    try {
      final version = await NativeYtdlpAndroid.getVersion();
      if (version != null) markReady(version);
      return version;
    } catch (e) {
      return null;
    } finally {
      _versionProbe = null;
    }
  }

  /// Get latest available version - uses GitHub API (rate-limit friendly)
  @override
  Future<String?> getLatestVersion({bool forceRefresh = false}) =>
      _releaseChecker.getLatestVersion(forceRefresh: forceRefresh);

  bool _isNewerVersion(String current, String latest) =>
      VersionUtils.isNewerVersion(current, latest);

  /// Check if a newer version is available - uses GitHub API
  @override
  Future<YtdlpUpdateInfo?> checkForUpdateWithProgress() async {
    try {
      final currentVersion = await getVersion();
      if (currentVersion == null) {
        return null;
      }

      final latestVersion = await getLatestVersion(forceRefresh: true);

      if (latestVersion == null) {
        return YtdlpUpdateInfo(
          currentVersion: currentVersion,
          latestVersion: currentVersion,
          downloadUrl: AppConstants.ytdlpAndroidDownloadUrl,
          publishedAt: DateTime.now(),
          releaseNotes: 'Update check failed',
        );
      }

      final hasUpdate = _isNewerVersion(currentVersion, latestVersion);

      return YtdlpUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        downloadUrl: AppConstants.ytdlpAndroidDownloadUrl,
        publishedAt: DateTime.now(),
        releaseNotes: hasUpdate
            ? 'New version available: $latestVersion'
            : 'Up to date',
      );
    } catch (e, stackTrace) {
      if (e.toString().toLowerCase().contains('rate limit') ||
          e.toString().contains('403') ||
          e.toString().contains('429')) {
        _logger.warning(
          'Rate limited while checking yt-dlp updates: $e',
          component: 'YtdlpServiceAndroid',
        );
        rethrow;
      }
      _logger.error(
        'Failed to check for updates',
        component: 'YtdlpServiceAndroid',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Download and install update with progress callback
  @override
  Future<bool> downloadAndInstallUpdate(
    String downloadUrl, {
    required Function(double progress) onProgress,
    required Function(String status) onStatus,
    bool Function()? isCancelled,
  }) async {
    StreamSubscription<Map<String, dynamic>>? progressSubscription;
    try {
      if (isCancelled?.call() == true) {
        onStatus('Cancelled');
        return false;
      }

      // The native updater initializes the bundled runtime. It can be called
      // even when Dart could not get an installed version.
      onStatus('Updating yt-dlp…');

      progressSubscription = NativeYtdlpAndroid.downloadEvents.listen((event) {
        if (event['event'] == 'progress') {
          final progress = (event['progress'] as num?)?.toDouble() ?? 0.0;
          onProgress(progress);
        }
      });

      final result = await NativeYtdlpAndroid.updateYoutubeDL(
        updateChannel: 'stable',
      );

      onProgress(1.0);

      final status = result['status'] as String?;
      if (result['success'] == true) {
        // An update changes the installed binary. Never retain the old
        // availability/version snapshot after installing it.
        _installedVersion = null;
        _isInitialized = false;
        final updatedVersion = result['version'] as String?;
        if (updatedVersion != null) markReady(updatedVersion);
        if (status == 'up_to_date') {
          onStatus('Already up to date!');
        } else {
          final ver = result['version'] as String?;
          onStatus(
            ver != null ? 'Update complete (v$ver)!' : 'Update complete!',
          );
        }
        return true;
      } else {
        final error =
            result['error'] ??
            result['message'] ??
            'Native update failed (status: ${status ?? 'unknown'})';
        final suggestion = result['suggestion'] as String?;
        final displayMsg = suggestion != null
            ? '$error. $suggestion'
            : '$error';
        onStatus('Update failed: $displayMsg');
        return false;
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Update failed',
        component: 'YtdlpServiceAndroid',
        error: e,
        stackTrace: stackTrace,
      );
      final errorHelper = ErrorHelper.parse(e.toString());
      final msg = errorHelper.suggestion != null
          ? '${errorHelper.friendlyMessage}: ${errorHelper.suggestion}'
          : errorHelper.friendlyMessage;
      onStatus('Update failed: $msg');
      return false;
    } finally {
      await progressSubscription?.cancel();
    }
  }

  @override
  Future<bool> update() async {
    return downloadAndInstallUpdate(
      AppConstants.ytdlpAndroidDownloadUrl,
      onProgress: (_) {},
      onStatus: (_) {},
    );
  }

  /// Handle "broken" yt-dlp errors by recommending an update.
  /// Shared with Windows via [ErrorHelper.isBrokenExtractorError].
  bool isBrokenError(String error) => ErrorHelper.isBrokenExtractorError(error);

  /// Fetch video information from URL
  @override
  Future<VideoInfo> getVideoInfo(
    String url, {
    Function(String status)? onProgress,
  }) async {
    final gen = _fetchGen;
    final cacheKey = _buildVideoInfoCacheKey(url);

    final cached = _videoCache.get(cacheKey);
    if (cached != null) {
      _logger.debug(
        'Returning cached video info for: $url',
        component: 'YtdlpServiceAndroid',
      );
      return cached;
    }

    // Deduplicate concurrent in-flight requests for the same normalized URL + auth.
    final existingInFlight = _videoCache.getInFlight(cacheKey);
    if (existingInFlight != null) {
      _logger.debug(
        'Joining in-flight video info request for: $url',
        component: 'YtdlpServiceAndroid',
      );
      onProgress?.call('Finding video details and available formats...');
      return existingInFlight;
    }

    onProgress?.call('Finding video details and available formats...');

    _logger.info(
      'Getting video info for: $url',
      component: 'YtdlpServiceAndroid',
    );

    final requestId = 'fetch_info_${++_requestSeq}_$gen';
    _activeFetchRequestIds.add(requestId);

    final future = () async {
      try {
        final info = await NativeYtdlpAndroid.getVideoInfoParsed(
          url,
          cookiesPath: _enableCookies ? _cookiePath : null,
          userAgent: _userAgent,
          requestId: requestId,
        );

        _checkFetchGeneration(gen);

        _videoCache.put(cacheKey, info);
        return info;
      } on TimeoutException {
        await NativeYtdlpAndroid.cancelFetch(requestId: requestId);
        rethrow;
      } on NativeFetchCancelledException catch (e) {
        throw YtdlpFetchCancelledException(e.message);
      } catch (e, stackTrace) {
        if (e is YtdlpFetchCancelledException) {
          rethrow;
        }
        _logger.error(
          'Failed to get video info',
          component: 'YtdlpServiceAndroid',
          error: e,
          stackTrace: stackTrace,
        );
        rethrow;
      } finally {
        _activeFetchRequestIds.remove(requestId);
      }
    }();

    return _videoCache.trackInFlight(cacheKey, future);
  }

  /// Fetch playlist information from URL
  @override
  Future<PlaylistInfo> getPlaylistInfo(
    String url, {
    String? playlistItems,
    Function(String status)? onProgress,
  }) async {
    final gen = _fetchGen;
    final cacheKey =
        '${_buildVideoInfoCacheKey(url)}|items=${playlistItems?.trim() ?? ''}';
    final cached = _playlistCache.get(cacheKey);
    if (cached != null) {
      return cached;
    }
    final existingInFlight = _playlistCache.getInFlight(cacheKey);
    if (existingInFlight != null) {
      onProgress?.call('Fetching playlist information...');
      return existingInFlight;
    }

    final requestId = 'fetch_playlist_${++_requestSeq}_$gen';
    _activeFetchRequestIds.add(requestId);

    onProgress?.call('Fetching playlist information...');

    _logger.info(
      'Getting playlist info for: $url'
      '${playlistItems != null ? ' (items=$playlistItems)' : ''}',
      component: 'YtdlpServiceAndroid',
    );

    final future = () async {
      try {
        final result = await NativeYtdlpAndroid.getPlaylistInfo(
          url,
          cookiesPath: _enableCookies ? _cookiePath : null,
          userAgent: _userAgent,
          playlistItems: playlistItems,
          requestId: requestId,
        );

        _checkFetchGeneration(gen);

        _logger.debug(
          'Raw playlist info result keys: ${result.keys.join(', ')}',
          component: 'YtdlpServiceAndroid',
        );

        final playlistData = result['playlist'];
        if (playlistData == null) {
          throw YtdlpAndroidException('No playlist object found in result');
        }

        final info = PlaylistInfo.fromJson(
          result['playlist'] as Map<String, dynamic>,
        );
        _playlistCache.put(cacheKey, info);
        return info;
      } on NativeFetchCancelledException catch (e) {
        throw YtdlpFetchCancelledException(e.message);
      } catch (e, stackTrace) {
        if (e is YtdlpFetchCancelledException) {
          rethrow;
        }
        _logger.error(
          'Failed to get playlist info',
          component: 'YtdlpServiceAndroid',
          error: e,
          stackTrace: stackTrace,
        );
        rethrow;
      } finally {
        _activeFetchRequestIds.remove(requestId);
      }
    }();

    return _playlistCache.trackInFlight(cacheKey, future);
  }

  /// yt-dlp search fallback used when youtube_explode search fails.
  /// Returns a raw yt-dlp flat-playlist JSON map (`entries` array).
  @override
  Future<Map<String, dynamic>> searchVideosRaw(
    String query, {
    int limit = 10,
  }) async {
    final gen = _fetchGen;
    final requestId = 'fetch_search_${++_requestSeq}_$gen';
    _activeFetchRequestIds.add(requestId);
    try {
      final result = await NativeYtdlpAndroid.searchVideos(
        query,
        limit: limit,
        cookiesPath: _enableCookies ? _cookiePath : null,
        userAgent: _userAgent,
        requestId: requestId,
      );
      _checkFetchGeneration(gen);
      return result;
    } on NativeFetchCancelledException catch (e) {
      throw YtdlpFetchCancelledException(e.message);
    } finally {
      _activeFetchRequestIds.remove(requestId);
    }
  }

  /// Enqueue a download on the native yt-dlp library.
  ///
  /// Returns the process id once native work has been accepted, or null if
  /// enqueueing failed. This does NOT wait for the download to finish —
  /// terminal outcomes arrive only via [NativeYtdlpAndroid.downloadEvents].
  Future<String?> downloadVideo({
    required String url,
    required String outputPath,
    String? formatId,
    String? audioFormatId,
    String? processId,
    bool audioOnly = false,
    String? audioQuality,
    int? targetHeight,
    bool embedThumbnail = true,
    bool embedMetadata = true,
    List<String>? subtitleLanguages,
    bool embedSubtitles = false,
    bool sponsorBlock = false,
    String? archivePath,
    int? concurrentFragments,
    Function(double progress, String line, int eta)? onProgress,
  }) async {
    StreamSubscription<Map<String, dynamic>>? progressSubscription;
    try {
      // Build format string.
      //
      // Plan 2.4: progressive auto-select for ≤720p (single stream, no
      // merge). Dual-stream only for explicit 1080p+ quality. The default
      // without an explicit target is progressive `best[ext=mp4]/best` —
      // half the work of the old bestvideo+bestaudio default.
      final String format;
      if (audioOnly) {
        format = audioFormatId ?? 'bestaudio';
      } else if (formatId != null && audioFormatId != null) {
        format = '$formatId+$audioFormatId';
      } else if (formatId != null) {
        format = formatId;
      } else if (targetHeight != null && targetHeight <= 720) {
        format =
            'best[height<=$targetHeight][ext=mp4]/best[height<=$targetHeight]/best[ext=mp4]/best';
      } else if (targetHeight != null) {
        format =
            'bestvideo[height<=$targetHeight][ext=mp4]+bestaudio[ext=m4a]/best[height<=$targetHeight]/best';
      } else {
        format = 'best[ext=mp4]/best';
      }

      // Generate process ID for tracking
      final processIdToUse =
          processId ?? 'download_${DateTime.now().millisecondsSinceEpoch}';

      _logger.info(
        'Enqueueing download: $url -> $outputPath (format=$format)',
        component: 'YtdlpServiceAndroid',
      );

      if (onProgress != null) {
        progressSubscription = NativeYtdlpAndroid.downloadEvents.listen((
          event,
        ) {
          if (event['process_id'] == processIdToUse &&
              event['event'] == 'progress') {
            final progress = (event['progress'] as num?)?.toDouble() ?? 0.0;
            final eta = (event['eta'] as num?)?.toInt() ?? 0;
            // Kotlin sends `line` as a String (the yt-dlp stdout progress
            // text, e.g. "[download] 45.2% of 150MiB at 5MiB/s ETA 00:30"),
            // NOT a number. Casting to `num?` threw a TypeError on every
            // progress event (M15). Read it as a String instead; callers that
            // need the speed value parse it via the progress-line regex (see
            // MobileDownloadProvider._extractSpeedBytesPerSecond).
            final line = (event['line'] ?? '').toString();
            onProgress(progress, line, eta);
          }
        });
      }

      final result = await NativeYtdlpAndroid.downloadVideo(
        url: url,
        outputPath: outputPath,
        format: format,
        cookiesPath: _enableCookies ? _cookiePath : null,
        userAgent: _userAgent,
        processId: processIdToUse,
        archivePath: archivePath,
        subtitleLanguages: subtitleLanguages,
        embedSubtitles: embedSubtitles,
        sponsorBlock: sponsorBlock,
        embedThumbnail: embedThumbnail,
        embedMetadata: embedMetadata,
        audioOnly: audioOnly,
        targetHeight: targetHeight,
        audioQuality: audioQuality,
        concurrentFragments: concurrentFragments ?? defaultConcurrentFragments,
      );

      if (result['success'] != true) {
        final error = result['error'] ?? 'Unknown error';
        _logger.error(
          'Failed to enqueue download: $error',
          component: 'YtdlpServiceAndroid',
        );
        return null;
      }

      // Enqueue accepted. process_id is the handle for EventChannel events;
      // do not treat this return as download completion.
      return result['process_id'] as String?;
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to enqueue download',
        component: 'YtdlpServiceAndroid',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      // Optional caller progress subscription is only for the enqueue call;
      // ongoing progress is consumed by the provider via downloadEvents.
      await progressSubscription?.cancel();
    }
  }

  /// Cancel every active native download (playlist bulk-cancel / app exit).
  ///
  /// Prefers native `cancelAll`; falls back to cancelling each provided
  /// process id individually. Only cancels the ids the caller passes —
  /// never unrelated downloads.
  Future<void> cancelAllDownloads({Iterable<String>? processIds}) async {
    await NativeYtdlpAndroid.cancelAll(processIds: processIds);
    _logger.info(
      'cancelAllDownloads invoked (ids=${processIds?.length ?? 'native all'})',
      component: 'YtdlpServiceAndroid',
    );
  }
}

class YtdlpAndroidException implements Exception {
  final String message;
  YtdlpAndroidException(this.message);
  @override
  String toString() => 'YtdlpAndroidException: $message';
}

/// Thrown when a fetch (getVideoInfo / getPlaylistInfo) is aborted because
/// [YtdlpServiceAndroid.cancelFetch] bumped the generation while the native
/// call was in flight. Callers should treat this as a user cancel, not a
/// failure.
class YtdlpFetchCancelledException implements Exception {
  final String message;
  YtdlpFetchCancelledException(this.message);
  @override
  String toString() => 'YtdlpFetchCancelledException: $message';
}
