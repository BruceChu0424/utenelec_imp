import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_data.dart';
import 'package:uten_imp/features/report/shared/report_metadata_reuse.dart';

ReportData _response({
  int page = 1,
  bool omitted = false,
  bool empty = false,
  String? scopeVersion = 'fixture-v1',
}) => parseReportResponse({
  'readScopeVersion': scopeVersion,
  'columnSearchKeys': ['amount'],
  'statisticsGeneratedAt': omitted ? null : '2026-10-25T00:00:00Z',
  'columns': [
    {'key': 'amount', 'label': '金额', 'type': 'money'},
  ],
  'rows': [
    {'id': 'row-$page', 'amount': '0.000000000000000001'},
  ],
  'page': page,
  'total': omitted ? -1 : (empty ? 0 : 51),
  'totalPages': omitted ? -1 : (empty ? 0 : 2),
  'facets': omitted || empty
      ? <String, dynamic>{}
      : {
          'currency': [
            {'value': 'usd', 'label': '美元', 'count': 51},
          ],
        },
  'totals': omitted || empty
      ? <dynamic>[]
      : [
          {
            'key': 'amount',
            'label': '金额',
            'type': 'money',
            'groupKey': 'currency',
            'groups': [
              {'unit': '美元', 'identity': 'usd', 'value': '999999999999.01'},
              {'unit': '美元', 'identity': 'other-usd', 'value': '0.02'},
            ],
          },
        ],
  'meta': {'pageProof': page},
}, page);

