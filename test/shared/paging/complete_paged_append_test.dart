import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';

UiWorkBudget _unbounded() =>
    UiWorkBudget(maxItems: 1 << 30, slice: const Duration(days: 1));

class _Base {
  const _Base(this.id);
  final int id;
}

class _Child extends _Base {
  const _Child(super.id);
}

class _ChildPage extends PagedResult<_Child> {
  _ChildPage(List<_Child> rows, {required super.page})
    : super(items: rows, size: 1, total: 3, totalPages: 3);

  _ChildPage._(PagedResult<_Child> page)
    : super(
        items: page.items,
        page: page.page,
        size: page.size,
        total: page.total,
        totalPages: page.totalPages,
      );

  @override
  _ChildPage withRows(
    List<_Child> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) => _ChildPage._(
    super.withRows(
      rows,
      page: page,
      size: size,
      total: total,
      totalPages: totalPages,
    ),
  );
}

class _ProvenPage extends PagedResult<int>
    implements VersionedPagedResultProof {
  _ProvenPage(List<int> rows, {required super.page})
    : super(
        items: rows,
        size: 1,
        total: 4,
        totalPages: 4,
        readScopeVersion: 'scope',
      );
  @override
  String get readSnapshotRevision => 'a' * 64;
  @override
  String get readDataVersion => 'b' * 64;
  @override
  Object get snapshotRevision => (readSnapshotRevision, readDataVersion);
}

