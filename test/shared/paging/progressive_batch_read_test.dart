import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

/// 2026-11-08 user decision: complete reads start with 50 rows, keep reading
/// in aligned batches growing to 200 (50 → 50 → 100 → 200 …) and append each
/// validated batch to the view. No row is read twice; the complete result
/// replaces the growing rows; failures retire them as a whole.

/// An offset-exact server: page `p` of size `s` returns rows (p-1)*s … p*s-1.
class _OffsetServer {
  _OffsetServer(this.total, {this.cap = 1000, this.ignoreSize});
  final int total;
  final int cap;
  // A loader that ignores the requested size always answers with this size.
  final int? ignoreSize;
  final requests = <(int, int)>[];

  Future<PagedResult<String>> load(int page, int size) async {
    requests.add((page, size));
    final effective = ignoreSize ?? (size > cap ? cap : size);
    final start = (page - 1) * effective;
    final end = (start + effective).clamp(0, total);
    return PagedResult<String>(
      items: [for (var i = start; i < end; i++) 'row-$i'],
      page: page,
      size: effective,
      total: total,
      totalPages: total == 0 ? 0 : (total + effective - 1) ~/ effective,
      readScopeVersion: 'scope-a',
    );
  }
}

List<(int, int)> _pairs(List<dynamic> raw) => [
  for (final pair in raw) ((pair as List)[0] as int, pair[1] as int),
];

// The fake clock does not drive the budget's real stopwatch: never yield.
UiWorkBudget _unbounded({bool Function()? isCurrent}) => UiWorkBudget(
  slice: const Duration(days: 1),
  maxItems: 1 << 30,
  isCurrent: isCurrent,
);

void _expectNoRowReadTwice(List<(int, int)> requests, int total) {
  var offset = 0;
  for (final (page, size) in requests) {
    expect((page - 1) * size, offset, reason: 'each batch starts at the next unread row');
    offset += size;
  }
  expect(offset, greaterThanOrEqualTo(total));
}

