import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/download_item.dart';
import '../../models/video_info.dart';
import '../../models/playlist_info.dart';
import '../notification/notification_service.dart';
import '../core/logging_service.dart';
import '../core/download_helper.dart';
import 'video_info_cache.dart';
import 'ytdlp_release_checker.dart';
import 'ytdlp_tool_service.dart';
import '../core/certificate_pinning_service.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/platform_utils.dart';
import '../../core/utils/url_validator.dart';
import '../../core/utils/version_utils.dart';
import '../../core/utils/error_helper.dart';

export 'ytdlp_tool_service.dart' show YtdlpUpdateInfo;

VideoInfo _parseVideoInfoIsolate(String stdout) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) {
    throw YtdlpException(
      'Failed to fetch video info: Empty output from yt-dlp',
    );
  }
  final lines = trimmed.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) {
    throw YtdlpException(
      'Failed to fetch video info: No valid JSON lines in output',
    );
  }
  String? jsonLine;
  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('{')) {
      jsonLine = t;
      break;
    }
  }
  if (jsonLine == null) {
    throw YtdlpException(
      'Failed to fetch video info: No JSON object found in output',
    );
  }
  final json = jsonDecode(jsonLine) as Map<String, dynamic>;
  return VideoInfo.fromJson(json);
}

class YtdlpService implements YtdlpToolService {
  String _ytdlpPath;
  String? _cookiePath;
  String? _cookieBrowser;
  String? _webViewPath;
  String? _ffmpegPath;
  String? _userAgent;
  bool _enableCookies = false;
  bool _isInitialized = false;
  final CertificatePinningService _certPinningService =
      CertificatePinningService();
  late final YtdlpReleaseChecker _releaseChecker = YtdlpReleaseChecker(
    componentName: 'YtdlpService',
    clientFactory: _certPinningService.createPinnedHttpClient,
  );
  final MetadataCache<VideoInfo> _videoCache = MetadataCache<VideoInfo>();
  final MetadataCache<PlaylistInfo> _playlistCache = MetadataCache<PlaylistInfo>();
  String? _cachedVersion;
  String? _extractorCachePath;
  String? _pluginDirPath;

  static const String _ejsCachePluginSource = '''import os
import sys

try:
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = True
except Exception:
    pass


def _prune_challenge_cache():
    try:
        argv = sys.argv
        if '--cache-dir' not in argv:
            return
        idx = argv.index('--cache-dir')
        if idx + 1 >= len(argv):
            return
        cache_dir = os.path.join(argv[idx + 1], 'challenge-solver')
        if not os.path.isdir(cache_dir):
            return
        players = []
        for name in os.listdir(cache_dir):
            if name.startswith('player') and name.endswith('.json'):
                p = os.path.join(cache_dir, name)
                try:
                    players.append((os.path.getmtime(p), p))
                except OSError:
                    pass
        if len(players) > 3:
            players.sort(reverse=True)
            for _, old_path in players[3:]:
                try:
                    os.remove(old_path)
                except OSError:
                    pass
    except Exception:
        pass


_prune_challenge_cache()
''';

  static const String _windowsDownloadUrl =
      AppConstants.ytdlpWindowsDownloadUrl;
  static const String _linuxDownloadUrl = AppConstants.ytdlpLinuxDownloadUrl;
  static const String _macosDownloadUrl = AppConstants.ytdlpMacosDownloadUrl;

  YtdlpService({
    String? ytdlpPath,
    String? cookiePath,
    String? cookieBrowser,
    String? webViewPath,
    String? ffmpegPath,
    NotificationService? notificationService,
  }) : _ytdlpPath = ytdlpPath ?? 'yt-dlp',
       _cookiePath = cookiePath,
       _cookieBrowser = cookieBrowser,
       _webViewPath = webViewPath,
       _ffmpegPath = ffmpegPath;

  @override
  set ytdlpPath(String path) {
    if (_ytdlpPath != path) {
      _ytdlpPath = path;
      _cachedVersion = null;
    }
  }

  @override
  String get ytdlpPath => _ytdlpPath;
  @override
  set cookiePath(String? path) => _cookiePath = path;
  @override
  String? get cookiePath => _cookiePath;
  @override
  set cookieBrowser(String? browser) => _cookieBrowser = browser;
  @override
  String? get cookieBrowser => _cookieBrowser;
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

  bool get isUsingCookies =>
      _enableCookies &&
      ((_cookiePath != null && File(_cookiePath!).existsSync()) ||
          (_cookieBrowser != null && _cookieBrowser != 'none') ||
          (_webViewPath != null));

  String? get activeCookieSource {
    if (_cookiePath != null) return 'file';
    // H4: null != 'none' is true in Dart — must null-check before comparing.
    if (_cookieBrowser != null && _cookieBrowser != 'none') return 'browser';
    if (_webViewPath != null) return 'webview';
    return null;
  }

  /// H7: true when cookies-from-browser / WebView profile is the active
  /// auth source. In that case a hardcoded Chrome UA can mismatch the
  /// browser session and cause YouTube to reject it — skip --user-agent.
  bool get _usesBrowserCookieSource =>
      _enableCookies &&
      (_webViewPath != null ||
          (_cookieBrowser != null && _cookieBrowser != 'none'));

  Future<void> _ensureExtractorCacheAndPlugin() async {
    if (_extractorCachePath != null && _pluginDirPath != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _extractorCachePath = p.join(dir.path, 'ytdlp-extractor');
      _pluginDirPath = p.join(dir.path, 'aerotube-ytdlp-plugins');

      final pluginDir = Directory(
        p.join(_pluginDirPath!, 'ejs_cache', 'yt_dlp_plugins', 'extractor'),
      );
      if (!await pluginDir.exists()) {
        await pluginDir.create(recursive: true);
      }
      final pluginFile = File(p.join(pluginDir.path, 'aerotube_ejs_cache.py'));
      if (!await pluginFile.exists() ||
          await pluginFile.readAsString() != _ejsCachePluginSource) {
        await pluginFile.writeAsString(_ejsCachePluginSource);
      }
    } catch (e) {
      LoggingService().warning(
        'Failed to prepare yt-dlp EJS cache plugin: $e',
        component: 'YtdlpService',
      );
    }
  }

  /// Initialize the service: locate or download yt-dlp
  @override
  Future<void> initialize({bool force = false}) async {
    if (_isInitialized && !force) return;
    if (force) {
      _isInitialized = false;
      _cachedVersion = null;
    }

    try {
      final dir = await getApplicationSupportDirectory();
      await _ensureExtractorCacheAndPlugin();
      final executableName = PlatformUtils.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
      final localPath = p.join(dir.path, 'bin', executableName);
      final localFile = File(localPath);

      // If the current path is NOT the default 'yt-dlp' AND not our managed local path,
      // it means the user (or settings) provided a custom path. We should respect it.
      if (_ytdlpPath != 'yt-dlp' && _ytdlpPath != localPath) {
        // Verify if it exists, if not, try adding .exe on Windows
        if (!await File(_ytdlpPath).exists()) {
          if (PlatformUtils.isWindows &&
              !_ytdlpPath.toLowerCase().endsWith('.exe')) {
            final withExe = '$_ytdlpPath.exe';
            if (await File(withExe).exists()) {
              // Use public setter so cache is invalidated on path change
              ytdlpPath = withExe;
            }
          }
        }
        _isInitialized = true;
        return;
      }

      if (await localFile.exists()) {
        // Use public setter so the availability cache is cleared when
        // the resolved local path differs from the current value.
        ytdlpPath = localPath;
      } else {
        // If not in local path and not in system PATH, download it
        if (await isAvailable()) {
          _isInitialized = true;
          return;
        }

        await _downloadYtdlp(localFile);
        // Use setter to ensure cache is cleared after download
        ytdlpPath = localPath;
      }

      _isInitialized = true;
    } catch (e) {
      // Fallback to system PATH if initialization fails
    }
  }

