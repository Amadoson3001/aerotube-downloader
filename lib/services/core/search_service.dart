import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    hide SearchResult;
import '../../models/search_video_result.dart';
import 'logging_service.dart';

/// Optional yt-dlp `ytsearchN:` fallback used when youtube_explode fails.
typedef YtdlpSearchFallback = Future<List<SearchVideoResult>> Function(
  String query, {
  int limit,
});

/// Optional custom search executor for testing.
typedef ExplodeSearchFn = Future<VideoSearchList> Function(String query);

class SearchService {
  final YoutubeExplode? _ownedYt;
  final ExplodeSearchFn? _explodeSearchOverride;
  final LoggingService _logger = LoggingService();
  VideoSearchList? _currentSearchPage;
  String? _currentSearchQuery;
  int _requestToken = 0;

  /// Injected by SearchProvider when a platform yt-dlp service is available.
  final YtdlpSearchFallback? ytdlpFallback;
  SearchService({
    this.ytdlpFallback,
    YoutubeExplode? youtubeExplode,
    ExplodeSearchFn? explodeSearchOverride,
  }) : _ownedYt = explodeSearchOverride == null
           ? (youtubeExplode ?? YoutubeExplode())
           : null,
       _explodeSearchOverride = explodeSearchOverride;

  YoutubeExplode get _yt => _ownedYt!;

  // Simple in-memory cache for VPN / repeated queries
  final Map<String, List<SearchVideoResult>> _cache = {};
  final Map<String, VideoSearchList> _pageCache = {};
  final Map<String, DateTime> _cacheTime = {};
  static const Duration _cacheExpiry = Duration(minutes: 5);
  static const int _maxCacheEntries = 30;

  /// Default single overall deadline for a search request (explode + fallback).
  static const Duration defaultOverallBudget = Duration(seconds: 16);

  bool _isTransientNetworkError(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('timeout') ||
        m.contains('timed out') ||
        m.contains('socket') ||
        m.contains('connection') ||
        m.contains('network is unreachable') ||
        m.contains('failed host lookup');
  }

  void resetPagination() {
    _requestToken++;
    _currentSearchPage = null;
    _currentSearchQuery = null;
  }

  void _storeCache(
    String key,
    List<SearchVideoResult> results, {
    VideoSearchList? page,
  }) {
    if (_cache.length >= _maxCacheEntries && !_cache.containsKey(key)) {
      final oldest = _cacheTime.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;
      _cache.remove(oldest);
      _pageCache.remove(oldest);
      _cacheTime.remove(oldest);
    }
    _cache[key] = results;
    if (page != null) {
      _pageCache[key] = page;
    } else {
      _pageCache.remove(key);
    }
    _cacheTime[key] = DateTime.now();
  }

