import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/cursor_paged_read_adapter.dart';

class _Response {
  const _Response(this.rows, this.next);
  final List<int> rows;
  final String? next;
}

void main() {
  test('opaque tokens are used exactly and bookmarks remain bounded', () async {
    final adapter = CursorPagedReadAdapter<int, _Response, String>(
      maximumBookmarks: 3,
    )..bind(['query-A']);
    final tokens = <String?>[];
    Future<_Response> fetch(String? token) async {
      tokens.add(token);
      final ordinal = token == null ? 1 : int.parse(token.substring(7)) + 1;
      return _Response([ordinal], 'opaque-$ordinal');
    }

    final sixth = await adapter.fetch(
      6,
      fetch: fetch,
      rowsOf: (r) => r.rows,
      nextCursorOf: (r) => r.next,
      isCurrent: () => true,
    );
    expect(tokens, [
      null,
      'opaque-1',
      'opaque-2',
      'opaque-3',
      'opaque-4',
      'opaque-5',
    ]);
    expect(sixth.snapshot.rows, [6]);
    expect(sixth.cursor, 'opaque-5');
    expect(sixth.nextCursor, 'opaque-6');
    expect(adapter.bookmarkCount, lessThanOrEqualTo(3));
    tokens.clear();
    final old = await adapter.fetch(
      2,
      fetch: fetch,
      rowsOf: (r) => r.rows,
      nextCursorOf: (r) => r.next,
      isCurrent: () => true,
    );
    expect(tokens, [
      null,
      'opaque-1',
    ], reason: 'replay uses known tokens, never a fabricated offset');
    expect(old.snapshot.rows, [2]);
    expect(adapter.bookmarkCount, lessThanOrEqualTo(3));
  });

  test('query retirement discards late cursor metadata', () async {
    final adapter = CursorPagedReadAdapter<int, _Response, String>()
      ..bind(['A']);
    final gate = Completer<_Response>();
    final pending = adapter.fetch(
      1,
      fetch: (_) => gate.future,
      rowsOf: (r) => r.rows,
      nextCursorOf: (r) => r.next,
      isCurrent: () => true,
    );
    final rejected = expectLater(pending, throwsStateError);
    adapter.bind(['B']);
    gate.complete(const _Response([1], 'old-token'));
    await rejected;
    expect(adapter.bookmarkCount, 1);
  });

  test('end of cursor chain cannot invent a later page', () async {
    final adapter = CursorPagedReadAdapter<int, _Response, String>()
      ..bind(['A']);
    final tokens = <String?>[];
    await expectLater(
      adapter.fetch(
        3,
        fetch: (token) async {
          tokens.add(token);
          return token == null
              ? const _Response([1], 'next')
              : const _Response([2], null);
        },
        rowsOf: (r) => r.rows,
        nextCursorOf: (r) => r.next,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(tokens, [null, 'next']);
  });
}
