import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedResult<int> _page(int page, {int total = 3, String version = 'v1'}) =>
    PagedResult(
      items: [page],
      page: page,
      size: 1,
      total: total,
      totalPages: total,
      readScopeVersion: version,
    );

class _Base {
  const _Base(this.id);
  final int id;
}

class _Child extends _Base {
  const _Child(super.id);
}

class _OtherChild extends _Base {
  const _OtherChild(super.id);
}

class _ChildPage extends PagedResult<_Child> {
  _ChildPage(
    List<_Child> rows, {
    super.page = 1,
    super.size = 1,
    super.totalPages = 2,
    this.authority = 'first',
  }) : super(items: rows, total: 2);
  final String authority;
  @override
  _ChildPage withRows(
    List<_Child> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) => _ChildPage(
    List.unmodifiable(rows),
    page: page,
    size: size ?? rows.length,
    totalPages: totalPages ?? 1,
    authority: authority,
  );
}

class _Metadata {
  const _Metadata(this.rows, this.count, this.permission);
  final List<int> rows;
  final int count;
  final String permission;
  _Metadata withPage(PagedResult<int> page) =>
      _Metadata(page.items, count, permission);
}

void main() {
  test(
    'a new request ticket retains same-owner accepted rows while pending or offline, but 403 and owner ABA retire them',
    () async {
      final reader = ScopedPagedRead<int>();
      var ticket = 1;
      var owner = 1;
      final accepted = await reader.read(
        1,
        scope: [owner, 'A'],
        fetchPage: (_) async => const PagedResult(
          items: [1],
          page: 1,
          size: 100,
          total: 1,
          totalPages: 1,
        ),
        isCurrent: () => ticket == 1,
        isOwnerCurrent: () => owner == 1,
      );
      final proof = readWindowBindingOf(accepted.items)!;
      ticket = 2;
      final gate = Completer<PagedResult<int>>();
      final fresh = reader.read(
        1,
        scope: [owner, 'A'],
        fetchPage: (_) => gate.future,
        isCurrent: () => ticket == 2,
        isOwnerCurrent: () => owner == 1,
      );
      expect(proof.isCurrent, isTrue);
      expect(proof.pending, isTrue);
      final failed = expectLater(fresh, throwsA(isA<NetworkException>()));
      gate.completeError(NetworkException());
      await failed;
      expect(proof.isCurrent, isTrue);
      expect(proof.failed, isTrue);
      ticket = 3;
      await expectLater(
        reader.read(
          1,
          scope: [owner, 'A'],
          fetchPage: (_) async =>
              throw ApiException('FORBIDDEN', '', httpStatus: 403),
          isCurrent: () => ticket == 3,
          isOwnerCurrent: () => owner == 1,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(proof.isCurrent, isFalse);
      owner = 2;
      reader.invalidate();
      owner = 3;
      await reader.read(
        1,
        scope: [owner, 'A'],
        fetchPage: (_) async => const PagedResult(
          items: [2],
          page: 1,
          size: 100,
          total: 1,
          totalPages: 1,
        ),
        isCurrent: () => true,
        isOwnerCurrent: () => owner == 3,
      );
      expect(proof.isCurrent, isFalse);
    },
  );
  for (final count in [10000, 100000, 1000000]) {
    test(
      'complete $count-row summary growth uses bounded batches and yields before publication',
      () async {
        var batches = 0, yields = 0, eventTurns = 0;
        final previous = debugUiWorkSliceObserver;
        debugUiWorkSliceObserver = (_, _) {
          yields++;
        };
        final timer = Timer(Duration.zero, () {
          eventTurns++;
        });
        final watch = Stopwatch()..start();
        var offset = 0;
        try {
          final result = await loadCompletePagedResult<int>(
            isCurrent: () => true,
            idOf: (row) => row,
            loadPage: (page, size) async {
              // 50 first, then aligned growth to the bounded shared maximum.
              expect(size, CompleteReadBatchPlan.progressive.sizeAt(offset));
              expect((page - 1) * size, offset);
              batches++;
              final rows = (count - offset).clamp(0, size);
              final items = List.generate(rows, (index) => offset + index);
              offset += rows;
              return PagedResult(
                items: items,
                page: page,
                size: size,
                total: count,
                totalPages: (count + size - 1) ~/ size,
              );
            },
          );
          expect(result.items.length, count);
          expect((result.items.first, result.items.last), (0, count - 1));
          // The batch count follows the shared plan itself (2026-11-09: max 1000).
          var expectedBatches = 0;
          for (
            var o = 0;
            o < count;
            o += CompleteReadBatchPlan.progressive.sizeAt(o)
          ) {
            expectedBatches++;
          }
          expect(batches, expectedBatches);
          expect(yields, greaterThan(0));
          expect(eventTurns, greaterThan(0));
          expect((result.page, result.totalPages), (1, 1));
          // Synthetic local transport only: this is not a WAN latency claim.
          debugPrint(
            'COMPLETE_SUMMARY_GROWTH rows=$count batches=$batches elapsedMs=${watch.elapsedMilliseconds} yields=$yields events=$eventTurns',
          );
        } finally {
          timer.cancel();
          debugUiWorkSliceObserver = previous;
        }
      },
    );
  }

  test(
    'all bounded batches form one local page; a loader keeping its own page size continues on it',
    () async {
      final calls = <(int, int)>[];
      final result = await loadCompletePagedResult<int>(
        loadPage: (page, size) async {
          calls.add((page, size));
          return _page(page);
        },
        isCurrent: () => true,
        idOf: (row) => row,
      );
      expect(calls, [(1, 50), (2, 1), (3, 1)]);
      expect(result.items, [1, 2, 3]);
      expect((result.page, result.total, result.totalPages), (1, 3, 1));
    },
  );

  test(
    'a Base reader safely merges a Child page and retains its typed metadata',
    () async {
      final result = await loadCompletePagedResult<_Base>(
        loadPage: (page, _) async => _ChildPage(
          [_Child(page)],
          page: page,
          authority: page == 1 ? 'first' : 'not-first',
        ),
        isCurrent: () => true,
        idOf: (row) => row.id,
      );
      expect(result, isA<_ChildPage>());
      expect(result.items.map((row) => row.id), [1, 2]);
      expect((result as _ChildPage).authority, 'first');
      expect(result.size, 2);
    },
  );

  test(
    'a real Base response may start with a narrow Child list and later contain another Child subtype',
    () async {
      final result = await loadCompletePagedResult<_Base>(
        loadPage: (page, _) async => PagedResult<_Base>(
          items: page == 1
              ? <_Child>[const _Child(1)]
              : <_OtherChild>[const _OtherChild(2)],
          page: page,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
        isCurrent: () => true,
        idOf: (row) => row.id,
      );
      expect(result.items.map((row) => row.id), [1, 2]);
      expect(result.items.last, isA<_OtherChild>());
    },
  );

  test(
    'typed snapshot rebuild contains every row while first response counts and permissions remain authoritative',
    () async {
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      final result = await reader.read(
        1,
        scope: 'typed',
        isCurrent: () => true,
        fetchPage: (page) async {
          final response = _Metadata([page], page == 1 ? 7 : 99, 'read-only');
          return PagedReadSnapshot<int, _Metadata>(
            page: _page(page),
            snapshot: response,
            rebuildSnapshot: response.withPage,
          );
        },
      );
      final typed = (result as PagedReadSnapshot<int, _Metadata>).snapshot;
      expect(typed.rows, [1, 2, 3]);
      expect(typed.rows, same(result.items));
      expect((typed.count, typed.permission), (7, 'read-only'));
      expect(readWindowBindingOf(typed.rows)!.isCurrent, isTrue);
    },
  );

  test(
    'equal collection revision proofs compare by frozen value rather than object identity',
    () async {
      final result = await loadCompletePagedResult<int>(
        isCurrent: () => true,
        loadPage: (page, _) async => PagedReadSnapshot<int, String>(
          page: _page(page),
          snapshot: 'metadata',
          revision: {
            'schema': ['v1'],
            'scope': 1,
          },
        ),
      );
      expect(result.items, [1, 2, 3]);
    },
  );

  for (final defect in ['total', 'version', 'identity', 'empty']) {
    test(
      '$defect drift rejects a complete snapshot instead of publishing an incomplete result',
      () async {
        final pending = loadCompletePagedResult<int>(
          isCurrent: () => true,
          idOf: (row) => row,
          loadPage: (page, _) async {
            if (page == 1) return _page(1);
            if (defect == 'total') return _page(page, total: 4);
            if (defect == 'version') return _page(page, version: 'v2');
            return PagedResult(
              items: defect == 'empty' ? <int>[] : [1],
              page: page,
              size: 1,
              total: 3,
              totalPages: 3,
              readScopeVersion: 'v1',
            );
          },
        );
        await expectLater(pending, throwsA(isA<ApiException>()));
      },
    );
  }

  test(
    'unknown totals use a real fixed page count and derive an exact total only after completion',
    () async {
      final result = await loadCompletePagedResult<int>(
        isCurrent: () => true,
        allowUnknownTotal: true,
        idOf: (row) => row,
        loadPage: (page, _) async => PagedResult(
          items: [page],
          page: page,
          size: 1,
          total: -1,
          totalPages: 2,
        ),
      );
      expect(result.items, [1, 2]);
      expect((result.total, result.totalPages), (2, 1));
    },
  );

  test(
    'an explicit hasMore horizon is not mistaken for a fixed unknown totalPages',
    () async {
      final result = await loadCompletePagedResult<int>(
        isCurrent: () => true,
        allowUnknownTotal: true,
        unknownPageCountIsHorizon: true,
        idOf: (row) => row,
        loadPage: (page, _) async => PagedResult(
          items: [page],
          page: page,
          size: 1,
          total: -1,
          totalPages: page < 3 ? page + 1 : page,
        ),
      );
      expect(result.items, [1, 2, 3]);
      expect((result.total, result.totalPages), (3, 1));
    },
  );

  test(
    'same query reuse shares its complete flight but an explicit completed refresh reads again',
    () async {
      final reader = ScopedPagedRead<int>();
      addTearDown(reader.dispose);
      final first = Completer<PagedResult<int>>();
      final calls = <int>[];
      Future<PagedResult<int>> fetch(int page) {
        calls.add(page);
        return page == 1 && calls.length == 1
            ? first.future
            : Future.value(_page(page));
      }

      final a = reader.read(
        1,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      final b = reader.read(
        8,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
        useCache: true,
      );
      expect(identical(a, b), isTrue);
      first.complete(_page(1));
      expect((await a).items, [1, 2, 3]);
      await b;
      await reader.read(
        9,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
        useCache: true,
      );
      expect(calls, [1, 2, 3]);
      await reader.read(
        1,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      expect(calls, [1, 2, 3, 1, 2, 3]);
    },
  );

  test(
    'a required fresh read cannot join a pre-write same-query flight or publish its old reply',
    () async {
      final reader = ScopedPagedRead<int>();
      addTearDown(reader.dispose);
      final oldTail = Completer<PagedResult<int>>();
      var revised = false;
      Future<PagedResult<int>> fetch(int page) async {
        if (!revised && page == 2) return oldTail.future;
        return PagedResult(
          items: [page + (revised ? 10 : 0)],
          page: page,
          size: 1,
          total: 2,
          totalPages: 2,
        );
      }

      final old = reader.read(
        1,
        scope: 'same',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      final rejection = expectLater(old, throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      revised = true;
      final fresh = await reader.read(
        1,
        scope: 'same',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      expect(fresh.items, [11, 12]);
      oldTail.complete(
        const PagedResult(
          items: [2],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      await rejection;
      expect(
        (await reader.read(
          1,
          scope: 'same',
          fetchPage: fetch,
          isCurrent: () => true,
          useCache: true,
        )).items,
        [11, 12],
      );
    },
  );

  test(
    'read proof changes retire old rows and every business projection while ordinary local scrolling does no reads',
    () async {
      final reader = ScopedPagedRead<int>();
      addTearDown(reader.dispose);
      var version = 'v1';
      var calls = 0;
      Future<PagedResult<int>> fetch(int page) async {
        calls++;
        return _page(page, version: version);
      }

      final original = await reader.read(
        1,
        scope: 'q',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      final projection = original.items.where((row) => row != 2).toList();
      projectReadWindowBinding(
        original.items,
        projection,
        project: (rows) => rows.where((row) => row != 2).toList(),
        projectionKey: 'visible',
      );
      final binding = readWindowBindingOf(projection)!;
      expect(binding.isCurrent, isTrue);
      for (var index = 0; index < 100; index++) {
        expect(original.items[index % 3], inInclusiveRange(1, 3));
      }
      expect(calls, 3);
      version = 'v2';
      final changed = await reader.read(
        1,
        scope: 'q',
        fetchPage: fetch,
        isCurrent: () => true,
      );
      expect(binding.isCurrent, isFalse);
      expect(readWindowBindingOf(changed.items)!.isCurrent, isTrue);
    },
  );

  test(
    'controller silent refresh publishes only one complete replacement and retains accepted data on failure',
    () async {
      final controller = PagedListController<int>(idOf: (row) => row);
      addTearDown(controller.dispose);
      await controller.load(
        1,
        fetch: () async => _page(1),
        fetchPage: (page) async => _page(page),
      );
      final accepted = controller.page!;
      final gate = Completer<PagedResult<int>>();
      final reached = Completer<void>();
      final refresh = controller.load(
        1,
        silent: true,
        fetch: () async => _page(1),
        fetchPage: (page) {
          if (page == 2) {
            reached.complete();
            return gate.future;
          }
          return Future.value(_page(page));
        },
      );
      expect(controller.page, same(accepted));
      expect(controller.refreshing, isTrue);
      await reached.future;
      gate.completeError(ApiException('NETWORK', 'offline'));
      await refresh;
      expect(controller.page, same(accepted));
      expect(controller.refreshError, matches(r'offline（关联号 [0-9A-Z]{6}）'));
      expect(controller.refreshing, isFalse);
      await controller.load(
        1,
        silent: true,
        fetch: () async => throw ApiException('FORBIDDEN', 'denied'),
      );
      expect(controller.page, isNull);
      expect(controller.error, matches(r'denied（关联号 [0-9A-Z]{6}）'));
    },
  );
}