void main() {
  for (final total in [35000, 100000]) {
    for (final slow in [false, true]) {
      test(
        '$total rows ${slow ? "slow" : "fast"} copy each sealed row once',
        () {
          fakeAsync((clock) {
            final observer = debugPagedRowsCopyObserver;
            var copied = 0;
            var directoryReferences = 0;
            var batches = 0;
            final prefixes = <PagedResult<int>>[];
            PagedResult<int>? complete;
            Object? error;
            debugPagedRowsCopyObserver = (rows, chunks) {
              copied += rows;
              directoryReferences += chunks;
            };
            try {
              unawaited(
                loadCompletePagedResult<int>(
                  loadPage: (page, size) async {
                    batches++;
                    if (slow) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 250),
                      );
                    }
                    final start = (page - 1) * size;
                    final end = (start + size).clamp(0, total);
                    return PagedResult<int>(
                      items: [
                        for (var index = start; index < end; index++) index,
                      ],
                      page: page,
                      size: size,
                      total: total,
                      totalPages: (total + size - 1) ~/ size,
                      readScopeVersion: 'scope',
                    );
                  },
                  idOf: (row) => row,
                  isCurrent: () => true,
                  budget: _unbounded(),
                  onProgressiveBatch: prefixes.add,
                ).then<void>((result) => complete = result).catchError((
                  Object failure,
                ) {
                  error = failure;
                }),
              );
              clock.flushMicrotasks();
              if (slow) clock.elapse(const Duration(minutes: 2));
              clock.flushMicrotasks();
              expect(error, isNull);
              expect(complete, isNotNull);
              expect(complete!.items.length, total);
              for (var index = 0; index < total; index++) {
                expect(complete!.items[index], index);
              }
              expect(
                copied,
                total,
                reason: 'sealing never recopies an old prefix',
              );
              expect(directoryReferences, lessThan(total));
              expect(prefixes.first.items.length, 50);
              expect(prefixes.first.items, List.generate(50, (index) => index));
              if (slow) expect(prefixes.length, batches - 1);
              for (final prefix in prefixes) {
                expect(
                  pagedRowsAppendStart(prefix.items, complete!.items),
                  prefix.items.length,
                );
              }
              expect(clock.pendingTimers, isEmpty);
            } finally {
              debugPagedRowsCopyObserver = observer;
            }
          });
        },
      );
    }
  }

  test(
    'a base reader preserves child response type for progressive and final rows',
    () async {
      final prefixes = <PagedResult<_Base>>[];
      final result = await loadCompletePagedResult<_Base>(
        loadPage: (page, size) async => _ChildPage([_Child(page)], page: page),
        batchSize: 1,
        isCurrent: () => true,
        idOf: (row) => row.id,
        progressiveInterval: Duration.zero,
        onProgressiveBatch: prefixes.add,
      );
      expect(result, isA<_ChildPage>());
      expect(result.items, isA<List<_Child>>());
      expect(prefixes.every((page) => page is _ChildPage), isTrue);
      expect(pagedRowsAppendStart(prefixes.first.items, result.items), 1);
    },
  );

  test(
    'mutable page membership is frozen before yielding and cannot alter old prefixes',
    () async {
      final input = <int>[];
      final prefixes = <PagedResult<int>>[];
      final result = await loadCompletePagedResult<int>(
        loadPage: (page, size) async {
          input
            ..clear()
            ..addAll([page * 2 - 2, page * 2 - 1]);
          Timer.run(input.clear);
          return PagedResult(
            items: input,
            page: page,
            size: 2,
            total: 6,
            totalPages: 3,
          );
        },
        batchSize: 2,
        isCurrent: () => true,
        budget: UiWorkBudget(maxItems: 1),
        onPage: (_) => input.clear(),
        progressiveInterval: Duration.zero,
        onProgressiveBatch: prefixes.add,
      );
      input.add(99);
      expect(result.items, [0, 1, 2, 3, 4, 5]);
      expect(prefixes.first.items, [0, 1]);
    },
  );

  test(
    'queued concurrent pages retain received membership behind a held head',
    () async {
      final head = Completer<void>();
      var mutated = false;
      final result = await loadCompletePagedResult<int>(
        loadPage: (page, size) async {
          if (page == 2) await head.future;
          final rows = [page];
          if (page == 3) {
            Timer.run(() {
              rows
                ..clear()
                ..add(99);
              mutated = true;
              head.complete();
            });
          }
          return _ProvenPage(rows, page: page);
        },
        batchSize: 1,
        maxConcurrentPages: 2,
        idOf: (row) => row,
        isCurrent: () => true,
      );
      expect(mutated, isTrue);
      expect(result.items, [1, 2, 3, 4]);
    },
  );

  test(
    'overlap replacement updates the result without claiming immutable append',
    () async {
      final prefixes = <PagedResult<(int, String)>>[];
      final result = await loadCompletePagedResult<(int, String)>(
        loadPage: (page, size) async => PagedResult(
          items: switch (page) {
            1 => [(1, 'old'), (2, 'two')],
            2 => [(1, 'new'), (3, 'three')],
            _ => [(4, 'four')],
          },
          page: page,
          size: size,
          total: -1,
          totalPages: 3,
        ),
        batchSize: 2,
        allowUnknownTotal: true,
        deduplicateOverlaps: true,
        idOf: (row) => row.$1,
        isCurrent: () => true,
        progressiveInterval: Duration.zero,
        onProgressiveBatch: prefixes.add,
      );
      expect(prefixes.first.items, [(1, 'old'), (2, 'two')]);
      expect(result.items, [(1, 'new'), (2, 'two'), (3, 'three'), (4, 'four')]);
      expect(pagedRowsAppendStart(prefixes.first.items, result.items), isNull);
    },
  );

  test(
    'retirement and scope changes never publish an appended stale batch',
    () async {
      for (final changedScope in [false, true]) {
        var current = true;
        final prefixes = <PagedResult<int>>[];
        final future = loadCompletePagedResult<int>(
          loadPage: (page, size) async => PagedResult(
            items: [page],
            page: page,
            size: 1,
            total: 3,
            totalPages: 3,
            readScopeVersion: page > 1 && changedScope ? 'other' : 'original',
          ),
          batchSize: 1,
          isCurrent: () => current,
          progressiveInterval: Duration.zero,
          onProgressiveBatch: (page) {
            prefixes.add(page);
            if (!changedScope) current = false;
          },
        );
        await expectLater(
          future,
          throwsA(changedScope ? isA<ApiException>() : isA<UiWorkCancelled>()),
        );
        expect(prefixes, hasLength(1));
        expect(prefixes.single.items, [1]);
      }
    },
  );
}