void main() {
  final vectors =
      jsonDecode(
            File('contracts/complete-read-batch-plan-v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final plans = vectors['plans'] as Map<String, dynamic>;
  CompleteReadBatchPlan planOf(String name) {
    final raw = plans[name] as Map<String, dynamic>;
    return CompleteReadBatchPlan(
      firstBatchSize: raw['firstBatchSize'] as int,
      maxBatchSize: raw['maxBatchSize'] as int,
    );
  }

  group('shared batch-plan vectors (Dart/Java)', () {
    for (final raw in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      final total = raw['total'] as int;
      test('${raw['plan']} total=$total', () async {
        final server = _OffsetServer(total);
        final result = await loadCompletePagedResult<String>(
          loadPage: server.load,
          isCurrent: () => true,
          idOf: (row) => row,
          plan: planOf(raw['plan'] as String),
        );
        expect(result.items, [for (var i = 0; i < total; i++) 'row-$i']);
        expect(result.total, total);
        if (raw['requests'] case final List<dynamic> requests) {
          expect(server.requests, _pairs(requests));
        } else {
          expect(server.requests, hasLength(raw['requestCount'] as int));
          final first = _pairs(raw['firstRequests'] as List);
          expect(server.requests.take(first.length), first);
          expect(server.requests.last, _pairs([raw['lastRequest']]).single);
          final (lastPage, lastSize) = server.requests.last;
          expect(total - (lastPage - 1) * lastSize, raw['lastRows']);
        }
        _expectNoRowReadTwice(server.requests, total);
      });
    }
  });

  test('the default plan reads 50 first, then aligned up to 200', () async {
    final server = _OffsetServer(1000);
    await loadCompletePagedResult<String>(
      loadPage: server.load,
      isCurrent: () => true,
      idOf: (row) => row,
    );
    expect(server.requests.first, (1, 50));
    expect(server.requests.skip(3).every((request) => request.$2 == 200), isTrue);
    _expectNoRowReadTwice(server.requests, 1000);
  });

  test('an explicit batch size keeps one fixed batch', () async {
    final server = _OffsetServer(250);
    await loadCompletePagedResult<String>(
      loadPage: server.load,
      isCurrent: () => true,
      idOf: (row) => row,
      batchSize: 100,
    );
    expect(server.requests, [(1, 100), (2, 100), (3, 100)]);
  });

  test(
    'a smaller server maximum is adopted after one discarded batch',
    () async {
      final server = _OffsetServer(450, cap: 100);
      final result = await loadCompletePagedResult<String>(
        loadPage: server.load,
        isCurrent: () => true,
        idOf: (row) => row,
      );
      expect(result.items, [for (var i = 0; i < 450; i++) 'row-$i']);
      // (2,200) was answered as page 2 of 100: rows already read, so the same
      // offset is read again on the server's own aligned size.
      expect(server.requests, [
        (1, 50),
        (2, 50),
        (2, 100),
        (2, 200),
        (3, 100),
        (4, 100),
        (5, 100),
      ]);
    },
  );

  test('a loader with its own page size continues on that size', () async {
    final server = _OffsetServer(45, ignoreSize: 20);
    final result = await loadCompletePagedResult<String>(
      loadPage: server.load,
      isCurrent: () => true,
      idOf: (row) => row,
    );
    expect(result.items, [for (var i = 0; i < 45; i++) 'row-$i']);
    expect(server.requests, [(1, 50), (2, 20), (3, 20)]);
  });

  test(
    'an unknown-total reader keeps page-by-page continuation on its fixed size',
    () async {
      // A server with its own 40-row pages and no exact total (pickers and
      // column-filter candidates). No offset can be proven, so the read must
      // continue (2,100),(3,100) — never an offset-aligned (2,20) that points
      // at other rows.
      final requests = <(int, int)>[];
      final result = await loadCompletePagedResult<String>(
        loadPage: (page, size) async {
          requests.add((page, size));
          return PagedResult<String>(
            items: [for (var i = 0; i < 40; i++) 'row-${(page - 1) * 40 + i}'],
            page: page,
            size: size,
            total: -1,
            totalPages: 3,
          );
        },
        isCurrent: () => true,
        idOf: (row) => row,
        allowUnknownTotal: true,
      );
      expect(requests, [(1, 100), (2, 100), (3, 100)]);
      expect(result.items, [for (var i = 0; i < 120; i++) 'row-$i']);
    },
  );

  test('a repeated row fails the whole read instead of joining it', () async {
    final server = _OffsetServer(300);
    await expectLater(
      loadCompletePagedResult<String>(
        loadPage: (page, size) async {
          final result = await server.load(page, size);
          if (page == 2 && size == 100) {
            // Data shifted between batches: the previous batch's last row
            // comes back at the head of this one.
            return result.withRows(
              ['row-99', ...result.items.skip(1)],
              page: page,
              size: size,
              total: result.total,
              totalPages: result.totalPages,
            );
          }
          return result;
        },
        isCurrent: () => true,
        idOf: (row) => row,
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
      ),
    );
  });

  test('a changed total between batches fails the whole read', () async {
    final server = _OffsetServer(300);
    await expectLater(
      loadCompletePagedResult<String>(
        loadPage: (page, size) async {
          final result = await server.load(page, size);
          return page == 2 && size == 100
              ? PagedResult<String>(
                  items: result.items,
                  page: page,
                  size: size,
                  total: 301,
                  totalPages: 4,
                  readScopeVersion: 'scope-a',
                )
              : result;
        },
        isCurrent: () => true,
        idOf: (row) => row,
      ),
      throwsA(isA<ApiException>()),
    );
  });

  group('progressive publication', () {
    test('every validated batch publishes the accumulated prefix', () async {
      final server = _OffsetServer(450);
      final published = <PagedResult<String>>[];
      final result = await loadCompletePagedResult<String>(
        loadPage: server.load,
        isCurrent: () => true,
        idOf: (row) => row,
        progressiveInterval: Duration.zero,
        onProgressiveBatch: published.add,
      );
      expect(
        [for (final partial in published) partial.items.length],
        [50, 100, 200, 400],
        reason: 'the last batch is published only as the complete result',
      );
      for (final partial in published) {
        expect(partial.total, 450, reason: 'the server total rides along');
        expect(partial.items, result.items.take(partial.items.length));
      }
      expect(result.items, hasLength(450));
    });

    test('a single-batch result is published only as complete', () async {
      final published = <PagedResult<String>>[];
      final result = await loadCompletePagedResult<String>(
        loadPage: _OffsetServer(30).load,
        isCurrent: () => true,
        idOf: (row) => row,
        onProgressiveBatch: published.add,
      );
      expect(published, isEmpty);
      expect(result.items, hasLength(30));
    });

    test('fast batches are coalesced into the latest prefix', () {
      fakeAsync((async) {
        final published = <int>[];
        PagedResult<String>? complete;
        final gates = <Completer<void>>[];
        final server = _OffsetServer(1000);
        unawaited(
          loadCompletePagedResult<String>(
            loadPage: (page, size) async {
              final gate = Completer<void>();
              gates.add(gate);
              await gate.future;
              return server.load(page, size);
            },
            isCurrent: () => true,
            idOf: (row) => row,
            budget: _unbounded(),
            onProgressiveBatch: (partial) =>
                published.add(partial.items.length),
          ).then((value) => complete = value),
        );
        void answer() {
          gates.last.complete();
          async.flushMicrotasks();
        }

        answer(); // 50 → published at once
        expect(published, [50]);
        answer(); // 100 → within the interval, held
        answer(); // 200 → replaces the held prefix
        expect(published, [50]);
        async.elapse(kProgressiveBatchInterval);
        expect(published, [50, 200]);
        answer(); // 400
        async.elapse(const Duration(milliseconds: 50));
        answer(); // 600
        expect(published, [50, 200]);
        async.elapse(kProgressiveBatchInterval);
        expect(published, [50, 200, 600]);
        answer(); // 800 → held
        answer(); // 1000 → complete; the held prefix is dropped
        async.elapse(kProgressiveBatchInterval);
        expect(published, [50, 200, 600]);
        expect(complete?.items, hasLength(1000));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a retired read publishes nothing more and leaves no timer', () {
      fakeAsync((async) {
        var current = true;
        final published = <int>[];
        Object? failure;
        final gates = <Completer<void>>[];
        final server = _OffsetServer(1000);
        unawaited(
          loadCompletePagedResult<String>(
            loadPage: (page, size) async {
              final gate = Completer<void>();
              gates.add(gate);
              await gate.future;
              return server.load(page, size);
            },
            isCurrent: () => current,
            idOf: (row) => row,
            budget: _unbounded(isCurrent: () => current),
            onProgressiveBatch: (partial) =>
                published.add(partial.items.length),
          ).catchError((Object error) {
            failure = error;
            return const PagedResult<String>(
              items: [],
              page: 1,
              size: 0,
              total: 0,
              totalPages: 0,
            );
          }),
        );
        gates.last.complete();
        async.flushMicrotasks();
        gates.last.complete();
        async.flushMicrotasks();
        expect(published, [50]);
        current = false;
        async.elapse(kProgressiveBatchInterval);
        expect(published, [50], reason: 'a held prefix of a retired read is dropped');
        gates.last.complete();
        async.flushMicrotasks();
        expect(failure, isNotNull);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('shared reader', () {
    test('progressive rows are growing pending rows of the session', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final server = _OffsetServer(450);
      final published = <PagedResult<String>>[];
      final result = await reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => server.load(page, 100),
        fetchPageSized: server.load,
        isCurrent: () => true,
        onProgressiveBatch: (partial) {
          final binding = readWindowBindingOf(partial.items)!;
          expect(binding.pending, isTrue);
          expect(binding.growing, isTrue);
          published.add(partial);
        },
      );
      expect(published, isNotEmpty);
      expect(published.first.items, hasLength(50));
      final complete = readWindowBindingOf(result.items)!;
      expect(complete.growing, isFalse);
      expect(complete.pending, isFalse);
      expect(
        complete.sameSession(readWindowBindingOf(published.last.items)),
        isTrue,
      );
      _expectNoRowReadTwice(server.requests, 450);
    });

    test('a failure after progressive rows retires them as a whole', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final server = _OffsetServer(450);
      final published = <PagedResult<String>>[];
      await expectLater(
        reader.read(
          1,
          scope: 'goods',
          fetchPage: (page) => server.load(page, 100),
          fetchPageSized: (page, size) =>
              size == 200 ? throw StateError('stream broke') : server.load(page, size),
          isCurrent: () => true,
          onProgressiveBatch: published.add,
        ),
        throwsStateError,
      );
      expect(published, isNotEmpty);
      for (final partial in published) {
        expect(
          readWindowBindingOf(partial.items)!.isCurrent,
          isFalse,
          reason: 'a half list is never left as if it were complete',
        );
      }
    });

    test('a superseded request never publishes progressive rows', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final published = <PagedResult<String>>[];
      var current = true;
      final gate = Completer<void>();
      final read = reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => _OffsetServer(450).load(page, 100),
        fetchPageSized: (page, size) async {
          await gate.future;
          return _OffsetServer(450).load(page, size);
        },
        isCurrent: () => current,
        onProgressiveBatch: published.add,
      );
      current = false;
      gate.complete();
      await expectLater(read, throwsA(anything));
      expect(published, isEmpty);
    });

    test('a same-query restart keeps the rows on screen until it has more', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final hold = Completer<void>();
      final first = <int>[];
      final firstRead = reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => _OffsetServer(1000).load(page, 100),
        fetchPageSized: (page, size) async {
          if (size == 200) await hold.future;
          return _OffsetServer(1000).load(page, size);
        },
        isCurrent: () => true,
        progressiveInterval: Duration.zero,
        onProgressiveBatch: (partial) => first.add(partial.items.length),
      );
      await pumpEventQueue();
      expect(first.last, 200);
      final second = <int>[];
      final result = await reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => _OffsetServer(1000).load(page, 100),
        fetchPageSized: _OffsetServer(1000).load,
        isCurrent: () => true,
        progressiveInterval: Duration.zero,
        onProgressiveBatch: (partial) => second.add(partial.items.length),
      );
      expect(second.every((count) => count > 200), isTrue);
      expect(result.items, hasLength(1000));
      hold.complete();
      await expectLater(firstRead, throwsA(anything));
    });

    test('a reread of an accepted result keeps it instead of growing', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final server = _OffsetServer(450);
      await reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => server.load(page, 100),
        fetchPageSized: server.load,
        isCurrent: () => true,
      );
      final published = <PagedResult<String>>[];
      final result = await reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => server.load(page, 100),
        fetchPageSized: server.load,
        isCurrent: () => true,
        onProgressiveBatch: published.add,
      );
      expect(published, isEmpty);
      expect(result.items, hasLength(450));
    });

    test('complete readers in the view zone claim the slot once', () async {
      final published = <PagedResult<Object?>>[];
      final sink = PagedReadProgressiveSink(published.add);
      await PagedReadIntent.progressiveRead(sink, () async {
        expect(PagedReadIntent.currentProgressive, same(sink));
        await Future<void>.delayed(Duration.zero);
        expect(PagedReadIntent.currentProgressive, same(sink));
        expect(sink.claim(), isTrue);
        // An auxiliary complete read in the same zone cannot publish.
        expect(sink.claim(), isFalse);
      });
      expect(PagedReadIntent.currentProgressive, isNull);
    });

    test('a fetchComplete read publishes through the view slot', () async {
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final published = <PagedResult<String>>[];
      final result = await reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) => _OffsetServer(450).load(page, 100),
        fetchComplete: () {
          final sink = PagedReadIntent.currentProgressive;
          expect(sink, isNotNull);
          final claimed = sink!.claim();
          return loadCompletePagedResult<String>(
            loadPage: _OffsetServer(450).load,
            isCurrent: () => true,
            idOf: (row) => row,
            progressiveInterval: Duration.zero,
            onProgressiveBatch: claimed
                ? (partial) => sink.publish(partial as PagedResult<Object?>)
                : null,
          );
        },
        isCurrent: () => true,
        onProgressiveBatch: published.add,
      );
      expect([for (final p in published) p.items.length], [50, 100, 200, 400]);
      expect(result.items, hasLength(450));
    });
  });
}
