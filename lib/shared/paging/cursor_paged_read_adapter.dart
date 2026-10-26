import '../models/paged_result.dart';
import 'paged_query_identity.dart';
import 'scoped_paged_read.dart';

/// Complete cursor response with the exact token used and returned by it.
/// Ordinal/known-next horizon are internal cache indices, never server totals.
class CursorReadSnapshot<R, S, C> extends PagedReadSnapshot<R, S> {
  CursorReadSnapshot({
    required int ordinal,
    required List<R> rows,
    required S response,
    required this.cursor,
    required this.nextCursor,
  }) : super(
         page: PagedResult<R>(
           items: rows,
           page: ordinal,
           size: rows.length,
           // The cursor protocol has no total. This stable internal sentinel
           // prevents an advancing known horizon from retiring previous pages.
           total: 0,
           totalPages: ordinal + (nextCursor == null ? 0 : 1),
         ),
         snapshot: response,
       );

  final C? cursor;
  final C? nextCursor;
}

/// Cursor transport adapter for the ordinary ScopedPagedRead cache/worker.
/// Stores only bounded cursor bookmarks; DTOs stay in the shared row cache.
/// If an old bookmark was evicted, replay from the nearest earlier known
/// cursor, sequentially and with ownership checked before every transport.
class CursorPagedReadAdapter<R, S, C> {
  CursorPagedReadAdapter({this.maximumBookmarks = 128})
    : assert(maximumBookmarks >= 3);

  final int maximumBookmarks;
  final _bookmarks = <int, C?>{1: null};
  Object? _scope;
  bool _bound = false;
  int _generation = 0;

  int get bookmarkCount => _bookmarks.length;

  void bind(Object scope, {bool reset = false}) {
    if (!reset && _bound && samePagedReadQuery(_scope, scope)) return;
    invalidate();
    _scope = freezePagedReadQuery(scope);
    _bound = true;
  }

  void invalidate() {
    _generation++;
    _bookmarks
      ..clear()
      ..[1] = null;
  }

  void remember(CursorReadSnapshot<R, S, C> page) {
    _remember(page.page, page.cursor);
    if (page.nextCursor != null) _remember(page.page + 1, page.nextCursor);
  }

  void _remember(int ordinal, C? cursor) {
    _bookmarks.remove(ordinal);
    _bookmarks[ordinal] = cursor;
    while (_bookmarks.length > maximumBookmarks) {
      final victim = _bookmarks.keys.firstWhere((page) => page != 1);
      _bookmarks.remove(victim);
    }
  }

  Future<CursorReadSnapshot<R, S, C>> fetch(
    int ordinal, {
    required Future<S> Function(C? cursor) fetch,
    required List<R> Function(S response) rowsOf,
    required C? Function(S response) nextCursorOf,
    required bool Function() isCurrent,
  }) async {
    final generation = _generation;
    bool current() => generation == _generation && isCurrent();
    if (ordinal < 1 || !current()) {
      throw StateError('Cursor read owner changed');
    }
    final known = _bookmarks.keys.where((page) => page <= ordinal);
    var page = known.reduce((a, b) => a > b ? a : b);
    var cursor = _bookmarks[page];
    while (true) {
      if (!current()) throw StateError('Cursor read owner changed');
      final response = await fetch(cursor);
      if (!current()) throw StateError('Cursor read owner changed');
      final rows = rowsOf(response), nextCursor = nextCursorOf(response);
      final snapshot = CursorReadSnapshot<R, S, C>(
        ordinal: page,
        rows: rows,
        response: response,
        cursor: cursor,
        nextCursor: nextCursor,
      );
      remember(snapshot);
      if (page == ordinal) return snapshot;
      if (nextCursor == null || nextCursor == cursor) {
        throw StateError('Cursor response has no next page');
      }
      page++;
      cursor = nextCursor;
      // A long backwards revisit must not become a synchronous page crawl.
      await Future<void>.delayed(Duration.zero);
    }
  }
}
