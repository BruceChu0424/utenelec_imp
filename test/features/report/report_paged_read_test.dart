import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/features/report/shared/report_metadata_reuse.dart';
import 'package:uten_imp/features/report/shared/report_paged_read.dart';

Map<String, dynamic> _response(
  int page, {
  bool omitted = false,
  String schema = '金额',
  String prefix = 'row',
  int total = 40,
}) => {
  'columns': [
    {'key': 'amount', 'label': schema, 'type': 'money', 'width': 240},
  ],
  'rows': [
    for (var index = 0; index < 20 && (page - 1) * 20 + index < total; index++)
      {'id': '$prefix-$page-$index', 'amount': '999999999999.000001'},
  ],
  'page': page,
  'total': omitted ? -1 : total,
  'totalPages': omitted ? -1 : (total / 20).ceil(),
  'readScopeVersion': 'scope-v1',
  'statisticsGeneratedAt': omitted ? null : '2026-10-26T00:00:00Z',
  'facets': omitted || total == 0
      ? <String, dynamic>{}
      : {
          'amount': [
            {'value': 'source', 'label': '服务端来源', 'count': total},
          ],
        },
  'totals': omitted || total == 0
      ? <Map<String, dynamic>>[]
      : [
          {
            'key': 'amount',
            'label': '金额',
            'type': 'money',
            'groupKey': 'currency',
            'groups': [
              {'unit': '元', 'identity': 'cny', 'value': '999999999999.000001'},
            ],
          },
        ],
  'meta': {'pageProof': page, 'schema': schema},
};

