import '../core/logging_service.dart';
import '../ytdlp/native_ytdlp_android.dart';
import 'ffmpeg_tool_service.dart';

/// Android-specific FFmpeg service.
///
/// FFmpeg is bundled inside the youtubedl-android library and is used
/// automatically by yt-dlp for merging (e.g. bestvideo+bestaudio). This
/// service does not shell out to a separate FFmpeg binary and does not
/// expose merge/convert APIs — those operations are yt-dlp's job.
class FfmpegServiceAndroid implements FfmpegToolService {
  bool _isInitialized = false;
  String? _ffmpegVersion;
  final LoggingService _logger = LoggingService();

  /// Initialize FFmpeg.
  ///
  /// The native availability probe returns a label after verifying the
  /// bundled payload.
  @override
  Future<void> initialize({bool force = false}) async {
    if (_isInitialized && !force) return;

    try {
      _ffmpegVersion = await NativeYtdlpAndroid.getFfmpegVersion();
      _isInitialized = _ffmpegVersion != null;

      if (_ffmpegVersion != null) {
        _logger.info(
          'FFmpeg initialized (bundled with youtubedl-android): $_ffmpegVersion',
          component: 'FfmpegServiceAndroid',
        );
      } else {
        _logger.warning(
          'Bundled FFmpeg is unavailable',
          component: 'FfmpegServiceAndroid',
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to initialize FFmpeg',
        component: 'FfmpegServiceAndroid',
        error: e,
        stackTrace: stackTrace,
      );
      throw FfmpegAndroidException('Failed to initialize FFmpeg: $e');
    }
  }

  /// Real FFmpeg version from native, or null. Never a fake string.
  ///
  /// Native may return a bundled-library label such as "bundled-0.18.1"
  /// rather than an upstream ffmpeg version. Display it as-is; never parse
  /// it as a semantic ffmpeg version for update checks (checkForUpdate is
  /// intentionally a no-op on Android).
  String? get version => _ffmpegVersion;
  @override
  Future<String?> getVersion() async => _ffmpegVersion;

  @override
  String? get ffmpegPath => null;
  @override
  set ffmpegPath(String? _) {}

  /// True when the native probe has confirmed the bundled payload.
  @override
  bool get isAvailable => _isInitialized;

  /// Check for FFmpeg updates.
  /// Bundled with youtubedl-android; there is no separate FFmpeg to update.
  @override
  Future<FfmpegUpdateInfo?> checkForUpdate() async {
    return null;
  }

  /// Update FFmpeg.
  /// Bundled with youtubedl-android; returns false because no independent
  /// update path exists.
  @override
  Future<bool> update({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
    bool Function()? isCancelled,
  }) async {
    _logger.info(
      'FFmpeg is bundled with youtubedl-android; no independent update path',
      component: 'FfmpegServiceAndroid',
    );
    return false;
  }

  /// Download and install FFmpeg.
  /// Bundled with youtubedl-android; returns false because no independent
  /// install path exists.
  @override
  Future<bool> downloadAndInstall({
    required Function(double progress) onProgress,
    required Function(String status) onStatus,
    bool Function()? isCancelled,
  }) async {
    _logger.info(
      'FFmpeg is bundled with youtubedl-android; no independent install path',
      component: 'FfmpegServiceAndroid',
    );
    return false;
  }
}

class FfmpegAndroidException implements Exception {
  final String message;
  FfmpegAndroidException(this.message);
  @override
  String toString() => 'FfmpegAndroidException: $message';
}
