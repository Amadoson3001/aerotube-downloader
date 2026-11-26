import 'dart:async';

/// Coordinates priority between user-initiated interactive metadata fetches
/// and optional background probes (e.g. startup tool/app update checks).
class FetchPriority {
  static int _activeInteractiveCount = 0;
  static final List<Completer<void>> _idleWaiters = [];

  static bool get hasInteractiveFetch => _activeInteractiveCount > 0;

  static void beginInteractive() {
    _activeInteractiveCount++;
  }

  static void endInteractive() {
    if (_activeInteractiveCount > 0) {
      _activeInteractiveCount--;
    }
    if (_activeInteractiveCount == 0 && _idleWaiters.isNotEmpty) {
      final waiters = List<Completer<void>>.from(_idleWaiters);
      _idleWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
  }

  /// Waits until no interactive fetch is in progress (bounded by [timeout]).
  static Future<void> waitForIdle({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_activeInteractiveCount == 0) return;
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _idleWaiters.remove(completer);
    }
  }
}
