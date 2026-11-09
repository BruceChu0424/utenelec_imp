import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';

class _History {
  const _History(
    this.rows,
    this.next, {
    this.authority = 'first',
    this.version = 'v1',
  });
  final List<int> rows;
  final String? next;
  final String authority;
  final String version;
  _History complete(List<int> rows) =>
      _History(rows, null, authority: authority, version: version);
}

Future<_History> _load(
  Future<_History> Function(String?, int) fetch, {
  bool Function()? current,
}) => loadCompleteCursorSnapshot<int, _History, String>(
  loadPage: fetch,
  rowsOf: (page) => page.rows,
  nextCursorOf: (page) => page.next,
  rebuildSnapshot: (first, rows) => first.complete(rows),
  isCurrent: current ?? () => true,
  idOf: (row) => row,
  revisionOf: (page) => page.version,
);

void main() {
  test(
    'an explicitly immutable timeline overlap keeps the first ID fact and still reaches EOF',
    () async {
      final result = await loadCompleteCursorSnapshot<int, _History, String>(
        isCurrent: () => true,
        idOf: (row) => row,
        deduplicateOverlaps: true,
        loadPage: (cursor, _) async => cursor == null
            ? const _History([1], 'next')
            : const _History([1, 2], null),
        rowsOf: (page) => page.rows,
        nextCursorOf: (page) => page.next,
        rebuildSnapshot: (first, rows) => first.complete(rows),
      );
      expect(result.rows, [1, 2]);
      expect(result.next, isNull);
    },
  );

  test(
    'a repeated structured cursor is rejected even when the server returns a new map instance',
    () async {
      var calls = 0;
      await expectLater(
        loadCompleteCursorSnapshot<
          int,
          ({List<int> rows, Map<String, int>? next}),
          Map<String, int>
        >(
          isCurrent: () => true,
          loadPage: (_, _) async => (rows: [++calls], next: {'id': 1}),
          rowsOf: (page) => page.rows,
          nextCursorOf: (page) => page.next,
          rebuildSnapshot: (first, rows) => (rows: rows, next: null),
          idOf: (row) => row,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 2);
    },
  );

  test(
    'real cursor termination completes every history row and preserves first authority without a fake total',
    () async {
      final calls = <(String?, int)>[];
      final result = await _load((cursor, size) async {
        calls.add((cursor, size));
        return cursor == null
            ? const _History([1], 'second')
            : const _History([2], null, authority: 'not-first');
      });
      // A cursor continues from its token: a small first batch, then the
      // bounded maximum (2026-11-08 progressive plan).
      expect(calls, [(null, 50), ('second', 200)]);
      expect(result.rows, [1, 2]);
      expect(result.next, isNull);
      expect(result.authority, 'first');
    },
  );

  for (final defect in ['cursor', 'empty', 'identity', 'version']) {
    test(
      '$defect defect rejects a cursor result instead of publishing a partial complete history',
      () async {
        await expectLater(
          _load((cursor, _) async {
            if (cursor == null) return const _History([1], 'next');
            return switch (defect) {
              'cursor' => const _History([2], 'next'),
              'empty' => const _History([], 'later'),
              'identity' => const _History([1], null),
              _ => const _History([2], null, version: 'v2'),
            };
          }),
          throwsA(isA<ApiException>()),
        );
      },
    );
  }

  test(
    'an owner retirement rejects a late cursor response and does not read its successor',
    () async {
      var current = true;
      final held = Completer<_History>();
      final calls = <String?>[];
      final result = _load((cursor, _) async {
        calls.add(cursor);
        return cursor == null ? const _History([1], 'next') : held.future;
      }, current: () => current);
      final rejected = expectLater(result, throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      current = false;
      held.complete(const _History([2], 'must-not-read'));
      await rejected;
      expect(calls, [null, 'next']);
    },
  );
}