void main() {
  test(
    'external writes never relabel a retained snapshot and its lease forces fresh statistics',
    () {
      var now = 0;
      final cache = ReportMetadataReuse(monotonicMicros: () => now);
      final first = cache.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
      )..merge(_response());
      cache.accept(first);
      final next = cache.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
        reuseMetadata: true,
      );
      expect(next.queryForPage(2)['includeTotals'], isFalse);
      final retained = next.merge(_response(page: 2, omitted: true));
      expect(retained.statisticsGeneratedAt, '2026-10-25T00:00:00Z');
      expect(retained.columnSearchKeys, {'amount'});
      cache.accept(next);
      now = 30000000;
      final expired = cache.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
        reuseMetadata: true,
      );
      expect(expired.queryForPage(2)['includeCount'], isNull);
      final refreshed = expired.merge(_response(empty: true));
      expect(refreshed.total, 0);
      expect(refreshed.totals, isEmpty);
    },
  );
  test(
    'unknown legacy versions never reuse metadata and changed scope cannot adopt old aggregates',
    () {
      final legacy = ReportMetadataReuse();
      final first = legacy.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
      )..merge(_response(scopeVersion: null));
      legacy.accept(first);
      final page = legacy.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
        reuseMetadata: true,
      );
      expect(page.queryForPage(2)['includeCount'], isNull);
      final cache = ReportMetadataReuse();
      final accepted = cache.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
      )..merge(_response());
      cache.accept(accepted);
      final changed = cache.begin(
        endpoint: '/sales/reports/ORDER/detail',
        query: {},
        readerEpoch: 0,
        reuseMetadata: true,
      );
      expect(changed.queryForPage(2)['readScopeVersion'], 'fixture-v1');
      expect(changed.queryForPage(2)['metadataReuse'], isTrue);
      expect(
        () =>
            changed.merge(_response(omitted: true, scopeVersion: 'fixture-v2')),
        throwsStateError,
      );
      expect(
        () => changed.merge(_response(scopeVersion: 'fixture-v2')),
        throwsStateError,
      );
    },
  );
  const query = {
    'dateFrom': '2026-10-01',
    'size': 50,
    'f.clientId': 'client-a',
  };

  ReportMetadataRead begin(
    ReportMetadataReuse cache, {
    String endpoint = '/sales/reports/ORDER/detail',
    Map<String, dynamic> parameters = query,
    int epoch = 0,
    bool reuse = false,
  }) => cache.begin(
    endpoint: endpoint,
    query: parameters,
    readerEpoch: epoch,
    reuseMetadata: reuse,
  );

  test(
    'rows-only page keeps exact grouped server facts and fresh page metadata',
    () {
      final cache = ReportMetadataReuse();
      final first = begin(cache);
      expect(first.queryForPage(1)['includeCount'], isNull);
      final full = first.merge(_response());
      cache.accept(first);
      final next = begin(cache, reuse: true);
      expect(next.queryForPage(2), containsPair('includeCount', false));
      expect(next.queryForPage(2), containsPair('includeFacets', false));
      expect(next.queryForPage(2), containsPair('includeTotals', false));
      final page = next.merge(_response(page: 2, omitted: true));
      expect(page.total, 51);
      expect(page.totalPages, 2);
      expect(page.page, 2);
      expect(page.rows.single['id'], 'row-2');
      expect(page.meta['pageProof'], 2);
      expect(page.facets, same(full.facets));
      expect(page.totals, same(full.totals));
      expect(page.totals.single.groups.map((group) => group.valueText), [
        '999999999999.01',
        '0.02',
      ]);
      expect(page.totals.single.groups.map((group) => group.identity), [
        'usd',
        'other-usd',
      ]);
    },
  );

  test('query dimensions and reader epoch prevent metadata reuse', () {
    for (final changed in [
      {'endpoint': '/sales/reports/RETURN/detail'},
      {'epoch': 2},
      {
        'parameters': {...query, 'f.clientId': 'client-b'},
      },
      {
        'parameters': {...query, 'size': 100},
      },
      {
        'parameters': {...query, 'sort': 'amount', 'order': 'desc'},
      },
      {
        'parameters': {...query, 'direction': 'AP'},
      },
      {
        'parameters': {...query, 'dateFrom': '2025-01-01'},
      },
    ]) {
      final cache = ReportMetadataReuse();
      final accepted = begin(cache)..merge(_response());
      cache.accept(accepted);
      final read = begin(
        cache,
        reuse: true,
        endpoint:
            changed['endpoint'] as String? ?? '/sales/reports/ORDER/detail',
        epoch: changed['epoch'] as int? ?? 0,
        parameters: changed['parameters'] as Map<String, dynamic>? ?? query,
      );
      expect(read.queryForPage(2)['includeCount'], isNull, reason: '$changed');
    }
  });

  test('refresh fetches full metadata once within its private page window', () {
    final cache = ReportMetadataReuse();
    final first = begin(cache)..merge(_response());
    cache.accept(first);
    final refresh = begin(cache);
    expect(refresh.queryForPage(1)['includeCount'], isNull);
    refresh.merge(_response());
    expect(refresh.queryForPage(2)['includeCount'], isFalse);
    refresh.merge(_response(page: 2, omitted: true));
    // Simulate failure before publication: no accept(refresh).
    final retry = begin(cache, reuse: true);
    expect(retry.queryForPage(2)['includeCount'], isNull);
  });

  test(
    'superseded candidates and reader invalidation cannot repopulate cache',
    () {
      final cache = ReportMetadataReuse();
      final old = begin(cache)..merge(_response());
      begin(cache, epoch: 1);
      cache.accept(old);
      expect(begin(cache, reuse: true).queryForPage(2)['includeCount'], isNull);
      final accepted = begin(cache)..merge(_response());
      cache.accept(accepted);
      cache.invalidate();
      cache.accept(accepted);
      expect(begin(cache, reuse: true).queryForPage(2)['includeCount'], isNull);
    },
  );

  test(
    'ALL responses replace old metadata including authoritative emptiness',
    () {
      final cache = ReportMetadataReuse();
      final first = begin(cache)..merge(_response());
      cache.accept(first);
      final next = begin(cache, reuse: true);
      final fresh = _response(empty: true);
      expect(next.merge(fresh), same(fresh));
      cache.accept(next);
      final last = begin(cache, reuse: true).merge(_response(omitted: true));
      expect(last.total, 0);
      expect(last.totalPages, 0);
      expect(last.facets, isEmpty);
      expect(last.totals, isEmpty);
    },
  );

  test(
    'unexpected omission has no local substitute or inferred page total',
    () {
      final read = begin(ReportMetadataReuse());
      expect(() => read.merge(_response(omitted: true)), throwsStateError);
    },
  );
}
