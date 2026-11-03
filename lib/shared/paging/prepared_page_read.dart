import '../../components/data_display/paged_read_cache.dart';
import '../models/paged_result.dart';
import 'paged_query_identity.dart';

/// A short-lived handoff from category preparation to a visible table. Only
/// explicitly prepared first pages are retained; ordinary reads stay fresh.
/// The owner retires this lease on identity, access, transport or write changes.
class PreparedPageRead<T> {
  static const defaultFreshFor = Duration(seconds: 15);

  PreparedPageRead({
    this.maximumQueries = 8,
    this.maximumRowsPerPage = 50,
    this.freshFor = defaultFreshFor,
  });

  final int maximumQueries;
  final int maximumRowsPerPage;
  final Duration freshFor;
  final _entries = <PagedReadQueryKey, _PreparedPage<T>>{};
  final _consumed = <PagedReadQueryKey, Stopwatch>{};
  final _inFlight = <PagedReadQueryKey, int>{};
  int _generation = 0;
  bool _disposed = false;

  Future<void> prepare(
    Object query,
    Future<PagedResult<T>> Function() fetch,
  ) async {
    if (_disposed) return;
    final key = PagedReadQueryKey(query);
    // A fast click may reach a category before its queued preparation. That
    // read has already done the useful work; do not fetch it again in the tail.
    if (_inFlight.containsKey(key) ||
        (_consumed[key]?.elapsed ?? freshFor) < freshFor) {
      return;
    }
    final previous = _entries[key];
    if (previous != null && previous.isFresh(freshFor)) return;
    _entries.remove(key)?.cache.clear();
    while (_entries.length >= maximumQueries) {
      _entries.remove(_entries.keys.first)?.cache.clear();
    }
    final entry = _PreparedPage<T>(maximumRowsPerPage);
    _entries[key] = entry;
    final generation = _generation;
    try {
      await entry.cache.read(1, fetch);
      entry.completed.start();
      if (_disposed || generation != _generation) return;
    } catch (_) {
      // Failed speculation is not retained. A later click starts an ordinary
      // read. Once adopted in flight, it follows the visible table's error flow.
      if (identical(_entries[key], entry)) _entries.remove(key);
    }
  }

  Future<PagedResult<T>> read(
    Object query,
    Future<PagedResult<T>> Function() fetch, {
    bool preferPrepared = false,
  }) async {
    final key = PagedReadQueryKey(query);
    // Consume once, including an in-flight preparation. Refreshing the same
    // query first removes its old preparation so it cannot reappear afterward.
    final entry = _entries.remove(key);
    if (_disposed) throw StateError('Prepared read owner changed');
    final generation = _generation;
    _inFlight.update(key, (count) => count + 1, ifAbsent: () => 1);
    final prepared = preferPrepared && entry != null && entry.isFresh(freshFor);
    if (!prepared) entry?.cache.clear();
    try {
      final result = await (prepared ? entry.cache.read(1, fetch) : fetch());
      if (_disposed || generation != _generation) {
        throw StateError('Prepared read owner changed');
      }
      return result;
    } finally {
      if (!_disposed && generation == _generation) {
        final remaining = _inFlight[key]! - 1;
        if (remaining > 0) {
          _inFlight[key] = remaining;
        } else {
          _inFlight.remove(key);
          _consumed.remove(key);
          _consumed[key] = Stopwatch()..start();
          while (_consumed.length > maximumQueries) {
            _consumed.remove(_consumed.keys.first);
          }
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    for (final entry in _entries.values) {
      entry.cache.clear();
    }
    _entries.clear();
    _consumed.clear();
    _inFlight.clear();
  }
}

class _PreparedPage<T> {
  _PreparedPage(int maximumRows)
    : cache = PagedReadCache<T>(maximumPages: 1, maximumRows: maximumRows);
  final PagedReadCache<T> cache;
  final completed = Stopwatch();
  bool isFresh(Duration freshFor) =>
      !completed.isRunning || completed.elapsed < freshFor;
}
