import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/prepared_page_read.dart';

PagedResult<int> _page(int value, {int rows = 1}) => PagedResult(
  items: List.generate(rows, (index) => value + index),
  page: 1,
  size: rows,
  total: 1000,
  totalPages: 1000,
  readScopeVersion: 'scope-$value',
);

void main() {
  test(
    'an expired freshness window cannot duplicate a pending foreground read',
    () async {
      final reads = PreparedPageRead<int>(freshFor: Duration.zero);
      addTearDown(reads.dispose);
      final pending = Completer<PagedResult<int>>();
      final foreground = reads.read('READY', () => pending.future);
      var speculativeFetches = 0;
      Future<PagedResult<int>> prepare() async => _page(++speculativeFetches);

      for (var attempt = 0; attempt < 3; attempt++) {
        await reads.prepare('READY', prepare);
      }
      expect(speculativeFetches, 0);
      pending.complete(_page(42));
      expect((await foreground).items, [42]);
      await reads.prepare('READY', prepare);
      expect(
        speculativeFetches,
        1,
        reason:
            'With no freshness window, preparation resumes only after completion',
      );
    },
  );

  for (final firstFails in [false, true]) {
    test(
      'one ${firstFails ? 'failed' : 'successful'} concurrent read cannot release another pending read',
      () async {
        final reads = PreparedPageRead<int>(freshFor: Duration.zero);
        addTearDown(reads.dispose);
        final first = Completer<PagedResult<int>>();
        final second = Completer<PagedResult<int>>();
        final firstRead = reads.read('READY', () => first.future);
        final secondRead = reads.read('READY', () => second.future);
        var speculativeFetches = 0;
        Future<PagedResult<int>> prepare() async => _page(++speculativeFetches);
        if (firstFails) {
          final rejected = expectLater(firstRead, throwsStateError);
          first.completeError(StateError('offline'));
          await rejected;
        } else {
          first.complete(_page(1));
          expect((await firstRead).items, [1]);
        }

        await reads.prepare('READY', prepare);
        expect(
          speculativeFetches,
          0,
          reason: 'The second foreground read still owns the query',
        );
        second.complete(_page(2));
        expect((await secondRead).items, [2]);
        await reads.prepare('READY', prepare);
        expect(speculativeFetches, 1);
      },
    );
  }

  test(
    'a queued preparation skips a query already read in the foreground',
    () async {
      final reads = PreparedPageRead<int>();
      addTearDown(reads.dispose);
      final pending = Completer<PagedResult<int>>();
      var fetches = 0;
      final foreground = reads.read('READY', () {
        fetches++;
        return pending.future;
      }, preferPrepared: true);
      await reads.prepare('READY', () async {
        fetches++;
        return _page(-1);
      });
      expect(
        fetches,
        1,
        reason: 'The queue cannot duplicate a visible in-flight read',
      );
      pending.complete(_page(1));
      expect((await foreground).items, [1]);
      await reads.prepare('READY', () async {
        fetches++;
        return _page(-2);
      });
      expect(
        fetches,
        1,
        reason: 'Recently completed foreground reads also suppress tail work',
      );
      expect(
        (await reads.read(
          'READY',
          () async => _page(++fetches),
          preferPrepared: true,
        )).items,
        [2],
        reason:
            'The consumed marker never supplies rows or caches ordinary reads',
      );
    },
  );

  test(
    'consumed-query suppression is bounded and does not suppress other queries',
    () async {
      final reads = PreparedPageRead<int>(maximumQueries: 2);
      addTearDown(reads.dispose);
      for (final key in ['A', 'B', 'C']) {
        await reads.read(key, () async => _page(0));
      }
      var fetches = 0;
      await reads.prepare('B', () async => _page(++fetches));
      expect(fetches, 0);
      await reads.prepare('A', () async => _page(++fetches));
      expect(
        fetches,
        1,
        reason: 'The oldest consumed-query marker was evicted',
      );
      await reads.prepare('D', () async => _page(++fetches));
      expect(fetches, 2, reason: 'An independent query can still prepare');
      expect(
        (await reads.read(
          'A',
          () async => _page(100),
          preferPrepared: true,
        )).items,
        [1],
      );
    },
  );

  test('expired consumed markers permit fresh preparation', () async {
    final reads = PreparedPageRead<int>(freshFor: Duration.zero);
    addTearDown(reads.dispose);
    await reads.read('READY', () async => _page(1));
    var fetches = 0;
    await reads.prepare('READY', () async => _page(++fetches));
    expect(fetches, 1);
  });

  test('a complete prepared page is handed off exactly once', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    final complete = _page(10);
    var fetches = 0;
    Future<PagedResult<int>> fetch() async => _page(++fetches);

    await reads.prepare('DRAFT', () async => complete);
    expect(
      await reads.read('DRAFT', fetch, preferPrepared: true),
      same(complete),
      reason: 'The handoff preserves the complete response and its scope proof',
    );
    expect(fetches, 0);
    expect((await reads.read('DRAFT', fetch, preferPrepared: true)).items, [1]);
    expect(fetches, 1);
  });

  test('one concurrent consumer adopts an in-flight preparation', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    final pending = Completer<PagedResult<int>>();
    var preparedFetches = 0;
    var foregroundFetches = 0;
    final preparation = reads.prepare('READY', () {
      preparedFetches++;
      return pending.future;
    });
    await reads.prepare('READY', () async {
      preparedFetches++;
      return _page(-1);
    });
    Future<PagedResult<int>> foreground() async => _page(++foregroundFetches);
    final adopted = reads.read('READY', foreground, preferPrepared: true);
    final ordinary = reads.read('READY', foreground, preferPrepared: true);
    final result = _page(20);
    pending.complete(result);

    await preparation;
    expect(await adopted, same(result));
    expect((await ordinary).items, [1]);
    expect(preparedFetches, 1);
    expect(foregroundFetches, 1);
  });

  test('refresh retires a completed preparation', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    await reads.prepare('ACTIVE', () async => _page(1));
    var fetches = 0;
    Future<PagedResult<int>> fetch() async => _page(100 + ++fetches);
    expect((await reads.read('ACTIVE', fetch)).items, [101]);
    expect((await reads.read('ACTIVE', fetch, preferPrepared: true)).items, [
      102,
    ]);
    expect(fetches, 2);
  });

  test('late preparation cannot reappear after refresh', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    final pending = Completer<PagedResult<int>>();
    final preparation = reads.prepare('ACTIVE', () => pending.future);
    var fetches = 0;
    Future<PagedResult<int>> fetch() async => _page(100 + ++fetches);
    expect((await reads.read('ACTIVE', fetch)).items, [101]);
    pending.complete(_page(1));
    await preparation;
    expect((await reads.read('ACTIVE', fetch, preferPrepared: true)).items, [
      102,
    ]);
    expect(fetches, 2);
  });

  for (final prepared in [false, true]) {
    test(
      'dispose rejects late ${prepared ? 'adopted' : 'ordinary'} rows',
      () async {
        final reads = PreparedPageRead<int>();
        final pending = Completer<PagedResult<int>>();
        final preparation = prepared
            ? reads.prepare('DRAFT', () => pending.future)
            : Future<void>.value();
        final result = reads.read(
          'DRAFT',
          () => pending.future,
          preferPrepared: prepared,
        );
        final rejected = expectLater(result, throwsStateError);
        reads.dispose();
        pending.complete(_page(1));
        await preparation;
        await rejected;
        var newFetches = 0;
        await expectLater(
          reads.read('DRAFT', () async {
            newFetches++;
            return _page(2);
          }, preferPrepared: true),
          throwsStateError,
        );
        await reads.prepare('DRAFT', () async {
          newFetches++;
          return _page(3);
        });
        expect(newFetches, 0);
      },
    );
  }

  test('a completed speculative failure does not poison the click', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    await reads.prepare('DRAFT', () => Future.error(StateError('offline')));
    var fetches = 0;
    final result = await reads.read('DRAFT', () async {
      fetches++;
      return _page(10);
    }, preferPrepared: true);
    expect(result.items, [10]);
    expect(fetches, 1);
  });

  test(
    'an adopted failure propagates once and the next click retries',
    () async {
      final reads = PreparedPageRead<int>();
      addTearDown(reads.dispose);
      final pending = Completer<PagedResult<int>>();
      final preparation = reads.prepare('DRAFT', () => pending.future);
      var fetches = 0;
      Future<PagedResult<int>> fetch() async => _page(++fetches);
      final adopted = reads.read('DRAFT', fetch, preferPrepared: true);
      final failure = StateError('offline');
      final rejected = expectLater(adopted, throwsA(same(failure)));
      pending.completeError(failure);
      await preparation;
      await rejected;
      expect(
        fetches,
        0,
        reason: 'A foreground failure is not silently retried',
      );
      expect((await reads.read('DRAFT', fetch, preferPrepared: true)).items, [
        1,
      ]);
      expect(fetches, 1);
    },
  );

  test('query capacity evicts the oldest prepared page', () async {
    final reads = PreparedPageRead<int>(maximumQueries: 2);
    addTearDown(reads.dispose);
    await reads.prepare('A', () async => _page(1));
    await reads.prepare('B', () async => _page(2));
    await reads.prepare('C', () async => _page(3));
    expect(
      (await reads.read(
        'A',
        () async => _page(101),
        preferPrepared: true,
      )).items,
      [101],
    );
    expect(
      (await reads.read(
        'B',
        () async => _page(102),
        preferPrepared: true,
      )).items,
      [2],
    );
    expect(
      (await reads.read(
        'C',
        () async => _page(103),
        preferPrepared: true,
      )).items,
      [3],
    );
  });

  test('row budget never truncates or retains an oversized response', () async {
    final reads = PreparedPageRead<int>(maximumRowsPerPage: 2);
    addTearDown(reads.dispose);
    await reads.prepare('fits', () async => _page(10, rows: 2));
    await reads.prepare('large', () async => _page(20, rows: 3));
    var fetches = 0;
    Future<PagedResult<int>> fetch() async {
      fetches++;
      return _page(30, rows: 3);
    }

    expect((await reads.read('fits', fetch, preferPrepared: true)).items, [
      10,
      11,
    ]);
    expect(fetches, 0);
    final large = await reads.read('large', fetch, preferPrepared: true);
    expect(large.items, [30, 31, 32]);
    expect(large.total, 1000);
    expect(fetches, 1);
  });

  test('expired prepared rows are refetched', () async {
    final reads = PreparedPageRead<int>(freshFor: Duration.zero);
    addTearDown(reads.dispose);
    await reads.prepare('DRAFT', () async => _page(1));
    expect(
      (await reads.read(
        'DRAFT',
        () async => _page(2),
        preferPrepared: true,
      )).items,
      [2],
    );
  });

  test(
    'full query values and opaque transport identity isolate handoffs',
    () async {
      final transport = Object();
      final baseline = <String, Object?>{
        'path': '/sales/shipments',
        'page': 1,
        'size': 20,
        'stage': 'DRAFT',
        'originScope': 'CURRENT',
        'sort': 'billNo',
        'order': 'asc',
        'dateFrom': '2026-11-01',
        'columnSearch': <String, String>{'client': 'A'},
      };
      final variations = <Map<String, Object?>>[
        {'path': '/sales/returns'},
        {'page': 2},
        {'size': 50},
        {'stage': 'READY'},
        {'originScope': 'ALL'},
        {'sort': 'createdAt'},
        {'order': 'desc'},
        {'dateFrom': '2026-10-01'},
        {
          'columnSearch': <String, String>{'client': 'B'},
        },
      ];
      for (final variation in variations) {
        final reads = PreparedPageRead<int>();
        await reads.prepare([transport, baseline], () async => _page(1));
        expect(
          (await reads.read(
            [
              transport,
              {...baseline, ...variation},
            ],
            () async => _page(2),
            preferPrepared: true,
          )).items,
          [2],
          reason: 'Different query: $variation',
        );
        expect(
          (await reads.read(
            [transport, Map.of(baseline)],
            () async => _page(3),
            preferPrepared: true,
          )).items,
          [1],
        );
        reads.dispose();
      }
      final reads = PreparedPageRead<int>();
      addTearDown(reads.dispose);
      await reads.prepare([transport, baseline], () async => _page(1));
      expect(
        (await reads.read(
          [Object(), baseline],
          () async => _page(2),
          preferPrepared: true,
        )).items,
        [2],
      );
    },
  );

  test('later mutation cannot rewrite a prepared query key', () async {
    final reads = PreparedPageRead<int>();
    addTearDown(reads.dispose);
    final filters = <String, Object?>{
      'search': <String, String>{'client': 'old'},
      'stages': <String>['DRAFT'],
    };
    await reads.prepare(filters, () async => _page(1));
    (filters['search']! as Map<String, String>)['client'] = 'new';
    (filters['stages']! as List<String>).add('READY');
    expect(
      (await reads.read(
        filters,
        () async => _page(2),
        preferPrepared: true,
      )).items,
      [2],
    );
    expect(
      (await reads.read(
        {
          'stages': ['DRAFT'],
          'search': {'client': 'old'},
        },
        () async => _page(3),
        preferPrepared: true,
      )).items,
      [1],
    );
  });
}