  Future<List<SearchVideoResult>> searchVideos(
    String query, {
    Duration overallBudget = defaultOverallBudget,
    bool Function()? isCancelled,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final myToken = ++_requestToken;
    bool cancelled() => (isCancelled?.call() ?? false) || myToken != _requestToken;

    // Cache hit — also restore cached VideoSearchList so pagination works.
    final cached = _cache[trimmed];
    if (cached != null) {
      final t = _cacheTime[trimmed];
      if (t != null && DateTime.now().difference(t) < _cacheExpiry) {
        _logger.debug('Search cache hit for "$trimmed"', component: 'SearchService');
        _currentSearchQuery = trimmed;
        _currentSearchPage = _pageCache[trimmed];
        return List<SearchVideoResult>.from(cached);
      } else {
        _cache.remove(trimmed);
        _pageCache.remove(trimmed);
        _cacheTime.remove(trimmed);
      }
    }

    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final r = overallBudget - stopwatch.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    // Bounded attempts within the single overall deadline.
    // Reserve ~6s for yt-dlp fallback when available so explode retries
    // never starve the fallback.
    const maxExplodeAttempts = 2;
    final explodeCeiling = ytdlpFallback != null
        ? Duration(
            milliseconds: (overallBudget.inMilliseconds * 0.55).round(),
          )
        : overallBudget;
    Object? lastError;
    StackTrace? lastStack;

    for (int attempt = 1; attempt <= maxExplodeAttempts; attempt++) {
      if (cancelled()) return [];
      final remExplode = explodeCeiling - stopwatch.elapsed;
      final remTotal = remaining();
      final budgetLeft = remExplode < remTotal ? remExplode : remTotal;
      if (budgetLeft <= const Duration(milliseconds: 500)) break;

      final attemptTimeout = budgetLeft < const Duration(seconds: 5)
          ? budgetLeft
          : const Duration(seconds: 5);

      try {
        _logger.info(
          'Searching videos for: $trimmed (attempt $attempt/$maxExplodeAttempts, budget=${attemptTimeout.inMilliseconds}ms)',
          component: 'SearchService',
        );
        final searchFuture = _explodeSearchOverride != null
            ? _explodeSearchOverride(trimmed)
            : _yt.search.search(trimmed);
        final searchList = await searchFuture.timeout(attemptTimeout);
        if (cancelled()) return [];

        if (searchList.isEmpty) {
          _logger.warning('No results found for query: $trimmed', component: 'SearchService');
          _currentSearchQuery = trimmed;
          _currentSearchPage = null;
          // Empty from explode could be bot-blocking; allow fallback below.
          break;
        }

        _currentSearchQuery = trimmed;
        _currentSearchPage = searchList;
        final mapped = _mapVideos(searchList);
        _storeCache(trimmed, mapped, page: searchList);
        return mapped;
      } on TimeoutException catch (e, stack) {
        lastError = e;
        lastStack = stack;
        _logger.warning(
          'Search timeout for "$trimmed" attempt $attempt/$maxExplodeAttempts: $e',
          component: 'SearchService',
        );
        if (attempt < maxExplodeAttempts && !cancelled()) {
          final backoff = Duration(milliseconds: 250 * attempt);
          if (explodeCeiling - stopwatch.elapsed > backoff) {
            await Future.delayed(backoff);
            continue;
          }
        }
      } catch (e, stack) {
        lastError = e;
        lastStack = stack;
        if (_isTransientNetworkError(e) && attempt < maxExplodeAttempts && !cancelled()) {
          _logger.warning(
            'Search network error for "$trimmed" attempt $attempt: $e',
            component: 'SearchService',
          );
          final backoff = Duration(milliseconds: 300 * attempt);
          if (explodeCeiling - stopwatch.elapsed > backoff) {
            await Future.delayed(backoff);
            continue;
          }
        }
        // Non-transient error (bot check, 403, extractor break): fall back immediately.
        _logger.warning(
          'Explode search failed for "$trimmed" (non-transient or final attempt): $e',
          component: 'SearchService',
        );
        break;
      }
    }

    if (cancelled()) return [];

    // yt-dlp fallback when explode fails or is bot-blocked, bounded by remaining budget.
    final fallback = ytdlpFallback;
    final remForFallback = remaining();
    if (fallback != null && remForFallback > const Duration(seconds: 1)) {
      try {
        _logger.info(
          'Explode search failed for "$trimmed" — trying yt-dlp ytsearch fallback (budget=${remForFallback.inSeconds}s)',
          component: 'SearchService',
        );
        final results = await fallback(trimmed, limit: 15).timeout(remForFallback);
        if (cancelled()) return [];
        if (results.isNotEmpty) {
          _currentSearchQuery = trimmed;
          _currentSearchPage = null;
          _storeCache(trimmed, results);
          return results;
        }
      } catch (e, stack) {
        lastError ??= e;
        lastStack ??= stack;
        _logger.warning(
          'yt-dlp search fallback also failed for "$trimmed": $e',
          component: 'SearchService',
          error: e,
          stackTrace: stack,
        );
      }
    }

    if (lastError != null) {
      _logger.error(
        'Search failed for "$trimmed"',
        component: 'SearchService',
        error: lastError,
        stackTrace: lastStack,
      );
      if (lastError is TimeoutException) {
        throw lastError;
      }
    }
    return [];
  }

  Future<List<SearchVideoResult>> loadMoreVideos({
    String? expectedQuery,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final page = _currentSearchPage;
    final pageQuery = _currentSearchQuery;
    if (page == null) return [];
    if (expectedQuery != null &&
        pageQuery != null &&
        expectedQuery.trim() != pageQuery) {
      return [];
    }
    final myToken = _requestToken;
    const maxAttempts = 2;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final nextPage = await page.nextPage().timeout(timeout);
        if (myToken != _requestToken) return [];
        if (expectedQuery != null && _currentSearchQuery != expectedQuery.trim()) {
          return [];
        }
        if (nextPage == null) return [];
        _currentSearchPage = nextPage;
        final mapped = _mapVideos(nextPage);
        // Update cached list & page cursor so returning to this cached query
        // preserves loaded items and pagination state.
        if (pageQuery != null && _cache.containsKey(pageQuery)) {
          final existing = _cache[pageQuery]!;
          final seen = existing.map((v) => v.id).toSet();
          final merged = [
            ...existing,
            ...mapped.where((v) => seen.add(v.id)),
          ];
          _storeCache(pageQuery, merged, page: nextPage);
        }
        return mapped;
      } on TimeoutException catch (e) {
        _logger.warning(
          'loadMore timeout attempt $attempt/$maxAttempts: $e',
          component: 'SearchService',
        );
        if (attempt < maxAttempts && myToken == _requestToken) {
          await Future.delayed(Duration(milliseconds: 250 * attempt));
          continue;
        }
        return [];
      } catch (e, stack) {
        if (_isTransientNetworkError(e) &&
            attempt < maxAttempts &&
            myToken == _requestToken) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
          continue;
        }
        _logger.error(
          'Error loading more search videos',
          component: 'SearchService',
          error: e,
          stackTrace: stack,
        );
        return [];
      }
    }
    return [];
  }

  Future<List<SearchVideoResult>> getTrendingVideos() async {
    const perTermTimeout = Duration(seconds: 10);
    try {
      _logger.info('Fetching trending videos', component: 'SearchService');

      final searchTerms = ['trending', 'popular videos', 'music', 'gaming'];

      for (final term in searchTerms) {
        for (int attempt = 1; attempt <= 2; attempt++) {
          try {
            final searchList = await _yt.search.search(term, filter: TypeFilters.video).timeout(perTermTimeout);
            if (searchList.isNotEmpty) {
              return _mapVideos(searchList);
            }
            break; // empty, try next term
          } on TimeoutException catch (e) {
            _logger.warning('Trending timeout term "$term" attempt $attempt: $e', component: 'SearchService');
            if (attempt < 2) await Future.delayed(Duration(milliseconds: 300 * attempt));
            continue;
          } catch (e) {
            _logger.warning('Failed to fetch trending with term "$term" attempt $attempt: $e', component: 'SearchService');
            if (_isTransientNetworkError(e) && attempt < 2) {
              await Future.delayed(Duration(milliseconds: 400));
              continue;
            }
            break;
          }
        }
      }

      return [];
    } catch (e, stack) {
      _logger.error('Critical error in getTrendingVideos', component: 'SearchService', error: e, stackTrace: stack);
      return [];
    }
  }

  void dispose() {
    _ownedYt?.close();
  }

  List<SearchVideoResult> _mapVideos(Iterable<Video> videos) {
    return videos
        .map(
          (video) => SearchVideoResult(
            id: video.id.value,
            title: video.title,
            author: video.author,
            thumbnailUrl: video.thumbnails.mediumResUrl,
            duration: video.duration,
            viewCount: video.engagement.viewCount,
            uploadDate: video.uploadDate?.toString(),
          ),
        )
        .toList();
  }
}