  /// Download yt-dlp binary (runs in a background isolate for full speed)
  Future<void> _downloadYtdlp(File targetFile) async {
    if (!await targetFile.parent.exists()) {
      await targetFile.parent.create(recursive: true);
    }

    final url = PlatformUtils.isWindows
        ? _windowsDownloadUrl
        : PlatformUtils.isMacOS
        ? _macosDownloadUrl
        : _linuxDownloadUrl;
    // Use a private temp directory with a random suffix (O_EXCL semantics)
    // instead of a guessable millisecond-timestamp name in the shared temp
    // dir, which was vulnerable to predicted-name symlink/hijack races (M11).
    final tempDir = await Directory.systemTemp.createTemp('yt-dlp-dl-');
    final tempFileName = PlatformUtils.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    final tempPath = p.join(tempDir.path, tempFileName);

    try {
      await downloadInBackground(url: url, destPath: tempPath);

      // Atomic replace: copy to .new then rename, preserving original until new is ready (B16)
      if (await targetFile.exists()) {
        final backupFile = File('${targetFile.path}.bak');
        final newFile = File('${targetFile.path}.new');
        // Clean stale temp files
        try {
          if (await backupFile.exists()) await backupFile.delete();
        } catch (_) {}
        try {
          if (await newFile.exists()) await newFile.delete();
        } catch (_) {}
        await File(tempPath).copy(newFile.path);
        await targetFile.rename(backupFile.path);
        try {
          await newFile.rename(targetFile.path);
          await backupFile.delete();
        } catch (e) {
          // Restore original on failure
          try {
            if (await targetFile.exists()) await targetFile.delete();
          } catch (_) {}
          try {
            await backupFile.rename(targetFile.path);
          } catch (_) {}
          try {
            if (await newFile.exists()) await newFile.delete();
          } catch (_) {}
          throw YtdlpException('Failed to copy temp file: $e');
        }
      } else {
        // No existing binary: copy via temp .new then rename for atomicity
        final newFile = File('${targetFile.path}.new');
        try {
          if (await newFile.exists()) await newFile.delete();
        } catch (_) {}
        await File(tempPath).copy(newFile.path);
        await newFile.rename(targetFile.path);
      }

      if (!PlatformUtils.isWindows) {
        await Process.run('chmod', ['+x', targetFile.path]);
      }
    } catch (e) {
      throw YtdlpException('Failed to download yt-dlp: $e');
    } finally {
      try {
        // Recursively delete the private temp directory (binary + anything
        // written alongside it).
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } catch (e) {
        LoggingService().debug(
          'Failed to delete temp yt-dlp binary: $e',
          component: 'YtdlpService',
        );
      }
    }
  }

  @override
  Future<bool> update() async {
    try {
      final result = await _runWithTimeoutTracked(
        ['-U'],
        const Duration(seconds: 45),
        timeoutMessage: 'yt-dlp -U timed out',
      );
      if (result.exitCode == 0) {
        _cachedVersion = null;
        return true;
      }
      LoggingService().warning(
        'yt-dlp -U exited with code ${result.exitCode}, falling back to direct release download',
        component: 'YtdlpService',
      );
    } catch (e) {
      LoggingService().warning(
        'yt-dlp -U failed: $e, falling back to direct release download',
        component: 'YtdlpService',
      );
    }

    // Direct binary download fallback — pick URL by platform (not always .exe).
    final url = PlatformUtils.isWindows
        ? _windowsDownloadUrl
        : PlatformUtils.isMacOS
        ? _macosDownloadUrl
        : _linuxDownloadUrl;
    return downloadAndInstallUpdate(url, onProgress: (_) {}, onStatus: (_) {});
  }

  /// Check if yt-dlp is available.
  ///
  /// NOTE: No result caching here on purpose — caching `false` before
  /// [initialize] resolves the managed binary path would produce a permanent
  /// false-negative that persists for the lifetime of the service.  The probe
  /// is a simple `--version` call (~5 ms) so the cost is negligible.
  @override
  Future<bool> isAvailable() async {
    // Fast-path: once yt-dlp has been verified for the current path, avoid
    // spawning a ~300-800ms PyInstaller process on every fetch. Never cache
    // false so a later install/path fix still succeeds.
    if (_cachedVersion != null) {
      if (!p.isAbsolute(_ytdlpPath) || File(_ytdlpPath).existsSync()) {
        return true;
      }
      _cachedVersion = null;
    }
    try {
      // First try with current path
      var result = await Process.run(_ytdlpPath, ['--version']);
      if (result.exitCode == 0) {
        _cachedVersion = (result.stdout as String).trim();
        return true;
      }

      // On Windows, retry with .exe suffix if the bare name failed
      if (PlatformUtils.isWindows &&
          !_ytdlpPath.toLowerCase().endsWith('.exe')) {
        result = await Process.run('$_ytdlpPath.exe', ['--version']);
        if (result.exitCode == 0) {
          ytdlpPath = '$_ytdlpPath.exe'; // setter clears version cache
          _cachedVersion = (result.stdout as String).trim();
          return true;
        }
      }

      return false;
    } catch (e) {
      // If process launch fails on Windows, retry with .exe
      if (PlatformUtils.isWindows &&
          !_ytdlpPath.toLowerCase().endsWith('.exe')) {
        try {
          final result = await Process.run('$_ytdlpPath.exe', ['--version']);
          if (result.exitCode == 0) {
            ytdlpPath = '$_ytdlpPath.exe'; // setter clears version cache
            _cachedVersion = (result.stdout as String).trim();
            return true;
          }
        } catch (e) {
          LoggingService().warning(
            'yt-dlp .exe fallback check failed: $e',
            component: 'YtdlpService',
          );
        }
      }
      return false;
    }
  }

