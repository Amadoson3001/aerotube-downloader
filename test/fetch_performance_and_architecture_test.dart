import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_downloader/core/utils/error_helper.dart';
import 'package:youtube_downloader/models/download_item.dart';
import 'package:youtube_downloader/models/playlist_info.dart';
import 'package:youtube_downloader/models/search_video_result.dart';
import 'package:youtube_downloader/models/video_info.dart';
import 'package:youtube_downloader/providers/video_provider.dart';
import 'package:youtube_downloader/services/core/fast_youtube_metadata_service.dart';
import 'package:youtube_downloader/services/ytdlp/video_info_cache.dart';
import 'package:youtube_downloader/services/ytdlp/ytdlp_service_windows.dart';
import 'package:youtube_downloader/services/ytdlp/ytdlp_tool_service.dart';

class _FakeYtdlpToolService implements YtdlpToolService {
  final Completer<VideoInfo> videoCompleter = Completer<VideoInfo>();
  bool cached = false;
  bool cancelled = false;

  @override
  String ytdlpPath = 'yt-dlp';
  @override
  String? cookiePath;
  @override
  String? cookieBrowser;
  @override
  String? webViewPath;
  @override
  String? ffmpegPath;
  @override
  String? userAgent;
  @override
  bool enableCookies = false;

  @override
  Future<void> initialize({bool force = false}) async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> getVersion() async => '2026.01.01';

  @override
  void markReady(String version) {}

  @override
  Future<String?> getLatestVersion({bool forceRefresh = false}) async =>
      '2026.01.01';

  @override
  Future<YtdlpUpdateInfo?> checkForUpdateWithProgress() async => null;

  @override
  Future<bool> downloadAndInstallUpdate(
    String downloadUrl, {
    required Function(double progress) onProgress,
    required Function(String status) onStatus,
    bool Function()? isCancelled,
  }) async => true;

  @override
  Future<bool> update() async => true;

  @override
  Future<void> cancelFetch() async {
    cancelled = true;
  }

  @override
  bool hasCachedVideoInfo(String url) => cached;

  @override
  Future<VideoInfo> getVideoInfo(
    String url, {
    Function(String status)? onProgress,
  }) => videoCompleter.future;

