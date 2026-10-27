import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/components/data_display/paged_read_ahead_policy.dart';
import 'package:uten_imp/components/data_display/paged_read_cache.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

PagedResult<String> _page(int page, {String prefix = 'row', int total = 20}) =>
    PagedResult(
      items: ['$prefix $page a', '$prefix $page b'],
      page: page,
      size: 2,
      total: total,
      totalPages: (total / 2).ceil(),
    );

void main() {
  test('same immutable query retains pages with bounded LRU row storage', () {
    final cache = PagedReadCache<String>(maximumPages: 3, maximumRows: 4);
    cache.bind([
      'goods',
      {'status': 'active'},
    ]);
    cache.accept(_page(1));
    cache.accept(_page(2));
    expect(
      cache.bind([
        'goods',
        {'status': 'active'},
      ]),
      isFalse,
    );
    expect(cache.peek(1)!.items, ['row 1 a', 'row 1 b']);
    cache.accept(_page(3));
    expect(cache.peek(2), isNull);
    expect(cache.length, 2);
    expect(cache.retainedRows, 4);
    cache.bind([
      'goods',
      {'status': 'disabled'},
    ]);
    expect(cache.length, 0);
  });

  test(
    'foreground adopts speculative in-flight page without a second read',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods');
      final gate = Completer<PagedResult<String>>();
      var reads = 0;
      final speculative = cache.read(2, () {
        reads++;
        return gate.future;
      });
      final foreground = cache.read(2, () {
        reads++;
        return Future.value(_page(2));
      });
      expect(identical(speculative, foreground), isTrue);
      gate.complete(_page(2));
      expect((await foreground).page, 2);
      expect(reads, 1);
    },
  );

  test('A to B to A never republishes an earlier private response', () async {
    final cache = PagedReadCache<String>();
    cache.bind(['A', 1]);
    final gate = Completer<PagedResult<String>>();
    final old = cache.read(2, () => gate.future);
    cache.bind(['B', 2]);
    cache.bind(['A', 3]);
    gate.complete(_page(2, prefix: 'old private'));
    await old;
    expect(cache.peek(2), isNull);
    final accepted = await cache.read(2, () async => _page(2, prefix: 'fresh'));
    expect(accepted.items.first, 'fresh 2 a');
  });

  test(
    'a queued preparation never replays a failed speculative page',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('same reader and query');
      cache.accept(_page(1));
      final entered = Completer<void>();
      final failed = Completer<PagedResult<String>>();
      final reads = <int>[];
      final errors = <Object>[];
      Future<PagedResult<String>> fetch(int page) {
        reads.add(page);
        if (reads.length == 1) {
          entered.complete();
          return failed.future;
        }
        return Future.value(_page(page));
      }

      Future<void> prepare() => cache.prefetchPages(
        _page(1),
        [2, 3],
        fetch: fetch,
        isCurrent: () => true,
        onError: errors.add,
      );
      final first = prepare();
      await entered.future;
      final queued = prepare();
      failed.completeError(StateError('temporary page read failure'));
      await Future.wait([first, queued]);
      expect(reads, [
        2,
      ], reason: 'a queued viewport update is not a foreground retry');
      expect(errors, hasLength(1));
      expect(cache.peek(2), isNull);
      await prepare();
      expect(reads, [
        2,
      ], reason: 'repainting the same window cannot replay the failed page');
      expect((await cache.read(2, () => fetch(2))).page, 2);
      await cache.prefetchPages(
        _page(2),
        [3],
        fetch: fetch,
        isCurrent: () => true,
      );
      expect(
        reads,
        [2, 2, 3],
        reason: 'one explicit foreground retry unlocks the healthy successor',
      );
    },
  );

  for (final reset in ['clear', 'scope', 'revision', 'foreground success']) {
    test(
      'speculative failure reset by $reset permits a new preparation',
      () async {
        final cache = PagedReadCache<String>(maximumPages: 1);
        PagedResult<String> versioned(int page, String revision) => PagedResult(
          items: ['row $page'],
          page: page,
          size: 1,
          total: 3,
          totalPages: 3,
          readScopeVersion: revision,
        );
        cache.bind('reader A');
        cache.accept(versioned(1, 'v1'));
        final reads = <int>[];
        var revision = 'v1';
        Future<PagedResult<String>> fetch(int page) async {
          reads.add(page);
          if (reads.length == 1) throw StateError('temporary read failure');
          return versioned(page, revision);
        }

        await cache.prefetchPages(
          versioned(1, revision),
          [2],
          fetch: fetch,
          isCurrent: () => true,
        );
        await cache.prefetchPages(
          versioned(1, revision),
          [2],
          fetch: fetch,
          isCurrent: () => true,
        );
        expect(reads, [2]);
        switch (reset) {
          case 'clear':
            cache.clear();
          case 'scope':
            cache.bind('reader B');
          case 'revision':
            revision = 'v2';
            cache.accept(versioned(1, revision));
          case 'foreground success':
            await cache.read(2, () => fetch(2));
            cache.accept(
              versioned(1, revision),
            ); // Evict 2 to test its retired failure marker.
        }
        await cache.prefetchPages(
          versioned(1, revision),
          [2],
          fetch: fetch,
          isCurrent: () => true,
        );
        expect(reads, reset == 'foreground success' ? [2, 2, 2] : [2, 2]);
        expect(cache.peek(2)!.readScopeVersion, revision);
      },
    );
  }

  for (final stale in [false, true]) {
    test(
      'retired or REQUEST_STALE preparation does not poison a live job: $stale',
      () async {
        final cache = PagedReadCache<String>();
        cache.bind('reader');
        cache.accept(_page(1));
        final entered = Completer<void>();
        final old = Completer<PagedResult<String>>();
        final reads = <int>[];
        var current = true;
        Future<PagedResult<String>> fetch(int page) {
          reads.add(page);
          if (reads.length == 1) {
            entered.complete();
            return old.future;
          }
          return Future.value(_page(page));
        }

        final first = cache.prefetchPages(
          _page(1),
          [2],
          fetch: fetch,
          isCurrent: () => current,
        );
        await entered.future;
        final live = cache.prefetchPages(
          _page(1),
          [2],
          fetch: fetch,
          isCurrent: () => true,
        );
        if (!stale) current = false;
        old.completeError(
          stale
              ? ApiException('REQUEST_STALE', 'retired request')
              : StateError('retired owner'),
        );
        await Future.wait([first, live]);
        expect(reads, [2, 2]);
        expect(cache.peek(2)!.page, 2);
      },
    );
  }

  test('failed speculation uses a bounded recent-page budget', () async {
    final cache = PagedReadCache<String>(maximumPages: 2);
    cache.bind('reader');
    cache.accept(_page(1));
    final reads = <int>[];
    Future<PagedResult<String>> fail(int page) async {
      reads.add(page);
      throw StateError('temporary read failure');
    }

    for (final page in [2, 3, 4]) {
      await cache.prefetchPages(
        _page(1),
        [page],
        fetch: fail,
        isCurrent: () => true,
      );
    }
    await cache.prefetchPages(
      _page(1),
      [3],
      fetch: fail,
      isCurrent: () => true,
    );
    expect(reads, [
      2,
      3,
      4,
    ], reason: 'recent failures still block speculative replay');
    await cache.prefetchPages(
      _page(1),
      [2],
      fetch: fail,
      isCurrent: () => true,
    );
    expect(reads, [
      2,
      3,
      4,
      2,
    ], reason: 'only failures beyond the page budget are retired');
  });

  test(
    'prefetch prepares two following pages and yields before transport',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods');
      cache.accept(_page(2));
      final reads = <int>[];
      final pending = cache.prefetchAdjacent(
        _page(2),
        fetch: (page) async {
          reads.add(page);
          return _page(page);
        },
        isCurrent: () => true,
      );
      expect(reads, isEmpty);
      await pending;
      expect(reads, [3, 4, 1]);
      expect(cache.length, 4);
    },
  );

  test(
    'query retirement stops a speculative chain after its pending page',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods A');
      final gate = Completer<PagedResult<String>>();
      final reads = <int>[];
      final pending = cache.prefetchAdjacent(
        _page(2),
        fetch: (page) {
          reads.add(page);
          return gate.future;
        },
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      cache.bind('goods B');
      gate.complete(_page(3));
      await pending;
      expect(reads, [3]);
      expect(cache.length, 0);
    },
  );

  test(
    'rapid 1 to 50 to 20 navigation runs one speculative transport',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods');
      final gates = <int, Completer<PagedResult<String>>>{};
      final reads = <int>[];
      var active = 0;
      var maximumActive = 0;
      var current = true;
      Future<PagedResult<String>> fetch(int page) {
        reads.add(page);
        active++;
        if (active > maximumActive) maximumActive = active;
        final gate = gates[page] = Completer<PagedResult<String>>();
        return gate.future.whenComplete(() => active--);
      }

      final first = cache.prefetchAdjacent(
        _page(1, total: 200),
        fetch: fetch,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, [2]);
      final middle = cache.prefetchAdjacent(
        _page(50, total: 200),
        fetch: fetch,
        isCurrent: () => current,
      );
      final latest = cache.prefetchAdjacent(
        _page(20, total: 200),
        fetch: fetch,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, [
        2,
      ], reason: 'Retiring a center does not free its physical permit');
      gates[2]!.complete(_page(2, total: 200));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(reads, [
        2,
        21,
      ], reason: 'The intermediate center never starts transport');
      final adopted = cache.read(
        21,
        () => throw StateError('duplicate foreground read'),
      );
      current = false;
      gates[21]!.complete(_page(21, total: 200));
      expect((await adopted).page, 21);
      await Future.wait([first, middle, latest]);
      expect(reads, [
        2,
        21,
      ], reason: 'Stopping does not continue with previous-page reads');
      expect(maximumActive, 1);
    },
  );

  test(
    'scope retirement retains the physical speculative permit until completion',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('reader A');
      final firstGate = Completer<PagedResult<String>>();
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int page) {
        reads.add(page);
        return page == 2 ? firstGate.future : Future.value(_page(page));
      }

      final old = cache.prefetchAdjacent(
        _page(1),
        fetch: fetch,
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      cache.bind('reader B');
      final fresh = cache.prefetchAdjacent(
        _page(5),
        fetch: fetch,
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, [2]);
      firstGate.complete(_page(2));
      await Future.wait([old, fresh]);
      expect(reads, [2, 6, 7, 4, 3]);
      expect(cache.peek(2), isNull);
    },
  );

  test('count changes retire page boundaries from the old cached dataset', () {
    final cache = PagedReadCache<String>();
    cache.bind('goods');
    cache.accept(_page(1));
    cache.accept(_page(2, total: 18));
    expect(cache.peek(1), isNull);
    expect(cache.peek(2)!.total, 18);
  });

  test('count change also retires another page already in flight', () async {
    final cache = PagedReadCache<String>();
    cache.bind('goods');
    cache.accept(_page(1));
    final gate = Completer<PagedResult<String>>();
    final old = cache.read(2, () => gate.future);
    await cache.read(3, () async => _page(3, total: 18));
    gate.complete(_page(2));
    await old;
    expect(cache.peek(2), isNull);
    expect(cache.peek(3)!.total, 18);
  });

  test('write reload to another cached page still uses a fresh read', () async {
    final controller = PagedListController<String>();
    addTearDown(controller.dispose);
    final reads = <int>[];
    Future<PagedResult<String>> fetch(int page) async {
      reads.add(page);
      return _page(page, prefix: 'read ${reads.length}');
    }

    await controller.load(
      1,
      queryScope: 'goods',
      fetch: () => fetch(1),
      fetchPage: fetch,
    );
    await Future<void>.delayed(Duration.zero);
    await controller.load(
      2,
      queryScope: 'goods',
      useCachedPage: true,
      fetch: () => fetch(2),
      fetchPage: fetch,
    );
    await controller.load(
      1,
      queryScope: 'goods',
      fetch: () => fetch(1),
      fetchPage: fetch,
    );
    expect(reads.where((page) => page == 1).length, 2);
  });

  test(
    'controller prefetch never replaces rows or publishes a loading state',
    () async {
      final controller = PagedListController<String>();
      addTearDown(controller.dispose);
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int page) async {
        reads.add(page);
        return _page(page);
      }

      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.load(
        1,
        queryScope: 'goods',
        fetch: () => fetch(1),
        fetchPage: fetch,
      );
      final acceptedNotifications = notifications;
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1, 2, 3]);
      expect(controller.currentPage, 1);
      expect(controller.page!.items.first, 'row 1 a');
      expect(controller.loading, isFalse);
      expect(notifications, acceptedNotifications);
      await controller.load(
        2,
        queryScope: 'goods',
        useCachedPage: true,
        fetch: () => fetch(2),
        fetchPage: fetch,
      );
      expect(reads.where((page) => page == 2).length, 1);
      await controller.load(
        1,
        queryScope: 'goods',
        useCachedPage: true,
        fetch: () => fetch(1),
        fetchPage: fetch,
      );
      expect(reads.where((page) => page == 1).length, 1);
    },
  );

  test(
    'controller same-page refresh and changed filters bypass old cache',
    () async {
      final controller = PagedListController<String>();
      addTearDown(controller.dispose);
      var reads = 0;
      Future<PagedResult<String>> fetch(int page) async {
        reads++;
        return _page(page, total: 2, prefix: 'read $reads');
      }

      await controller.load(
        1,
        queryScope: [
          'goods',
          {'status': 'active'},
        ],
        fetch: () => fetch(1),
        fetchPage: fetch,
      );
      await controller.load(
        1,
        queryScope: [
          'goods',
          {'status': 'active'},
        ],
        fetch: () => fetch(1),
        fetchPage: fetch,
      );
      expect(reads, 2);
      expect(controller.page!.items.first, 'read 2 1 a');
      await controller.load(
        1,
        queryScope: [
          'goods',
          {'status': 'disabled'},
        ],
        fetch: () => fetch(1),
        fetchPage: fetch,
      );
      expect(reads, 3);
    },
  );

  test('speculative access denial clears accepted private rows', () async {
    final controller = PagedListController<String>();
    addTearDown(controller.dispose);
    await controller.load(
      1,
      queryScope: 'private goods',
      fetch: () async => _page(1),
      fetchPage: (_) async => throw ApiException('FORBIDDEN', 'denied'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.page, isNull);
    expect(controller.error, 'denied');
  });

  test('an inactive page does not start adjacent transport', () async {
    final controller = PagedListController<String>();
    addTearDown(controller.dispose);
    var speculativeReads = 0;
    await controller.load(
      1,
      queryScope: 'goods',
      canPrefetch: () => false,
      fetch: () async => _page(1),
      fetchPage: (page) async {
        speculativeReads++;
        return _page(page);
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(speculativeReads, 0);
    expect(controller.page!.page, 1);
  });

  for (final center in [1, 9, 10]) {
    test(
      'preparation near page $center never requests outside the dataset',
      () async {
        final cache = PagedReadCache<String>();
        cache.bind('goods');
        cache.accept(_page(center));
        final reads = <int>[];
        await cache.prefetchAdjacent(
          _page(center),
          fetch: (page) async {
            reads.add(page);
            return _page(page);
          },
          isCurrent: () => true,
        );
        expect(reads, switch (center) {
          1 => [2, 3],
          9 => [10, 8, 7],
          _ => [9, 8],
        });
      },
    );
  }

  test(
    'reverse scrolling prepares previous two pages before following pages',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods');
      cache.accept(_page(6));
      final reads = <int>[];
      await cache.prefetchPages(
        _page(6),
        PagedReadAheadPolicy.around(6, prepend: true),
        fetch: (page) async {
          reads.add(page);
          return _page(page);
        },
        isCurrent: () => true,
      );
      expect(reads, [5, 4, 7, 8]);
      for (final target in [5, 4, 6, 7, 8]) {
        final page = await cache.read(
          target,
          () => throw StateError('cached return started transport'),
        );
        expect(page.page, target);
      }
      expect(reads, [5, 4, 7, 8]);
      expect(cache.length, 5);
    },
  );

  test('a failed second look-ahead page stops the speculative chain', () async {
    final cache = PagedReadCache<String>();
    cache.bind('goods');
    cache.accept(_page(4));
    final reads = <int>[];
    final errors = <Object>[];
    await cache.prefetchAdjacent(
      _page(4),
      fetch: (page) async {
        reads.add(page);
        if (page == 6) throw StateError('offline');
        return _page(page);
      },
      isCurrent: () => true,
      onError: errors.add,
    );
    expect(reads, [5, 6]);
    expect(errors, hasLength(1));
    expect(cache.peek(5)!.items, ['row 5 a', 'row 5 b']);
    expect(cache.peek(6), isNull);
    expect(cache.peek(3), isNull);
  });

  test(
    'preparation remains bounded when a caller supplies the whole dataset',
    () async {
      final cache = PagedReadCache<String>();
      cache.bind('goods');
      final reads = <int>[];
      await cache.prefetchPages(
        _page(1),
        Iterable.generate(10, (index) => index + 1),
        fetch: (page) async {
          reads.add(page);
          return _page(page);
        },
        isCurrent: () => true,
      );
      expect(reads, [1, 2, 3, 4]);
      expect(cache.length, 4);
    },
  );
}
