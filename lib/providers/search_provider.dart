import 'dart:async';
import 'package:flutter/material.dart';
import '../models/search_video_result.dart';
import '../services/core/search_service.dart';
import '../services/core/logging_service.dart';
import '../services/ytdlp/ytdlp_tool_service.dart';
import '../core/utils/error_helper.dart';

class SearchProvider extends ChangeNotifier {
  late final SearchService _searchService;
  Timer? _debounceTimer;

  SearchProvider({YtdlpToolService? ytdlpService, SearchService? searchService}) {
    _searchService = searchService ??
        SearchService(
          ytdlpFallback: ytdlpService == null
              ? null
              : (query, {int limit = 10}) =>
                    _searchViaYtdlp(ytdlpService, query, limit),
        );
  }

  /// Platform-aware yt-dlp `ytsearchN:` fallback used when explode search fails.
  Future<List<SearchVideoResult>> _searchViaYtdlp(
    YtdlpToolService service,
    String query,
    int limit,
  ) async {
    final raw = await service.searchVideosRaw(query, limit: limit);

    // Android wraps yt-dlp JSON as {results: {entries: [...]}}.
    // Desktop searchVideosRaw returns the raw playlist object {entries: [...]}.
    final resultsObj = raw['results'];
    final entries = (resultsObj is Map ? resultsObj['entries'] : raw['entries'])
            as List? ??
        const [];
    final mapped = <SearchVideoResult>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final id = (e['id'] ?? e['url'] ?? '').toString();
      if (id.isEmpty) continue;
      // Flat entries may store a full watch URL in `url`.
      final videoId = id.contains('watch?v=')
          ? id.split('watch?v=').last.split('&').first
          : id;
      if (videoId.isEmpty) continue;
      final durationSec = e['duration'];
      mapped.add(
        SearchVideoResult(
          id: videoId,
          title: (e['title'] ?? 'Untitled').toString(),
          author: (e['channel'] ?? e['uploader'] ?? 'Unknown').toString(),
          thumbnailUrl: (e['thumbnail'] ??
                  'https://i.ytimg.com/vi/$videoId/mqdefault.jpg')
              .toString(),
          duration: durationSec is num
              ? Duration(seconds: durationSec.toInt())
              : null,
          viewCount: (e['view_count'] as num?)?.toInt(),
          uploadDate: e['upload_date']?.toString(),
        ),
      );
    }
    return mapped;
  }

  List<SearchVideoResult> _searchResults = [];
  List<SearchVideoResult> _trendingVideos = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  String _lastQuery = '';
  bool _hasMoreResults = false;

  List<SearchVideoResult> get searchResults => _searchResults;
  List<SearchVideoResult> get trendingVideos => _trendingVideos;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  String? get error => _error;
  String get lastQuery => _lastQuery;
  bool get hasMoreResults => _hasMoreResults;

  int _searchGen = 0;

  bool _isVpnError(String m) {
    final l = m.toLowerCase();
    return l.contains('timed out') || l.contains('timeout') || l.contains('vpn') || l.contains('socket') || l.contains('connection');
  }

  Future<void> search(
    String query, {
    bool immediate = false,
    Duration overallBudget = SearchService.defaultOverallBudget,
  }) async {
    if (query.trim().isEmpty) return;

    _debounceTimer?.cancel();
    final trimmed = query.trim();

    Future<void> execute() async {
      final myGen = ++_searchGen;
      _isLoading = true;
      _isLoadingMore = false;
      _error = null;
      _lastQuery = trimmed;
      notifyListeners();

      try {
        // Single overall deadline shared with SearchService so yt-dlp fallback
        // gets its bounded slice instead of being cut off by a shorter outer timeout.
        final results = await _searchService
            .searchVideos(
              trimmed,
              overallBudget: overallBudget,
              isCancelled: () => myGen != _searchGen || _isDisposed,
            )
            .timeout(
              overallBudget + const Duration(seconds: 2),
              onTimeout: () => throw TimeoutException(
                'Search timed out - VPN may be slowing connection, try again or disable VPN',
              ),
            );
        if (myGen != _searchGen) return; // cancelled by newer search
        _searchResults = results;
        _hasMoreResults = results.isNotEmpty;
      } catch (e, stackTrace) {
        if (myGen != _searchGen) return;
        LoggingService().error(
          'Search failed for query "$trimmed": $e',
          component: 'SearchProvider',
          error: e,
          stackTrace: stackTrace,
        );
        var cleaned = ErrorHelper.clean(e.toString());
        if (e is TimeoutException || _isVpnError(cleaned)) {
          if (!cleaned.toLowerCase().contains('vpn')) {
            cleaned =
                'Search timed out - VPN may be slowing connection, try again or disable VPN. ($cleaned)';
          }
        }
        _error = cleaned;
        _hasMoreResults = false;
      } finally {
        if (myGen == _searchGen) {
          _isLoading = false;
          notifyListeners();
        }
      }
    }

    if (immediate) {
      await execute();
      return;
    }

    // debounce with cancellation support
    _debounceTimer = Timer(const Duration(milliseconds: 250), execute);
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || _isLoading || !_hasMoreResults) return;
    final myGen = _searchGen;
    final expectedQuery = _lastQuery;
    if (expectedQuery.isEmpty) return;

    _isLoadingMore = true;
    _error = null;
    notifyListeners();

    try {
      final nextResults = await _searchService
          .loadMoreVideos(expectedQuery: expectedQuery)
          .timeout(
            const Duration(seconds: 18),
            onTimeout: () => throw TimeoutException(
              'Load more timed out - VPN may be slowing connection',
            ),
          );
      if (myGen != _searchGen || _lastQuery != expectedQuery) return;
      if (nextResults.isEmpty) {
        _hasMoreResults = false;
      } else {
        final existingIds = _searchResults.map((video) => video.id).toSet();
        _searchResults.addAll(
          nextResults.where((video) => existingIds.add(video.id)),
        );
        const maxSearchResults = 200;
        if (_searchResults.length > maxSearchResults) {
          _searchResults = _searchResults.sublist(0, maxSearchResults);
          _hasMoreResults = false;
        }
      }
    } catch (e, stackTrace) {
      if (myGen != _searchGen || _lastQuery != expectedQuery) return;
      LoggingService().error(
        'Load more search results failed: $e',
        component: 'SearchProvider',
        error: e,
        stackTrace: stackTrace,
      );
      var cleaned = ErrorHelper.clean(e.toString());
      if (e is TimeoutException || _isVpnError(cleaned)) {
        cleaned =
            'Load more timed out - VPN may be slowing connection. ($cleaned)';
      }
      _error = cleaned;
    } finally {
      if (myGen == _searchGen) {
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchTrending() async {
    if (_trendingVideos.isNotEmpty) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _trendingVideos = await _searchService.getTrendingVideos().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Trending fetch timed out - VPN may be slowing connection'),
      );
    } catch (e, stackTrace) {
      LoggingService().error(
        'Fetch trending videos failed: $e',
        component: 'SearchProvider',
        error: e,
        stackTrace: stackTrace,
      );
      var cleaned = ErrorHelper.clean(e.toString());
      if (e is TimeoutException || _isVpnError(cleaned)) {
        cleaned = 'Trending fetch timed out - VPN may be slowing connection. ($cleaned)';
      }
      _error = cleaned;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchGen++;
    _searchService.resetPagination();
    _isLoading = false;
    _isLoadingMore = false;
    _searchResults = [];
    _lastQuery = '';
    _error = null;
    _hasMoreResults = false;
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounceTimer?.cancel();
    _searchService.dispose();
    super.dispose();
  }
}