  @override
  Future<PlaylistInfo> getPlaylistInfo(
    String url, {
    String? playlistItems,
    Function(String status)? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> searchVideosRaw(
    String query, {
    int limit = 10,
  }) => throw UnimplementedError();
}

void main() {
  group('MetadataCache', () {
    test('stores, retrieves, and evicts LRU entries', () {
      final cache = MetadataCache<int>(
        ttl: const Duration(minutes: 5),
        maxEntries: 2,
      );

      expect(cache.get('a'), isNull);
      expect(cache.hasValid('a'), isFalse);

      cache.put('a', 1);
      cache.put('b', 2);
      expect(cache.get('a'), 1); // refreshes 'a' so 'b' is LRU
      cache.put('c', 3); // should evict 'b'

      expect(cache.hasValid('a'), isTrue);
      expect(cache.hasValid('b'), isFalse);
      expect(cache.get('c'), 3);
    });

    test('expires entries after TTL', () async {
      final cache = MetadataCache<String>(
        ttl: const Duration(milliseconds: 10),
        maxEntries: 5,
      );
      cache.put('k', 'v');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(cache.hasValid('k'), isFalse);
      expect(cache.get('k'), isNull);
    });

    test('deduplicates and clears in-flight futures', () async {
      final cache = MetadataCache<String>();
      final completer = Completer<String>();
      final tracked = cache.trackInFlight('url', completer.future);
      expect(identical(cache.getInFlight('url'), tracked), isTrue);

      cache.clearInFlight();
      expect(cache.getInFlight('url'), isNull);

      completer.complete('ok');
      expect(await tracked, 'ok');
    });
  });

  group('ErrorHelper VPN/network helpers', () {
    test('isVpnOrNetworkError detects network and timeout errors', () {
      expect(ErrorHelper.isVpnOrNetworkError('Connection timed out'), isTrue);
      expect(
        ErrorHelper.isVpnOrNetworkError('Temporary failure in name resolution'),
        isTrue,
      );
      expect(ErrorHelper.isVpnOrNetworkError('SocketException: reset'), isTrue);
      expect(ErrorHelper.isVpnOrNetworkError('Private video'), isFalse);
    });

    test('enrichVpnTimeoutMessage avoids duplicate VPN hint', () {
      expect(
        ErrorHelper.enrichVpnTimeoutMessage('Request timed out'),
        contains('VPN may be slowing connection'),
      );
      const alreadyHasVpn = 'Timed out behind VPN';
      expect(ErrorHelper.enrichVpnTimeoutMessage(alreadyHasVpn), alreadyHasVpn);
    });
  });

  group('YtdlpService args & progress parsing', () {
    test('buildVideoInfoArgsForTest sets fast vs patient flags', () {
      final service = YtdlpService();
      final fastArgs = service.buildVideoInfoArgsForTest(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        fast: true,
      );
      expect(fastArgs, contains('--no-check-formats'));
      expect(fastArgs, contains('--force-ipv4'));
      expect(fastArgs, containsAllInOrder(['--socket-timeout', '8']));

      final patientArgs = service.buildVideoInfoArgsForTest(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        fast: false,
      );
      expect(patientArgs, contains('--no-check-formats'));
      expect(patientArgs, isNot(contains('--force-ipv4')));
      expect(patientArgs, containsAllInOrder(['--socket-timeout', '30']));
    });

    test('parseProgress parses percent, speed, ETA, and merging', () {
      final dl = YtdlpService.parseProgress(
        '[download]  45.5% of 100.00MiB at  5.25MiB/s ETA 00:12',
      );
      expect(dl, isNotNull);
      expect(dl!.progress, closeTo(0.455, 0.001));
      expect(dl.speed, closeTo(5.25 * 1024 * 1024, 100));
      expect(dl.eta, 12);

      final merging = YtdlpService.parseProgress('[Merger] Merging formats');
      expect(merging, isNotNull);
      expect(merging!.status, DownloadStatus.merging);
    });
  });

  group('VideoInfo.fromJson', () {
    test('deduplicates subtitles so official overrides auto', () {
      final info = VideoInfo.fromJson({
        'id': 'abc123',
        'title': 'Test Video',
        'channel': 'Channel',
        'duration': 120,
        'formats': [
          {
            'format_id': '137',
            'ext': 'mp4',
            'height': 1080,
            'vcodec': 'avc1',
            'acodec': 'none',
          },
          {
            'format_id': '140',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a',
            'abr': 128,
          },
        ],
        'subtitles': {
          'en': [
            {'name': 'English', 'ext': 'vtt'},
          ],
        },
        'automatic_captions': {
          'en': [
            {'name': 'English', 'ext': 'vtt'},
          ],
          'es': [
            {'name': 'Spanish', 'ext': 'vtt'},
          ],
        },
      });

      expect(info.formats.length, 2);
      expect(info.subtitles.length, 2);
      final enSub = info.subtitles.firstWhere((s) => s.languageCode == 'en');
      expect(enSub.isAutoGenerated, isFalse);
      final esSub = info.subtitles.firstWhere((s) => s.languageCode == 'es');
      expect(esSub.isAutoGenerated, isTrue);
    });
  });

  group('VideoProvider parallel fast preview', () {
    test('shows fast preview immediately then upgrades to full formats', () async {
      final ytdlp = _FakeYtdlpToolService();
      final previewService = FastYouTubeMetadataService(
        fetcherOverride: (videoId) async => SearchVideoResult(
          id: videoId,
          title: 'Instant Title',
          author: 'Fast Author',
          thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          duration: const Duration(seconds: 90),
        ),
      );
      final provider = VideoProvider(
        ytdlp,
        fastMetadataService: previewService,
      );

      final fetchFuture = provider.fetchVideoInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );

      // Allow the fast preview microtask/future to resolve while yt-dlp is pending.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.hasVideo, isTrue);
      expect(provider.videoInfo!.title, 'Instant Title');
      expect(provider.isPreviewOnly, isTrue);
      expect(provider.canDownload, isFalse);

      // Now complete yt-dlp with real formats.
      ytdlp.videoCompleter.complete(
        VideoInfo(
          id: 'dQw4w9WgXcQ',
          title: 'Full Title',
          channel: 'Full Author',
          channelUrl: '',
          thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
          duration: 90,
          description: '',
          viewCount: 1000,
          uploadDate: '20260101',
          formats: [
            FormatInfo(
              formatId: '137',
              extension: 'mp4',
              height: 1080,
              videoCodec: 'avc1',
              hasAudio: false,
              hasVideo: true,
            ),
            FormatInfo(
              formatId: '140',
              extension: 'm4a',
              audioCodec: 'mp4a',
              audioBitrate: 128,
              hasAudio: true,
              hasVideo: false,
            ),
          ],
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          subtitles: const [],
        ),
      );

      await fetchFuture;
      expect(provider.isPreviewOnly, isFalse);
      expect(provider.canDownload, isTrue);
      expect(provider.videoInfo!.title, 'Full Title');
      expect(provider.availableResolutions, isNotEmpty);

      provider.dispose();
    });

    test('cancellation discards late preview and yt-dlp results', () async {
      final ytdlp = _FakeYtdlpToolService();
      final previewCompleter = Completer<SearchVideoResult?>();
      final previewService = FastYouTubeMetadataService(
        fetcherOverride: (_) => previewCompleter.future,
      );
      final provider = VideoProvider(
        ytdlp,
        fastMetadataService: previewService,
      );

      final fetchFuture = provider.fetchVideoInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      await provider.cancelFetch();
      expect(ytdlp.cancelled, isTrue);

      previewCompleter.complete(
        SearchVideoResult(
          id: 'dQw4w9WgXcQ',
          title: 'Late Preview',
          author: 'Author',
          thumbnailUrl: '',
        ),
      );
      ytdlp.videoCompleter.complete(
        VideoInfo(
          id: 'dQw4w9WgXcQ',
          title: 'Late Full',
          channel: 'Author',
          channelUrl: '',
          thumbnailUrl: '',
          duration: 10,
          description: '',
          viewCount: 0,
          uploadDate: '',
          formats: const [],
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          subtitles: const [],
        ),
      );

      await fetchFuture;
      expect(provider.hasVideo, isFalse);
      expect(provider.isLoading, isFalse);

      provider.dispose();
    });
  });
}
