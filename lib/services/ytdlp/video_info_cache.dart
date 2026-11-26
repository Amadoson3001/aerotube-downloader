/// Small TTL + LRU in-memory cache with in-flight request deduplication.
class MetadataCache<T> {
  final Duration ttl;
  final int maxEntries;
  final Map<String, ({T value, DateTime at})> _entries = {};
  final Map<String, Future<T>> _inFlight = {};

  MetadataCache({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 30,
  });

  bool hasValid(String key) {
    final entry = _entries[key];
    if (entry == null) return false;
    if (DateTime.now().difference(entry.at) >= ttl) {
      _entries.remove(key);
      return false;
    }
    return true;
  }

  T? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) >= ttl) {
      _entries.remove(key);
      return null;
    }
    // Refresh LRU position (LinkedHashMap keeps insertion order).
    _entries.remove(key);
    _entries[key] = entry;
    return entry.value;
  }

  void put(String key, T value) {
    final now = DateTime.now();
    _entries.removeWhere((_, e) => now.difference(e.at) >= ttl);
    if (_entries.containsKey(key)) {
      _entries.remove(key);
    } else if (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = (value: value, at: now);
  }

  Future<T>? getInFlight(String key) => _inFlight[key];

  Future<T> trackInFlight(String key, Future<T> future) {
    _inFlight[key] = future;
    void cleanup() {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    }

    future.then(
      (_) => cleanup(),
      onError: (Object _, StackTrace __) => cleanup(),
    );
    return future;
  }

  void clearInFlight() => _inFlight.clear();

  void clear() => _entries.clear();

  void removeWhere(bool Function(String key) test) {
    _entries.removeWhere((key, _) => test(key));
  }
}