void main() {
  test(
    'fresh statistics replace a complete snapshot without resetting its table schema',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      var stamp = '2026-10-26T00:00:00Z';
      ReportPageRead fresh() => reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        fetch: (query) async => {
          ..._response(query['page'] as int),
          'statisticsGeneratedAt': stamp,
        },
      );
      final first = await fresh().read(1) as ReportPageSnapshot;
      expect(reader.accept(first), isTrue);
      final schema = reader.snapshotRevision;
      stamp = '2026-10-26T00:01:00Z';
      final next = await fresh().read(1) as ReportPageSnapshot;
      expect(reader.accept(next), isTrue);
      expect(next.pageCacheRevision, isNot(first.pageCacheRevision));
      expect(reader.snapshotRevision, schema);
      expect(next.snapshot.statisticsGeneratedAt, stamp);
      expect(next.snapshot.rows.length, 40);
    },
  );
  test(
    'a complete result is reused locally without adjacent preparation and explicit refresh reads the whole query',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final calls = <int>[];
      ReportPageRead begin(bool reuse) => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        reusePages: reuse,
        fetch: (query) async {
          final page = query['page'] as int;
          calls.add(page);
          return _response(
            page,
            total: 60,
            omitted: query['includeCount'] == false,
          );
        },
      );
      final first = begin(false);
      expect(reader.accept(await first.read(1)), isTrue);
      expect(calls, [1, 2, 3]);
      final reuse = begin(true);
      expect(identical(first, reuse), isTrue);
      expect((await reuse.read(99)).items.length, 60);
      await Future<void>.delayed(Duration.zero);
      expect(calls, [1, 2, 3]);
      expect(reader.accept(await begin(false).read(1)), isTrue);
      expect(calls, [1, 2, 3, 1, 2, 3]);
    },
  );
  test(
    'changed server read proof rejects the entire refresh and retires the former report authority',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      var changed = false;
      ReportPageRead begin() => reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        fetch: (query) async {
          final page = query['page'] as int;
          return {
            ..._response(page, omitted: query['includeCount'] == false),
            if (changed && page == 2) 'readScopeVersion': 'changed-scope-v2',
          };
        },
      );
      final old = await begin().read(1);
      expect(reader.accept(old), isTrue);
      changed = true;
      await expectLater(
        begin().read(1),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'READ_SCOPE_CHANGED',
          ),
        ),
      );
      expect(reader.accept(old), isFalse);
      expect(reader.snapshotRevision, isNull);
    },
  );
  test(
    'complete typed report keeps first schema, exact totals, facets and metadata without summing batches',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final queries = <Map<String, dynamic>>[];
      ReportPageRead begin(bool reuse) => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        reusePages: reuse,
        fetch: (query) async {
          queries.add(query);
          return _response(
            query['page'] as int,
            omitted: query['includeCount'] == false,
          );
        },
      );
      final first = await begin(false).read(1) as ReportPageSnapshot;
      expect(reader.accept(first), isTrue);
      final reused = await begin(true).read(2) as ReportPageSnapshot;
      expect(reused.snapshot.rows.length, 40);
      expect(reused.snapshot.rows.first['id'], 'row-1-0');
      expect(reused.snapshot.rows.last['id'], 'row-2-19');
      expect(reused.snapshot.rows, same(reused.items));
      expect(reused.snapshot.columns.single.label, '金额');
      expect(reused.snapshot.facets['amount']!.single.label, '服务端来源');
      expect(
        reused.snapshot.totals.single.groups.single.valueText,
        '999999999999.000001',
      );
      expect(reused.snapshot.meta['pageProof'], 1);
      expect(reused.snapshot.statisticsGeneratedAt, '2026-10-26T00:00:00Z');
      expect(queries.length, 2);
      expect(queries.last['includeCount'], isFalse);
    },
  );
  test(
    'a schema change inside internal batches is rejected and a stable fresh schema can recover',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      var stable = false;
      ReportPageRead begin() => reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        fetch: (query) async {
          final page = query['page'] as int;
          return _response(
            page,
            schema: stable || page == 2 ? '新金额' : '旧金额',
            omitted: query['includeCount'] == false,
          );
        },
      );
      await expectLater(begin().read(1), throwsA(isA<ApiException>()));
      stable = true;
      final recovered = await begin().read(1) as ReportPageSnapshot;
      expect(reader.accept(recovered), isTrue);
      expect(recovered.snapshot.columns.single.label, '新金额');
      expect(recovered.snapshot.rows.length, 40);
    },
  );
  test(
    'concurrent consumers adopt the one complete in-flight result with its metadata',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final held = Completer<Map<String, dynamic>>(),
          started = Completer<void>();
      var secondReads = 0;
      final session = reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        fetch: (query) async {
          final page = query['page'] as int;
          if (page == 2) {
            secondReads++;
            started.complete();
            return held.future;
          }
          return _response(page);
        },
      );
      final first = session.read(1);
      await started.future;
      final adopt = session.read(2);
      expect(secondReads, 1);
      held.complete(_response(2, omitted: true));
      final a = await first as ReportPageSnapshot;
      final b = await adopt as ReportPageSnapshot;
      expect(reader.accept(a), isTrue);
      expect(b.snapshot.rows.length, 40);
      expect(b.snapshot.meta['pageProof'], 1);
      expect(b.snapshot.totals, isNotEmpty);
      expect(secondReads, 1);
    },
  );
  test(
    'owner A to B to A and a fresh write cannot revive old complete snapshots',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      var owner = 1, hold = false;
      final held = Completer<Map<String, dynamic>>(),
          started = Completer<void>();
      ReportPageRead begin(int epoch) => reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: epoch,
        isCurrent: () => owner == epoch,
        fetch: (query) async {
          final page = query['page'] as int;
          if (epoch == 1 && hold && page == 2) {
            started.complete();
            return held.future;
          }
          return _response(
            page,
            prefix: 'reader-$epoch',
            omitted: query['includeCount'] == false,
          );
        },
      );
      final oldSnapshot = await begin(1).read(1);
      reader.accept(oldSnapshot);
      hold = true;
      final old = begin(1).read(1);
      final rejected = expectLater(old, throwsA(anything));
      await started.future;
      owner = 2;
      reader.accept(await begin(2).read(1));
      owner = 3;
      final fresh = begin(3);
      final current = await fresh.read(1) as ReportPageSnapshot;
      reader.accept(current);
      held.complete(_response(2, prefix: 'private-old', omitted: true));
      await rejected;
      expect(current.snapshot.rows.first['id'], 'reader-3-1-0');
      expect(reader.accept(oldSnapshot), isFalse);
      final afterWrite = begin(3);
      expect(identical(fresh, afterWrite), isFalse);
      expect((await afterWrite.read(1)).items.length, 40);
    },
  );
  test(
    'an empty whole-query refresh preserves the report subtype and clears old totals and facets',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      final pages = PagedListController<Map<String, dynamic>>();
      addTearDown(reader.dispose);
      addTearDown(pages.dispose);
      ReportPageRead begin(int total) => reader.begin(
        reusePages: false,
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        isCurrent: () => true,
        fetch: (query) async => _response(
          query['page'] as int,
          total: total,
          omitted: query['includeCount'] == false,
        ),
      );
      final initial = begin(40);
      pages.page = await initial.read(1);
      reader.accept(pages.page);
      final fresh = begin(0);
      await pages.load(
        1,
        silent: true,
        fetch: () => fresh.read(1),
        fetchPage: fresh.read,
      );
      expect(pages.page, isA<ReportPageSnapshot>());
      expect(reader.accept(pages.page), isTrue);
      final result = pages.page as ReportPageSnapshot;
      expect(result.snapshot.rows, isEmpty);
      expect(result.snapshot.page, 1);
      expect(result.snapshot.total, 0);
      expect(result.snapshot.totals, isEmpty);
      expect(result.snapshot.facets, isEmpty);
    },
  );
}