  /// Lightweight binary check for background isolate (compute).
  /// Returns version string if available, null otherwise.
  static Future<String?> checkBinaryAvailable(String path) async {
    try {
      var result = await Process.run(path, ['--version']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
      if (PlatformUtils.isWindows && !path.toLowerCase().endsWith('.exe')) {
        result = await Process.run('$path.exe', ['--version']);
        if (result.exitCode == 0) {
          return (result.stdout as String).trim();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Called after background isolate confirms binary works.
  /// Skips full initialize() I/O.
  @override
  void markReady(String version) {
    _cachedVersion = version;
    _isInitialized = true;
  }

  @override
  Future<String?> getVersion() async {
    if (_cachedVersion != null) return _cachedVersion;
    try {
      final result = await Process.run(_ytdlpPath, ['--version']);
      if (result.exitCode == 0) {
        _cachedVersion = (result.stdout as String).trim();
        return _cachedVersion;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Check if a newer version of yt-dlp is available on GitHub
  @override
  Future<String?> getLatestVersion({bool forceRefresh = false}) =>
      _releaseChecker.getLatestVersion(forceRefresh: forceRefresh);

  bool isNewerVersion(String current, String latest) =>
      VersionUtils.isNewerVersion(current, latest);

  /// Detect if an error suggests yt-dlp is broken or outdated.
  /// Shared with Android via [ErrorHelper.isBrokenExtractorError].
  bool isBrokenError(String error) => ErrorHelper.isBrokenExtractorError(error);

  // ── VPN helpers ──────────────────────────────────────────────────────
  bool _isVpnNetworkError(String msg) => ErrorHelper.isVpnOrNetworkError(msg);

  bool _isCookieRelatedError(String msg) {
    final l = msg.toLowerCase();
    return l.contains('dpapi') ||
        l.contains('failed to decrypt') ||
        l.contains('permission denied') && l.contains('cookie') ||
        l.contains('could not copy chrome cookie') ||
        l.contains('could not copy edge cookie') ||
        l.contains('cookies database is locked');
  }

  String _vpnFriendlyMessage(String original) {
    if (_isVpnNetworkError(original)) {
      return '$original\n\nTip: VPN may be slowing or blocking the connection (adds latency/packet loss). Try disabling VPN, switching server, or retrying in a few seconds.';
    }
    if (original.toLowerCase().contains('timed out')) {
      return '$original\n\nTip: Fetch timed out — VPN may be slowing connection. Try again or disable VPN temporarily.';
    }
    return original;
  }

  List<String> _buildVideoInfoArgsWithoutCookies(String url) {
    final validated = _validateUrl(url);
    final args = <String>[
      '--ignore-config',
      '--newline',
      '--no-playlist',
      '--skip-download',
      '--no-check-formats',
      if (_extractorCachePath != null) ...['--cache-dir', _extractorCachePath!],
      if (_pluginDirPath != null) ...['--plugin-dirs', _pluginDirPath!],
      '--retries',
      '4',
      '--extractor-retries',
      '3',
      '--socket-timeout',
      '30',
      '--retry-sleep',
      'linear=1:3',
      '--no-warnings',
      '--dump-single-json',
    ];
    if (_ffmpegPath != null && _ffmpegPath != 'ffmpeg') {
      args.addAll(['--ffmpeg-location', _ffmpegPath!]);
    }
    if (_userAgent != null) args.addAll(['--user-agent', _userAgent!]);
    args.addAll(['--', validated]);
    return args;
  }

  List<String> _buildVpnFallbackArgs(String url) {
    final validated = _validateUrl(url);
    final args = <String>[
      '--ignore-config',
      '--newline',
      '--no-playlist',
      '--skip-download',
      '--no-check-formats',
      if (_extractorCachePath != null) ...['--cache-dir', _extractorCachePath!],
      if (_pluginDirPath != null) ...['--plugin-dirs', _pluginDirPath!],
      '--retries',
      '4',
      '--extractor-retries',
      '3',
      '--socket-timeout',
      '30',
      '--retry-sleep',
      'linear=1:3',
      '--force-ipv4',
      '--no-warnings',
      // YouTube-only extractor hint — harmless elsewhere but skip for non-YT.
      if (UrlValidator.isYouTubeUrl(url)) ...[
        '--extractor-args',
        'youtube:player_client=android',
      ],
      '--dump-single-json',
    ];
    if (_ffmpegPath != null && _ffmpegPath != 'ffmpeg') {
      args.addAll(['--ffmpeg-location', _ffmpegPath!]);
    }
    if (_userAgent != null) args.addAll(['--user-agent', _userAgent!]);
    args.addAll(['--', validated]);
    return args;
  }

  /// Active process for cancellation support
  Process? _activeVideoProcess;
  Process? _activePlaylistProcess;
  int _videoFetchGen = 0;
  int _videoCancelGen = 0;
  // H29: set while cancelFetch is killing an in-flight playlist so the
  // non-zero exit is reported as Cancelled, not a hard failure.
  bool _playlistCancelRequested = false;

  @override
  Future<void> cancelFetch() async {
    _videoCancelGen++;
    _videoFetchGen++;
    _playlistCancelRequested = true;
    _videoCache.clearInFlight();
    _playlistCache.clearInFlight();
    final vProc = _activeVideoProcess;
    final pProc = _activePlaylistProcess;
    _activeVideoProcess = null;
    _activePlaylistProcess = null;
    for (final proc in [vProc, pProc]) {
      if (proc != null) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
        try {
          proc.kill();
        } catch (_) {}
      }
    }
    LoggingService().info('Fetch cancelled by user', component: 'YtdlpService');
  }

  /// Returns true when a non-expired cached [VideoInfo] exists for [url]
  /// under the current authentication context.
  @override
  bool hasCachedVideoInfo(String url) =>
      _videoCache.hasValid(_buildVideoInfoCacheKey(url));

  /// Fetch video information from URL with retry logic for authentication
  /// VPN-resilient: per-attempt 45s, overall 120s, retries without cookies & ipv4 fallback
  @override
  Future<VideoInfo> getVideoInfo(
    String url, {
    Function(String status)? onProgress,
  }) async {
    final cancelGen = _videoCancelGen;
    if (!_isInitialized) await initialize();
    if (cancelGen != _videoCancelGen) throw YtdlpException('Cancelled');
    if (_extractorCachePath == null) await _ensureExtractorCacheAndPlugin();
    if (cancelGen != _videoCancelGen) throw YtdlpException('Cancelled');

    final cacheKey = _buildVideoInfoCacheKey(url);
    final cachedInfo = _videoCache.get(cacheKey);
    if (cachedInfo != null) {
      onProgress?.call('Using saved video details...');
      return cachedInfo;
    }

    final existingInFlight = _videoCache.getInFlight(cacheKey);
    if (existingInFlight != null) {
      onProgress?.call('Finding video details and available formats...');
      return existingInFlight;
    }

    return _videoCache.trackInFlight(
      cacheKey,
      _fetchVideoInfoUncached(url, cacheKey, onProgress: onProgress),
    );
  }

  Future<VideoInfo> _fetchVideoInfoUncached(
    String url,
    String cacheKey, {
    Function(String status)? onProgress,
  }) async {
    // Cancellation: bump generation, kill previous process
    final myGen = ++_videoFetchGen;
    try {
      _activeVideoProcess?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      _activeVideoProcess?.kill();
    } catch (_) {}

    onProgress?.call('Finding video details and available formats...');

    final stopwatch = Stopwatch()..start();
    // Overall budget still allows the full resilient chain (fast → patient →
    // auth/cookie/VPN fallbacks) without the provider giving up first.
    const overallTimeout = Duration(seconds: 120);
    const fastAttemptTimeout = Duration(seconds: 18);
    const patientAttemptTimeout = Duration(seconds: 45);
    Duration remainingOverall() {
      final r = overallTimeout - stopwatch.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    // Helper to run args with remaining-aware timeout + active process tracking
    Future<ProcessResult> runTracked(
      List<String> args,
      String timeoutMsg, {
      Duration perAttemptTimeout = patientAttemptTimeout,
    }) async {
      if (myGen != _videoFetchGen) throw YtdlpException('Cancelled');
      final effTimeout = remainingOverall();
      if (effTimeout.inSeconds < 5) {
        throw YtdlpException(
          'Fetch timed out — VPN may be slowing connection, try again or disable VPN.',
        );
      }
      final timeout = effTimeout < perAttemptTimeout
          ? effTimeout
          : perAttemptTimeout;
      LoggingService().debug(
        'Executing info fetch: $_ytdlpPath ${args.join(' ')} (timeout ${timeout.inSeconds}s)',
        component: 'YtdlpService',
      );
      try {
        final result = await _runWithTimeoutTracked(
          args,
          timeout,
          timeoutMessage: timeoutMsg,
          myGen: myGen,
        );
        return result;
      } on YtdlpException catch (e) {
        // Enrich timeout / VPN errors with friendly tip
        if (e.message.toLowerCase().contains('timed out') ||
            _isVpnNetworkError(e.message)) {
          throw YtdlpException(_vpnFriendlyMessage(e.message));
        }
        rethrow;
      }
    }

    ProcessResult? result;
    String lastError = '';

    // ── Attempt 1: FAST lean args ─────────────────────────────────────────
    // Short socket timeout + almost no in-process retries. On a healthy
    // network this is the common path and finishes in ~1–3s instead of
    // waiting out yt-dlp's 4×30s retry ladder. Content errors (private,
    // unavailable) fail immediately and skip the patient retry.
    try {
      result = await runTracked(
        _buildVideoInfoArgs(url, fast: true),
        'yt-dlp timed out fetching video info. Retrying with longer timeouts...',
        perAttemptTimeout: fastAttemptTimeout,
      );
      if (result.exitCode == 0) {
        return await _parseAndCacheVideoInfo(
          result.stdout as String,
          cacheKey,
          onProgress,
        );
      }
      lastError = (result.stderr as String).trim();
      LoggingService().warning(
        'Attempt 1 (fast) failed: $lastError',
        component: 'YtdlpService',
      );
    } on YtdlpException catch (e) {
      lastError = e.message;
      if (e.message.contains('Cancelled')) rethrow;
      // fall through — timeouts / VPN / auth handled below
    }

    // Content-class errors will not improve with more patient retries.
    final isContentError =
        lastError.isNotEmpty &&
        (lastError.toLowerCase().contains('video unavailable') ||
            lastError.toLowerCase().contains('private video') ||
            lastError.toLowerCase().contains('has been removed') ||
            lastError.toLowerCase().contains('not available') ||
            lastError.toLowerCase().contains('members-only') ||
            lastError.toLowerCase().contains('age-restricted') ||
            lastError.toLowerCase().contains('http error 404') ||
            lastError.toLowerCase().contains('http error 410'));

    // ── Attempt 2: PATIENT full retries (only on timeout/network) ─────────
    // Restores the old VPN-friendly ladder when the fast pass hit a slow
    // link or flaky socket. Skipped for content errors and auth (auth has
    // its own specialized fallbacks below).
    final needsPatientRetry =
        !isContentError &&
        lastError.isNotEmpty &&
        (_isVpnNetworkError(lastError) ||
            lastError.toLowerCase().contains('timed out') ||
            lastError.toLowerCase().contains('timeout'));
    if (needsPatientRetry) {
      if (remainingOverall().inSeconds < 5) {
        throw YtdlpException(_vpnFriendlyMessage(lastError));
      }
      onProgress?.call('Connection is slow. Trying again...');
      LoggingService().info(
        'Retrying getVideoInfo with patient timeouts due to: $lastError',
        component: 'YtdlpService',
      );
      try {
        result = await runTracked(
          _buildVideoInfoArgs(url, fast: false),
          'yt-dlp timed out fetching video info (45 s). VPN may be slowing connection, try again or disable VPN.',
        );
        if (result.exitCode == 0) {
          return await _parseAndCacheVideoInfo(
            result.stdout as String,
            cacheKey,
            onProgress,
          );
        }
        lastError = (result.stderr as String).trim();
        LoggingService().warning(
          'Attempt 2 (patient) failed: $lastError',
          component: 'YtdlpService',
        );
      } on YtdlpException catch (e) {
        if (e.message.contains('Cancelled')) rethrow;
        lastError = e.message;
      }
    }

    // Early auth check on lastError — if it's clearly auth, try player_client fallback before VPN fallback
    // (YouTube-only: player_client extractor args are YT-specific).
    if (lastError.isNotEmpty && UrlValidator.isYouTubeUrl(url)) {
      final authError = checkAuthenticationErrors(lastError);
      if (authError != null) {
        if (lastError.contains('Sign in to confirm you') ||
            lastError.contains('bot')) {
          onProgress?.call('Trying another way to access the video...');
          try {
            final retryArgs = <String>[
              '--ignore-config',
              '--newline',
              '--no-playlist',
              '--skip-download',
              '--no-warnings',
              if (_ffmpegPath != null) ...['--ffmpeg-location', _ffmpegPath!],
              if (_userAgent != null) ...['--user-agent', _userAgent!],
              if (_cookiePath != null && File(_cookiePath!).existsSync()) ...[
                '--cookies',
                _cookiePath!,
              ],
              '--extractor-args',
              'youtube:player_client=web,mweb,android,ios;player-skip=webpage,configs',
              '--dump-single-json',
              _validateUrl(url),
            ];
            final r2 = await runTracked(
              retryArgs,
              'yt-dlp auth retry timed out (45 s).',
            );
            if (r2.exitCode == 0) {
              return await _parseAndCacheVideoInfo(
                r2.stdout as String,
                cacheKey,
                onProgress,
              );
            }
            lastError = (r2.stderr as String).trim();
          } catch (e) {
            lastError = e.toString();
          }
        }
        // If still auth, don't throw yet — try VPN fallback which may bypass bot check via android client
        // but if overall time is low, throw
        if (remainingOverall().inSeconds < 10 &&
            _isVpnNetworkError(lastError)) {
          throw YtdlpException(_vpnFriendlyMessage(lastError));
        }
        // For pure auth without network hint, throw but with VPN tip if cookies were involved
        if (!_isVpnNetworkError(lastError) &&
            !_isCookieRelatedError(lastError)) {
          // still try cookie-stripped retry before giving up (below)
        }
      }
    }

    // ── Determine if we should retry without cookies / VPN fallback ──────
    // M6: only strip cookies for cookie/VPN-class errors. A simple
    // "video unavailable" must not double latency with a pointless retry.
    final shouldRetryWithoutCookies =
        lastError.isNotEmpty &&
        (_isVpnNetworkError(lastError) ||
            _isCookieRelatedError(lastError) ||
            lastError.toLowerCase().contains('timed out') ||
            lastError.contains('DPAPI') ||
            lastError.contains('Failed to decrypt') ||
            (isUsingCookies && _isVpnNetworkError(lastError)));

    // ── Attempt 2: without cookies (fixes LevelDB lock behind VPN, DPAPI) ─
    // M6: do NOT retry without cookies on every error just because cookies
    // are enabled — only for cookie/VPN-class failures.
    if (shouldRetryWithoutCookies) {
      if (remainingOverall().inSeconds < 5) {
        throw YtdlpException(
          _vpnFriendlyMessage(
            lastError.isEmpty ? 'Fetch timed out' : lastError,
          ),
        );
      }
      onProgress?.call(
        'Trying again without browser cookies...',
      );
      LoggingService().info(
        'Retrying getVideoInfo without cookies due to: $lastError',
        component: 'YtdlpService',
      );
      try {
        final noCookieArgs = _buildVideoInfoArgsWithoutCookies(url);
        result = await runTracked(
          noCookieArgs,
          'yt-dlp retry (no cookies) timed out (45 s). VPN may be slowing connection.',
        );
        if (result.exitCode == 0) {
          return await _parseAndCacheVideoInfo(
            result.stdout as String,
            cacheKey,
            onProgress,
          );
        }
        lastError = (result.stderr as String).trim();
        LoggingService().warning(
          'Attempt 2 (no cookies) failed: $lastError',
          component: 'YtdlpService',
        );
      } on YtdlpException catch (e) {
        if (e.message.contains('Cancelled')) rethrow;
        lastError = e.message;
      }
    }

    // ── Attempt 3: VPN fallback — force-ipv4 + android player client ─────
    if (lastError.isNotEmpty &&
        (_isVpnNetworkError(lastError) ||
            lastError.toLowerCase().contains('timed out'))) {
      if (remainingOverall().inSeconds < 5) {
        throw YtdlpException(_vpnFriendlyMessage(lastError));
      }
      onProgress?.call(
        'Trying different connection settings...',
      );
      LoggingService().info(
        'Retrying getVideoInfo with VPN fallback due to: $lastError',
        component: 'YtdlpService',
      );
      try {
        final vpnArgs = _buildVpnFallbackArgs(url);
        result = await runTracked(
          vpnArgs,
          'yt-dlp VPN fallback timed out (45 s). Try disabling VPN.',
        );
        if (result.exitCode == 0) {
          return await _parseAndCacheVideoInfo(
            result.stdout as String,
            cacheKey,
            onProgress,
          );
        }
        lastError = (result.stderr as String).trim();
      } on YtdlpException catch (e) {
        if (e.message.contains('Cancelled')) rethrow;
        lastError = e.message;
      }
    }

    // ── Final DPAPI fallback if not already tried and error matches ──────
    if (lastError.isNotEmpty &&
        (lastError.contains('DPAPI') ||
            lastError.contains('Failed to decrypt')) &&
        _cookieBrowser != null) {
      onProgress?.call('Trying again without browser cookies...');
      try {
        final argsWithoutBrowser = <String>[
          '--ignore-config',
          '--newline',
          '--no-playlist',
          '--skip-download',
          '--no-warnings',
          if (_ffmpegPath != null) ...['--ffmpeg-location', _ffmpegPath!],
          if (_cookiePath != null && File(_cookiePath!).existsSync()) ...[
            '--cookies',
            _cookiePath!,
          ],
          '--dump-single-json',
          _validateUrl(url),
        ];
        result = await runTracked(
          argsWithoutBrowser,
          'yt-dlp retry timed out (45 s).',
        );
        if (result.exitCode == 0) {
          return await _parseAndCacheVideoInfo(
            result.stdout as String,
            cacheKey,
            onProgress,
          );
        }
        final retryError = (result.stderr as String).trim();
        throw YtdlpException(
          'Failed to fetch video info: $retryError\n\nNote: Browser cookie extraction failed due to DPAPI. Try exporting cookies to a file or closing your browser.',
        );
      } on YtdlpException {
        rethrow;
      }
    }

    // ── All attempts exhausted ───────────────────────────────────────────
    final finalErr = lastError.isEmpty ? 'Unknown error' : lastError;
    if (_isVpnNetworkError(finalErr) ||
        finalErr.toLowerCase().contains('timed out')) {
      throw YtdlpException(
        _vpnFriendlyMessage('Failed to fetch video info: $finalErr'),
      );
    }
    final authErr = checkAuthenticationErrors(finalErr);
    if (authErr != null) throw YtdlpException(authErr);
    throw YtdlpException('Failed to fetch video info: $finalErr');
  }

  Future<VideoInfo> _parseAndCacheVideoInfo(
    String stdout,
    String cacheKey,
    Function(String status)? onProgress,
  ) async {
    onProgress?.call('Preparing available formats...');
    final info = await compute(_parseVideoInfoIsolate, stdout);
    _videoCache.put(cacheKey, info);
    // M5: do not spam a system notification for every routine metadata fetch.
    return info;
  }

  static String _validateUrl(String url) {
    try {
      return UrlValidator.validate(url);
    } on UrlValidationException catch (e) {
      throw YtdlpException(e.message);
    }
  }

  /// Builds yt-dlp args for a metadata dump.
  ///
  /// [fast]: lean flags for the happy path — short socket timeout, almost no
  /// in-process retries, no retry-sleep. A healthy network finishes in ~1–3s.
  /// Patient mode restores the VPN-friendly ladder used when the fast pass
  /// hits a timeout or network error.
  @visibleForTesting
  List<String> buildVideoInfoArgsForTest(String url, {bool fast = true}) =>
      _buildVideoInfoArgs(url, fast: fast);

  List<String> _buildVideoInfoArgs(String url, {bool fast = true}) {
    final args = <String>[
      '--ignore-config',
      '--newline',
      '--no-playlist',
      '--skip-download',
      '--no-check-formats',
      if (_extractorCachePath != null) ...['--cache-dir', _extractorCachePath!],
      if (_pluginDirPath != null) ...['--plugin-dirs', _pluginDirPath!],
      if (fast) ...[
        '--force-ipv4',
        '--retries',
        '1',
        '--extractor-retries',
        '1',
        '--socket-timeout',
        '8',
      ] else ...[
        '--retries',
        '4',
        '--extractor-retries',
        '3',
        '--socket-timeout',
        '30',
        '--retry-sleep',
        'linear=1:3',
      ],
      '--no-warnings',
      // Let yt-dlp choose its maintained clients for the current YouTube API.
      // Pinning android/web can succeed with only the 360p progressive stream.
      '--dump-single-json',
    ];

    if (_ffmpegPath != null && _ffmpegPath != 'ffmpeg') {
      args.addAll(['--ffmpeg-location', _ffmpegPath!]);
    }

    if (_userAgent != null && !_usesBrowserCookieSource) {
      args.addAll(['--user-agent', _userAgent!]);
    }

    if (_enableCookies) {
      if (_webViewPath != null) {
        args.addAll(['--cookies-from-browser', 'edge:$_webViewPath']);
      } else if (_cookiePath != null && File(_cookiePath!).existsSync()) {
        args.addAll(['--cookies', _cookiePath!]);
      } else if (_cookieBrowser != null && _cookieBrowser != 'none') {
        args.addAll(['--cookies-from-browser', _cookieBrowser!.toLowerCase()]);
      }
    }

    args.addAll(['--', _validateUrl(url)]);
    return args;
  }

  String _buildVideoInfoCacheKey(String url) {
    return [
      UrlValidator.normalizeVideoUrl(url),
      _enableCookies.toString(),
      _cookiePath ?? '',
      _cookieBrowser ?? '',
      _webViewPath ?? '',
      _userAgent ?? '',
    ].join('|');
  }

  /// Runs yt-dlp and guarantees the OS process is killed on timeout.
  ///
  /// Previous code used `Process.run(...).timeout(...)` which only throws
  /// a Dart exception but leaves the native `yt-dlp.exe` running orphaned,
  /// locking the cookie file and writing lingering `.part` files (B1).
  /// This helper uses `Process.start`, waits for `exitCode` with a timeout,
  /// and calls `process.kill()` on timeout before rethrowing as
  /// [YtdlpException]. VPN-friendly timeout message appended.
  // ignore: unused_element - kept for backwards compatibility / tests
  Future<ProcessResult> _runWithTimeout(
    List<String> args,
    Duration timeout, {
    String? timeoutMessage,
  }) async {
    return _runWithTimeoutTracked(
      args,
      timeout,
      timeoutMessage: timeoutMessage,
      myGen: null,
    );
  }

  Future<ProcessResult> _runWithTimeoutTracked(
    List<String> args,
    Duration timeout, {
    String? timeoutMessage,
    int? myGen,
  }) async {
    final process = await Process.start(_ytdlpPath, args);
    // Track for cancellation support
    if (myGen != null && myGen == _videoFetchGen) {
      _activeVideoProcess = process;
    }

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    final stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stdoutBuffer.write);
    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderrBuffer.write);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
          try {
            process.kill();
          } catch (_) {}
          throw TimeoutException(
            timeoutMessage ??
                'yt-dlp timed out after ${timeout.inSeconds}s. VPN may be slowing connection, try again or disable VPN.',
            timeout,
          );
        },
      );
    } on TimeoutException catch (e) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
      try {
        process.kill();
      } catch (_) {}
      try {
        await stdoutSub.cancel();
      } catch (_) {}
      try {
        await stderrSub.cancel();
      } catch (_) {}
      if (myGen != null && myGen == _videoFetchGen) _activeVideoProcess = null;
      final msg = e.message;
      if (msg != null && msg.isNotEmpty) {
        // Ensure VPN hint if not already present
        final enriched = msg.toLowerCase().contains('vpn')
            ? msg
            : '$msg\n\nTip: VPN may be slowing connection, try again or disable VPN.';
        throw YtdlpException(enriched);
      }
      throw YtdlpException(
        timeoutMessage ??
            'yt-dlp timed out after ${timeout.inSeconds}s. VPN may be slowing connection.',
      );
    }

    try {
      await Future.wait<void>([
        stdoutSub.asFuture<void>(),
        stderrSub.asFuture<void>(),
      ]).timeout(const Duration(milliseconds: 500), onTimeout: () => []);
    } catch (_) {}
    if (myGen != null && myGen == _videoFetchGen) _activeVideoProcess = null;

    return ProcessResult(
      process.pid,
      exitCode,
      stdoutBuffer.toString(),
      stderrBuffer.toString(),
    );
  }

  List<String> _buildPlaylistArgs(
    String url, {
    bool stripCookies = false,
    bool vpnFallback = false,
    String? playlistItems,
  }) {
    final base = <String>[
      '--ignore-config',
      '--newline',
      '--no-warnings',
      '--flat-playlist',
      '--retries',
      '3',
      '--extractor-retries',
      '3',
      '--socket-timeout',
      '15',
    ];
    if (_ffmpegPath != null && _ffmpegPath != 'ffmpeg') {
      base.addAll(['--ffmpeg-location', _ffmpegPath!]);
    }
    if (_userAgent != null) base.addAll(['--user-agent', _userAgent!]);
    if (vpnFallback) base.add('--force-ipv4');
    if (!stripCookies && _enableCookies) {
      if (_webViewPath != null) {
        base.addAll(['--cookies-from-browser', 'edge:$_webViewPath']);
      } else if (_cookiePath != null && File(_cookiePath!).existsSync()) {
        base.addAll(['--cookies', _cookiePath!]);
      } else if (_cookieBrowser != null && _cookieBrowser != 'none') {
        base.addAll(['--cookies-from-browser', _cookieBrowser!.toLowerCase()]);
      }
    }
    if (playlistItems != null && playlistItems.trim().isNotEmpty) {
      base.addAll(['--playlist-items', playlistItems.trim()]);
    }
    base.addAll([
      '--extractor-args',
      'youtubetab:skip=authcheck',
      '--dump-json',
      '--',
      _validateUrl(url),
    ]);
    return base;
  }

  /// Fetch playlist information from URL — VPN resilient
  @override
  Future<PlaylistInfo> getPlaylistInfo(
    String url, {
    String? playlistItems,
    Function(String status)? onProgress,
  }) async {
    if (!_isInitialized) await initialize();
    if (_extractorCachePath == null) await _ensureExtractorCacheAndPlugin();

    final cacheKey =
        '${_buildVideoInfoCacheKey(url)}|items=${playlistItems?.trim() ?? ''}';
    final cached = _playlistCache.get(cacheKey);
    if (cached != null) {
      onProgress?.call('Using cached playlist metadata...');
      return cached;
    }

    final existingInFlight = _playlistCache.getInFlight(cacheKey);
    if (existingInFlight != null) {
      onProgress?.call('Fetching playlist metadata...');
      return existingInFlight;
    }

    _playlistCancelRequested = false;
    onProgress?.call('Connecting...');

    Future<PlaylistInfo> runWithArgs(List<String> args) async {
      onProgress?.call('Fetching playlist metadata...');
      final process = await Process.start(_ytdlpPath, args).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw YtdlpException(
          'yt-dlp timed out starting playlist fetch (60 s). VPN may be slowing connection, try again or disable VPN.',
        ),
      );
      _activePlaylistProcess = process;
      final videos = <PlaylistVideoItem>[];
      Map<String, dynamic>? playlistMetadata;
      final stderrBuffer = StringBuffer();
      String? playlistTitle;
      int? expectedCount;

      final stdoutFuture = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isEmpty) return;
            try {
              final json = jsonDecode(line) as Map<String, dynamic>;
              if (json['_type'] == 'playlist') {
                playlistMetadata = json;
                playlistTitle = json['title'] as String?;
                expectedCount =
                    (json['playlist_count'] as int?) ??
                    (json['n_entries'] as int?);
                if (playlistTitle != null) {
                  onProgress?.call('Found playlist: $playlistTitle');
                }
              } else {
                final video = PlaylistVideoItem.fromJson(json);
                videos.add(video);
                final videoTitle = video.title.length > 40
                    ? '${video.title.substring(0, 40)}...'
                    : video.title;
                final countStr = expectedCount != null
                    ? '${videos.length}/$expectedCount'
                    : '${videos.length}';
                onProgress?.call('Loading video $countStr: $videoTitle');
              }
            } catch (e) {
              LoggingService().warning(
                'Failed to parse playlist JSON line: $e | line: ${line.length > 200 ? '${line.substring(0, 200)}...' : line}',
                component: 'YtdlpService',
              );
            }
          })
          .asFuture();

