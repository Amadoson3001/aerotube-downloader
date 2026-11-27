import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/url_validator.dart';
import '../../models/search_video_result.dart';
import '../ytdlp/video_info_cache.dart';

typedef FastPreviewFetcher = Future<SearchVideoResult?> Function(String videoId);

/// Fetches lightweight YouTube video metadata via [YoutubeExplode] so the UI
/// can render title/thumbnail/channel/duration in <1s while yt-dlp resolves the
/// full adaptive format ladder in parallel.
class FastYouTubeMetadataService {
  final YoutubeExplode? _ownedYt;
  final FastPreviewFetcher? _fetcherOverride;
  final MetadataCache<SearchVideoResult> _cache =
      MetadataCache<SearchVideoResult>(
        ttl: const Duration(minutes: 10),
        maxEntries: 30,
      );

  FastYouTubeMetadataService({
    YoutubeExplode? youtubeExplode,
    FastPreviewFetcher? fetcherOverride,
  }) : _ownedYt = fetcherOverride == null
           ? (youtubeExplode ?? YoutubeExplode())
           : null,
       _fetcherOverride = fetcherOverride;

  Future<SearchVideoResult?> fetchPreview(
    String url, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final videoId = UrlValidator.extractYouTubeVideoId(url);
    if (videoId == null || videoId.isEmpty) return null;

    final cached = _cache.get(videoId);
    if (cached != null) return cached;

    final inFlight = _cache.getInFlight(videoId);
    if (inFlight != null) {
      try {
        return await inFlight;
      } catch (_) {
        return null;
      }
    }

    final future = _fetchUncached(videoId, timeout);
    try {
      return await _cache.trackInFlight(videoId, future);
    } catch (_) {
      return null;
    }
  }

  Future<SearchVideoResult> _fetchUncached(
    String videoId,
    Duration timeout,
  ) async {
    final result = await (_fetcherOverride != null
            ? _fetcherOverride(videoId)
            : _fetchFromExplode(videoId))
        .timeout(timeout);
    if (result == null) {
      throw StateError('No fast preview available for $videoId');
    }
    _cache.put(videoId, result);
    return result;
  }

  Future<SearchVideoResult?> _fetchFromExplode(String videoId) async {
    final video = await _ownedYt!.videos.get(videoId);
    return SearchVideoResult(
      id: video.id.value,
      title: video.title,
      author: video.author,
      thumbnailUrl: video.thumbnails.highResUrl,
      duration: video.duration,
      viewCount: video.engagement.viewCount,
      uploadDate: video.uploadDate?.toString(),
    );
  }

  void dispose() {
    _ownedYt?.close();
  }
}