      final stderrFuture = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
            stderrBuffer.write(data);
          })
          .asFuture();

      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(
          const Duration(minutes: 6),
          onTimeout: () {
            try {
              process.kill(ProcessSignal.sigkill);
            } catch (_) {}
            throw YtdlpException(
              'Playlist fetch timed out (6 min). VPN may be slowing connection or playlist may be too large.',
            );
          },
        );
      } on YtdlpException {
        _activePlaylistProcess = null;
        rethrow;
      } catch (e) {
        _activePlaylistProcess = null;
        if (_playlistCancelRequested) {
          throw YtdlpCancelledException('Playlist fetch cancelled');
        }
        throw YtdlpException(_vpnFriendlyMessage(e.toString()));
      }
      try {
        await Future.wait<void>([
          stdoutFuture,
          stderrFuture,
        ]).timeout(const Duration(milliseconds: 500), onTimeout: () => []);
      } catch (_) {}
      _activePlaylistProcess = null;

      if (exitCode != 0) {
        // H29: a user cancel kills the process → non-zero exit. Report Cancelled
        // so providers can swallow it instead of showing a hard error.
        if (_playlistCancelRequested) {
          throw YtdlpCancelledException('Playlist fetch cancelled');
        }
        final error = stderrBuffer.toString().trim();
        final authError = checkAuthenticationErrors(error);
        if (authError != null) throw YtdlpException(authError);
        if (_isVpnNetworkError(error) ||
            _isCookieRelatedError(error) ||
            error.toLowerCase().contains('timed out')) {
          throw YtdlpException(
            _vpnFriendlyMessage('Failed to fetch playlist info: $error'),
          );
        }
        throw YtdlpException('Failed to fetch playlist info: $error');
      }

      if (videos.isEmpty) throw YtdlpException('No videos found in playlist');

      onProgress?.call('Processing ${videos.length} videos...');

      final info = PlaylistInfo(
        id: playlistMetadata?['id'] ?? '',
        title: playlistMetadata?['title'] ?? 'Playlist',
        uploader:
            playlistMetadata?['uploader'] ??
            playlistMetadata?['uploader_id'] ??
            'Unknown',
        description: playlistMetadata?['description'],
        videoCount: videos.length,
        videos: videos,
      );
      return info;
    }

    return _playlistCache.trackInFlight(cacheKey, () async {
      PlaylistInfo info;
      // Attempt 1: normal
      try {
        info = await runWithArgs(
          _buildPlaylistArgs(url, playlistItems: playlistItems),
        );
      } on YtdlpException catch (e) {
        final msg = e.message;
        final isVpn =
            _isVpnNetworkError(msg) || msg.toLowerCase().contains('timed out');
        final isCookie = _isCookieRelatedError(msg);
        if (isVpn || isCookie) {
          LoggingService().warning(
            'Playlist fetch failed ($msg), retrying without cookies/VPN fallback',
            component: 'YtdlpService',
          );
          onProgress?.call(
            'Retrying without browser cookies (VPN fallback)...',
          );
          try {
            info = await runWithArgs(
              _buildPlaylistArgs(
                url,
                stripCookies: true,
                playlistItems: playlistItems,
              ),
            );
          } catch (e2) {
            if (_isVpnNetworkError(e2.toString())) {
              onProgress?.call('Retrying with VPN-tolerant settings...');
              info = await runWithArgs(
                _buildPlaylistArgs(
                  url,
                  stripCookies: true,
                  vpnFallback: true,
                  playlistItems: playlistItems,
                ),
              );
            } else {
              rethrow;
            }
          }
        } else {
          rethrow;
        }
      }
      _playlistCache.put(cacheKey, info);
      return info;
    }());
  }

  /// yt-dlp `ytsearchN:query` flat-playlist search.
  /// Fallback when youtube_explode search fails (bot check / extractor break).
  /// Returns a map shaped like `{entries: [...], _type: playlist}`.
  @override
  Future<Map<String, dynamic>> searchVideosRaw(
    String query, {
    int limit = 10,
  }) async {
    if (!_isInitialized) await initialize();
    final n = limit.clamp(1, 25);
    final args = <String>[
      '--ignore-config',
      '--flat-playlist',
      '--no-warnings',
      '--socket-timeout',
      '15',
      '--retries',
      '5',
      '-J',
      '--',
      'ytsearch$n:$query',
    ];
    if (_enableCookies && _cookiePath != null && _cookiePath!.isNotEmpty) {
      args.insertAll(0, ['--cookies', _cookiePath!]);
    }
    if (_userAgent != null) {
      args.insertAll(0, ['--user-agent', _userAgent!]);
    }

    // H1: Process.run().timeout leaves the native yt-dlp running. Use
    // Process.start + exitCode.timeout + kill via _runWithTimeoutTracked.
    final result = await _runWithTimeoutTracked(
      args,
      const Duration(seconds: 60),
      timeoutMessage:
          'yt-dlp search timed out (60 s). VPN may be slowing connection.',
    );
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw YtdlpException('yt-dlp search failed: $err');
    }
    final out = (result.stdout as String).trim();
    if (out.isEmpty) {
      throw YtdlpException('yt-dlp search returned empty output');
    }
    return jsonDecode(out) as Map<String, dynamic>;
  }

  /// Download video with specified format
  Future<Process> downloadVideo({
    required String url,
    required String outputPath,
    String? formatId,
    String? audioFormatId,
    bool audioOnly = false,
    String? audioQuality, // '0' (best) to '9' (worst)
    int? targetHeight,
    bool embedThumbnail = true,
    bool embedMetadata = true,
    List<String>? subtitleLanguages,
    bool embedSubtitles = false,
    bool sponsorBlock = false,
    String? archivePath,
    String? mergeOutputFormat,
    Function(double progress, double speed, int eta)? onProgress,
  }) async {
    if (!_isInitialized) await initialize();

    final args = _buildCommonArgs(
      sponsorBlock: sponsorBlock,
      archivePath: archivePath,
    );
    args.addAll(['-o', outputPath]);

    // Embed flags work with a system-PATH ffmpeg too. Gating them on a
    // managed _ffmpegPath dropped thumbnail, metadata, and subtitle embed
    // whenever the user had not downloaded a private copy.
    if (embedThumbnail) args.add('--embed-thumbnail');
    if (embedMetadata) args.add('--embed-metadata');

    // Subtitles. One --sub-langs list: repeating --sub-lang keeps only the last.
    if (subtitleLanguages != null && subtitleLanguages.isNotEmpty) {
      args.add('--write-subs');
      args.add('--write-auto-subs');
      if (embedSubtitles) {
        args.add('--embed-subs');
      }
      final langs = subtitleLanguages
          .map((lang) => lang.trim())
          .where((lang) => lang.isNotEmpty)
          .join(',');
      if (langs.isNotEmpty) {
        args.addAll(['--sub-langs', langs]);
      }
    }

    // Always write thumbnail to disk for History UI optimization
    args.add('--write-thumbnail');

    if (audioOnly) {
      // Audio only mode
      if (audioFormatId != null) {
        // Only force format if it's not a generic 'best' selection
        // to avoid redundant transcoding.
        if (audioFormatId != 'bestaudio' && audioFormatId != 'best') {
          args.addAll(['-f', audioFormatId]);
        }
      }
      args.addAll([
        '-x', // Extract audio
        '--audio-format', 'mp3',
        '--audio-quality', audioQuality ?? '0', // Default to 0 (Best)
      ]);
    } else if (formatId != null && audioFormatId != null) {
      // Separate video and audio streams - strictly use selected formats
      args.addAll(['-f', '$formatId+$audioFormatId']);

      // H3: outputPath is an yt-dlp output TEMPLATE (`%(title)s [%(id)s].%(ext)s`),
      // so p.extension() returns `.%(ext)s` and never matches a real container.
      // Prefer an explicit mergeOutputFormat; otherwise default to mp4 (matches
      // the preferred format ladder: bestvideo[ext=mp4]+bestaudio[ext=m4a]).
      final container = _resolveMergeContainer(mergeOutputFormat, outputPath);
      if (container != null) {
        args.addAll(['--merge-output-format', container]);
      }
    } else if (formatId != null) {
      // Single format with fallback - skip if it's a live stream format (9x range)
      final isLikelyLiveFormat =
          int.tryParse(formatId) != null &&
          int.parse(formatId) >= 90 &&
          int.parse(formatId) <= 99;
      if (isLikelyLiveFormat) {
        // Use best quality instead of live stream format
        args.addAll([
          '-f',
          'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best',
        ]);
      } else {
        // Strictly use the specified single format
        args.addAll(['-f', formatId]);
      }
    } else if (targetHeight != null) {
      // User specified max resolution - apply height filter
      args.addAll([
        '-f',
        'bestvideo[height<=$targetHeight][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=$targetHeight]+bestaudio/best[height<=$targetHeight][ext=mp4]/best[height<=$targetHeight]',
      ]);
    } else {
      // Best quality default with comprehensive fallback chain
      args.addAll([
        '-f',
        'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best[ext=mp4]/best',
      ]);
    }

    args.addAll(['--', _validateUrl(url)]);

    final process = await Process.start(_ytdlpPath, args);
    return process;
  }

  static const Set<String> _allowedMergeContainers = {
    'mp4',
    'mkv',
    'ogg',
    'webm',
    'flv',
  };

  /// Resolve --merge-output-format for dual-stream downloads.
  /// Explicit container wins; a concrete (non-template) extension is used next;
  /// otherwise default to mp4 so the container matches the preferred ladder.
  static String? _resolveMergeContainer(String? explicit, String outputPath) {
    if (explicit != null &&
        explicit.isNotEmpty &&
        _allowedMergeContainers.contains(explicit.toLowerCase())) {
      return explicit.toLowerCase();
    }
    final ext = p.extension(outputPath).replaceAll('.', '').toLowerCase();
    if (ext.isNotEmpty &&
        !ext.contains('%(') &&
        _allowedMergeContainers.contains(ext)) {
      return ext;
    }
    // Template path (default desktop flow): yt-dlp would otherwise pick its
    // own default (often mkv). Force mp4 to match the mp4+m4a format ladder.
    return 'mp4';
  }

  /// Build common arguments for yt-dlp including cookies and ffmpeg location
  /// VPN-resilient: increased timeouts/retries, linear retry sleep
  List<String> _buildCommonArgs({
    bool sponsorBlock = false,
    String? archivePath,
  }) {
    final args = <String>[
      '--newline',
      '--no-playlist',
      if (_extractorCachePath != null) ...['--cache-dir', _extractorCachePath!],
      if (_pluginDirPath != null) ...['--plugin-dirs', _pluginDirPath!],
      // Titles with | : * ? " < > \ break NTFS writes. yt-dlp replaces them
      // with underscores when this flag is set (e.g. "Axiom | Module_7").
      '--windows-filenames',
      '--retries',
      '5',
      '--fragment-retries',
      '5',
      '--file-access-retries',
      '3',
      '--extractor-retries',
      '3',
      '--socket-timeout',
      '30',
      '--retry-sleep',
      'linear=1:3',
      '--concurrent-fragments',
      '16',
      '--buffer-size',
      '16K',
      '--http-chunk-size',
      '10M',
      '--no-warnings',
    ];

    if (_ffmpegPath != null && _ffmpegPath != 'ffmpeg') {
      args.addAll(['--ffmpeg-location', _ffmpegPath!]);
    }

    if (_userAgent != null && !_usesBrowserCookieSource) {
      args.addAll(['--user-agent', _userAgent!]);
    }

    // SponsorBlock
    if (sponsorBlock) {
      // A bare --sponsorblock-remove consumes the next flag
      // (--download-archive, --cookies, or -o) as its category.
      args.addAll(['--sponsorblock-remove', 'all']);
    }

    // Download archive
    if (archivePath != null && archivePath.isNotEmpty) {
      args.addAll(['--download-archive', archivePath]);
    }

    // Authentication logic: WebView profile > cookies file > browser cookies
    if (_enableCookies) {
      if (_webViewPath != null) {
        args.addAll(['--cookies-from-browser', 'edge:$_webViewPath']);
      } else if (_cookiePath != null) {
        final cookieFile = File(_cookiePath!);

        if (cookieFile.existsSync()) {
          // Using 'web' client with cookies - no need for extra extractor args
          args.addAll(['--cookies', _cookiePath!]);
        }
      } else if (_cookieBrowser != null && _cookieBrowser != 'none') {
        args.addAll(['--cookies-from-browser', _cookieBrowser!.toLowerCase()]);
      }
    }

    return args;
  }

  /// Check for authentication or permission errors in yt-dlp output
  static String? checkAuthenticationErrors(String output) {
    if (output.contains("Sign in to confirm you're not a bot") ||
        output.contains('Sign in to confirm your age') ||
        output.contains('This video is age-restricted') ||
        output.contains('Please sign in to view this video') ||
        output.contains('requires authentication')) {
      return 'Authentication required. Please provide a cookies.txt file or use browser cookies in Settings.';
    }

    if (output.contains('Permission denied') && output.contains('cookie')) {
      return 'Access to browser cookies denied. Please close all windows of specified browser and try again, or use a cookies.txt file.';
    }

    if (output.contains('Incomplete cookies file')) {
      return 'The selected cookies.txt file is incomplete or invalid. Please re-export it using the Netscape format.';
    }

    // Check for specific YouTube authentication errors
    if (output.toLowerCase().contains('authentication') &&
        (output.toLowerCase().contains('failed') ||
            output.toLowerCase().contains('required'))) {
      return 'Authentication failed. Please verify your cookies are valid and up-to-date.';
    }

    if (output.contains('HTTP Error 429') ||
        output.contains('Too Many Requests')) {
      return 'Rate limit exceeded (HTTP 429). Please wait a while before downloading more videos.';
    }

    return null;
  }

  static final RegExp _progressPercentRegex = RegExp(
    r'\[download\]\s+(\d+(?:\.\d+)?)%',
  );
  static final RegExp _progressSpeedRegex = RegExp(
    r'at\s+(\d+(?:\.\d+)?)\s*([KMG]?i?)B/s',
    caseSensitive: false,
  );
  static final RegExp _progressEtaRegex = RegExp(
    r'ETA\s+(?:(\d+):)?(\d+):(\d+)',
  );

  /// Parse progress from yt-dlp output line.
  /// [audioOnly] disambiguates `.webm` destinations (Opus audio vs VP9 video).
  static DownloadProgress? parseProgress(
    String line, {
    bool audioOnly = false,
  }) {
    final lowerLine = line.toLowerCase();

    if (line.contains('[download] Destination:')) {
      // M4: audio containers first. `.webm` is ambiguous — Opus audio and
      // VP9 video both use it — so honor [audioOnly] when present.
      if (audioOnly ||
          lowerLine.contains('.m4a') ||
          lowerLine.contains('.mp3') ||
          lowerLine.contains('.opus') ||
          lowerLine.contains('.aac') ||
          lowerLine.contains('.flac') ||
          lowerLine.contains('.wav') ||
          lowerLine.contains('.ogg') ||
          lowerLine.contains('.audio')) {
        return DownloadProgress(
          progress: 0,
          speed: 0,
          eta: 0,
          status: DownloadStatus.downloadingAudio,
        );
      }
      if (lowerLine.contains('.mp4') ||
          lowerLine.contains('.mkv') ||
          lowerLine.contains('.webm')) {
        return DownloadProgress(
          progress: 0,
          speed: 0,
          eta: 0,
          status: DownloadStatus.downloadingVideo,
        );
      }
    }

    if (line.contains('[download] 100%') ||
        line.contains('has already been downloaded')) {
      return DownloadProgress(progress: 1.0, eta: 0);
    }

    final progressMatch = _progressPercentRegex.firstMatch(line);

    if (progressMatch == null) {
      if (lowerLine.contains('[merger]') ||
          lowerLine.contains('[ffmpeg]') ||
          lowerLine.contains('[extractaudio]') ||
          lowerLine.contains('[metadata]') ||
          lowerLine.contains('[embedthumbnail]') ||
          lowerLine.contains('merging formats into') ||
          lowerLine.contains('deleting original file')) {
        return DownloadProgress(
          progress: 0.97,
          speed: 0,
          eta: 0,
          status: DownloadStatus.merging,
        );
      }

      return null;
    }

    final percent = double.parse(progressMatch.group(1)!) / 100;
    final speedMatch = _progressSpeedRegex.firstMatch(line);
    final etaMatch = _progressEtaRegex.firstMatch(line);

    double? speed;
    if (speedMatch != null) {
      final parsedSpeed = double.parse(speedMatch.group(1)!);
      final unit = (speedMatch.group(2) ?? '').toLowerCase();
      speed =
          parsedSpeed *
          switch (unit) {
            'k' || 'ki' => 1024,
            'm' || 'mi' => 1024 * 1024,
            'g' || 'gi' => 1024 * 1024 * 1024,
            _ => 1,
          };
    }

    int? eta;
    if (etaMatch != null) {
      final hours = int.tryParse(etaMatch.group(1) ?? '0') ?? 0;
      final minutes = int.tryParse(etaMatch.group(2) ?? '0') ?? 0;
      final seconds = int.tryParse(etaMatch.group(3) ?? '0') ?? 0;
      eta = hours * 3600 + minutes * 60 + seconds;
    }

    return DownloadProgress(
      progress: percent.clamp(0.0, 1.0),
      speed: speed,
      eta: eta,
    );
  }

  static String formatDownloadError(String output, int exitCode) {
    return ErrorHelper.formatDownloadError(output, exitCode);
  }

  /// Get best format for a specific resolution
  static String? getBestFormatForResolution(
    VideoInfo video,
    int targetHeight, {
    bool videoOnly = false,
  }) {
    final formats = videoOnly ? video.videoOnlyFormats : video.formats;

    // Find formats matching or closest to target height
    final matchingFormats = formats
        .where((f) => f.hasVideo && f.height != null)
        .toList();

    if (matchingFormats.isEmpty) return null;

    // Sort by how close they are to target, preferring higher quality
    matchingFormats.sort((a, b) {
      final diffA = (a.height! - targetHeight).abs();
      final diffB = (b.height! - targetHeight).abs();
      if (diffA != diffB) return diffA.compareTo(diffB);
      return (b.height ?? 0).compareTo(a.height ?? 0);
    });

    return matchingFormats.first.formatId;
  }

  /// Get best audio format
  static String? getBestAudioFormat(VideoInfo video) {
    final audioFormats = video.audioOnlyFormats;
    if (audioFormats.isEmpty) return null;
    return audioFormats.first.formatId;
  }

  /// Test authentication with a simple YouTube video to verify cookies are working
  Future<bool> testAuthentication() async {
    try {
      // Use a simple, non-age-restricted video for testing
      final testVideoUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

      // Try to fetch video info - this will fail if authentication is not working
      await getVideoInfo(testVideoUrl);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check for updates and return update info with download URL
  /// Returns null ONLY if yt-dlp is not available or version check failed
  /// Returns YtdlpUpdateInfo with same current/latest version when up to date
  @override
  Future<YtdlpUpdateInfo?> checkForUpdateWithProgress() async {
    final logger = LoggingService();
    logger.info('Checking for yt-dlp updates...', component: 'YtdlpService');

    try {
      final currentVersion = await getVersion();
      if (currentVersion == null) {
        logger.warning(
          'Cannot check for updates: yt-dlp not available',
          component: 'YtdlpService',
        );
        return null;
      }

      final latestVersion = await getLatestVersion();
      if (latestVersion == null) {
        logger.warning(
          'Cannot check for updates: failed to fetch latest version',
          component: 'YtdlpService',
        );
        // Still return info with current version so UI knows yt-dlp is installed
        return YtdlpUpdateInfo(
          currentVersion: currentVersion,
          latestVersion: currentVersion, // Same as current means up to date
          downloadUrl: _windowsDownloadUrl,
          publishedAt: DateTime.now(),
          releaseNotes: 'Up to date',
        );
      }

      final hasUpdate = isNewerVersion(currentVersion, latestVersion);

      logger.info(
        'Update check complete: current=$currentVersion, latest=$latestVersion, updateAvailable=$hasUpdate',
        component: 'YtdlpService',
      );

      // Always return info - this lets the caller know yt-dlp is available
      return YtdlpUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        downloadUrl: _windowsDownloadUrl,
        publishedAt: DateTime.now(),
        releaseNotes: hasUpdate
            ? 'New version available: $latestVersion'
            : 'Up to date',
      );
    } catch (e, stackTrace) {
      // Propagate rate-limit so UI can show specific message instead of silent "Not found"
      if (e.toString().toLowerCase().contains('rate limit') ||
          e.toString().contains('403') ||
          e.toString().contains('429')) {
        logger.warning(
          'Rate limited while checking yt-dlp updates: $e',
          component: 'YtdlpService',
        );
        rethrow;
      }
      logger.error(
        'Failed to check for yt-dlp updates',
        component: 'YtdlpService',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Download and install update with progress callback.
  /// The download runs in a background isolate for full network throughput.
  @override
  Future<bool> downloadAndInstallUpdate(
    String downloadUrl, {
    required Function(double progress) onProgress,
    required Function(String status) onStatus,
    bool Function()? isCancelled,
  }) async {
    final logger = LoggingService();
    File? tempFile;
    Directory? tempDir;

    try {
      // Ensure managed path is resolved before we decide where to install
      await initialize();
      onStatus('Downloading latest yt-dlp...');
      logger.info(
        'Starting yt-dlp update download (background isolate) -> $downloadUrl',
        component: 'YtdlpService',
      );

      // Private temp directory with a random suffix (O_EXCL semantics) to
      // avoid predicted-name symlink/hijack races in the shared temp dir (M11).
      tempDir = await Directory.systemTemp.createTemp('yt-dlp-update-');
      tempFile = File(p.join(tempDir.path, 'yt-dlp.exe'));

      // Download via multi-connection curl (8 parallel connections)
      await downloadInBackground(
        url: downloadUrl,
        destPath: tempFile.path,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      logger.info('yt-dlp download complete', component: 'YtdlpService');
      final downloadedSize = await tempFile.length();
      if (downloadedSize < 1024 * 1024) {
        // Read first bytes to diagnose HTML error page vs binary
        String snippet = '';
        try {
          final head = await tempFile
              .openRead(0, 500)
              .transform(utf8.decoder)
              .join();
          snippet = head.substring(0, head.length > 200 ? 200 : head.length);
        } catch (_) {}
        throw Exception(
          'Downloaded file too small ($downloadedSize bytes), likely not a valid binary. Snippet: $snippet',
        );
      }

      if (isCancelled?.call() == true) {
        onStatus('Update cancelled');
        return false;
      }

      onStatus('Installing update...');
      logger.info(
        'Download complete, installing update to $_ytdlpPath',
        component: 'YtdlpService',
      );

      // Backup current binary
      final currentFile = File(_ytdlpPath);
      final backupPath = '$_ytdlpPath.backup';

      if (await currentFile.exists()) {
        try {
          await currentFile.copy(backupPath);
        } catch (e) {
          logger.warning(
            'Backup copy failed (may be locked): $e',
            component: 'YtdlpService',
          );
        }
      }

      try {
        // On Windows the exe may be locked if a download is in progress – retry deletion
        for (int i = 0; i < 3; i++) {
          try {
            if (await currentFile.exists()) await currentFile.delete();
            break;
          } catch (e) {
            if (i == 2) rethrow;
            await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
          }
        }
        await tempFile.copy(_ytdlpPath);
        // Clear version cache so next getVersion reads new binary
        _cachedVersion = null;
        logger.info('Update installed successfully', component: 'YtdlpService');

        final backupFile = File(backupPath);
        if (await backupFile.exists()) await backupFile.delete();

        onStatus('Update complete!');
        return true;
      } catch (e) {
        logger.error(
          'Failed to install update, restoring backup',
          component: 'YtdlpService',
          error: e,
        );
        final backupFile = File(backupPath);
        if (await backupFile.exists()) {
          try {
            if (await currentFile.exists()) await currentFile.delete();
          } catch (_) {}
          await backupFile.copy(_ytdlpPath);
          try {
            await backupFile.delete();
          } catch (_) {}
        }
        throw Exception('Failed to install update: $e');
      }
    } catch (e, stackTrace) {
      if (e.toString().contains('Cancelled')) {
        onStatus('Update cancelled');
        return false;
      }
      logger.error(
        'Update download/install failed',
        component: 'YtdlpService',
        error: e,
        stackTrace: stackTrace,
      );
      onStatus('Update failed: $e');
      return false;
    } finally {
      if (tempDir != null && tempDir.existsSync()) {
        try {
          // Recursively delete the private temp directory (binary + anything
          // written alongside it).
          await tempDir.delete(recursive: true);
        } catch (e) {
          LoggingService().debug(
            'Failed to delete temp update file: $e',
            component: 'YtdlpService',
          );
        }
      }
    }
  }
}

class DownloadProgress {
  final double progress;
  final double? speed;
  final int? eta;
  final DownloadStatus? status;

  DownloadProgress({required this.progress, this.speed, this.eta, this.status});
}

class YtdlpException implements Exception {
  final String message;
  YtdlpException(this.message);

  @override
  String toString() => 'YtdlpException: $message';
}

/// Thrown when the user explicitly cancelled a fetch (vs a real failure).
class YtdlpCancelledException extends YtdlpException {
  YtdlpCancelledException(super.message);

  @override
  String toString() => 'YtdlpCancelledException: $message';
}
