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
  'rows': total == 0
      ? <Map<String, dynamic>>[]
      : [
          {'id': '$prefix-$page', 'amount': '999999999999.000001'},
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
    'fresh statistics replace the snapshot without resetting the table schema',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      var stamp = '2026-10-26T00:00:00Z';
      ReportPageRead fresh() => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (query) async => {
          ..._response(query['page'] as int),
          'statisticsGeneratedAt': stamp,
        },
        isCurrent: () => true,
        reusePages: false,
        revalidatingWindow: true,
      );
      final first = await fresh().read(1) as ReportPageSnapshot;
      reader.accept(first);
      final schema = reader.snapshotRevision;
      stamp = '2026-10-26T00:01:00Z';
      final refreshed = await fresh().read(1) as ReportPageSnapshot;
      reader.accept(refreshed);
      expect(refreshed.pageCacheRevision, isNot(first.pageCacheRevision));
      expect(reader.snapshotRevision, schema);
      expect(refreshed.snapshot.statisticsGeneratedAt, stamp);
    },
  );

  test(
    'navigation after a background refresh resumes adjacent preparation',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final reads = <int>[];
      Future<Map<String, dynamic>> fetch(Map<String, dynamic> query) async {
        final page = query['page'] as int;
        reads.add(page);
        return _response(
          page,
          total: 60,
          omitted: query['includeCount'] == false,
        );
      }

      ReportPageRead begin({required bool refresh}) => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: fetch,
        isCurrent: () => true,
        reusePages: !refresh,
        revalidatingWindow: refresh,
      );
      final refresh = begin(refresh: true);
      reader.accept(await refresh.read(1));
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1]);
      final browse = begin(refresh: false);
      reader.accept(await browse.read(2));
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1, 2, 3]);
    },
  );

  test(
    'changed server read proof retires the complete accepted report snapshot',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final session = reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (query) async {
          final page = query['page'] as int;
          return {
            ..._response(page, omitted: query['includeCount'] == false),
            if (page == 2) 'readScopeVersion': 'changed-scope-v2',
          };
        },
        isCurrent: () => true,
        reusePages: false,
        canPrefetch: () => false,
      );
      final old = await session.read(1);
      reader.accept(old);
      await expectLater(
        session.read(2),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
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
    'cached report restores rows, schema, exact totals and page metadata together',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final queries = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> fetch(Map<String, dynamic> query) async {
        queries.add(query);
        return _response(
          query['page'] as int,
          omitted: query['includeCount'] == false,
        );
      }

      ReportPageRead begin(bool cached) => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: fetch,
        isCurrent: () => true,
        reusePages: cached,
      );
      final initial = begin(false);
      final first = await initial.read(1);
      expect(reader.accept(first), isTrue);
      await Future<void>.delayed(Duration.zero);
      final navigation = begin(true);
      expect(identical(initial, navigation), isTrue);
      final second = await navigation.read(2) as ReportPageSnapshot;
      expect(reader.accept(second), isTrue);
      expect(second.snapshot.rows.single['id'], 'row-2');
      expect(second.snapshot.columns.single.label, '金额');
      expect(second.snapshot.facets['amount']!.single.label, '服务端来源');
      expect(
        second.snapshot.totals.single.groups.single.valueText,
        '999999999999.000001',
      );
      expect(second.snapshot.meta['pageProof'], 2);
      expect(second.snapshot.statisticsGeneratedAt, '2026-10-26T00:00:00Z');
      expect(queries.where((q) => q['page'] == 2), hasLength(1));
      expect(queries.last['includeCount'], isFalse);
      final back = await begin(true).read(1) as ReportPageSnapshot;
      expect(back.snapshot.meta['pageProof'], 1);
      expect(queries.where((q) => q['page'] == 1), hasLength(1));
    },
  );

  test(
    'same row count with changed schema retires the old cached page',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final reads = <int>[];
      var schema = '旧金额';
      final session = reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (query) async {
          final page = query['page'] as int;
          reads.add(page);
          if (page == 2) schema = '新金额';
          return _response(
            page,
            schema: schema,
            omitted: query['includeCount'] == false,
          );
        },
        isCurrent: () => true,
        reusePages: false,
      );
      final first = await session.read(1);
      reader.accept(first);
      final before = reader.snapshotRevision;
      await Future<void>.delayed(Duration.zero);
      final second = await session.read(2) as ReportPageSnapshot;
      reader.accept(second);
      expect(reader.snapshotRevision, isNot(before));
      final back = await session.read(1) as ReportPageSnapshot;
      expect(back.snapshot.columns.single.label, '新金额');
      expect(reads.where((page) => page == 1), hasLength(2));
    },
  );

  test(
    'foreground adopts pending speculative response with complete metadata',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final next = Completer<Map<String, dynamic>>();
      var secondReads = 0;
      final session = reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (query) async {
          final page = query['page'] as int;
          if (page == 2) {
            secondReads++;
            return next.future;
          }
          return _response(page);
        },
        isCurrent: () => true,
        reusePages: false,
      );
      reader.accept(await session.read(1));
      await Future<void>.delayed(Duration.zero);
      final foreground = session.read(2);
      expect(secondReads, 1);
      next.complete(_response(2, omitted: true));
      final accepted = await foreground as ReportPageSnapshot;
      expect(reader.accept(accepted), isTrue);
      expect(accepted.snapshot.meta['pageProof'], 2);
      expect(accepted.snapshot.totals, isNotEmpty);
      expect(secondReads, 1);
    },
  );

  test(
    'owner A to B to A and fresh writes cannot revive old snapshots',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      addTearDown(reader.dispose);
      final oldNext = Completer<Map<String, dynamic>>();
      var owner = 1;
      ReportPageRead begin(int epoch, {bool reuse = false}) => reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: epoch,
        fetch: (query) async {
          final page = query['page'] as int;
          if (epoch == 1 && page == 2) return oldNext.future;
          return _response(page, prefix: 'reader-$epoch');
        },
        isCurrent: () => owner == epoch,
        reusePages: reuse,
      );
      final old = begin(1);
      final oldSnapshot = await old.read(1);
      reader.accept(oldSnapshot);
      await Future<void>.delayed(Duration.zero);
      owner = 2;
      reader.accept(await begin(2).read(1));
      owner = 3;
      final fresh = begin(3);
      final accepted = await fresh.read(1) as ReportPageSnapshot;
      reader.accept(accepted);
      oldNext.complete(_response(2, prefix: 'private-old'));
      final next = await fresh.read(2) as ReportPageSnapshot;
      expect(next.snapshot.rows.single['id'], 'reader-3-2');
      expect(reader.accept(oldSnapshot), isFalse);
      await expectLater(old.read(1), throwsStateError);
      final afterWrite = begin(3);
      expect(identical(fresh, afterWrite), isFalse);
      expect(
        (await afterWrite.read(1) as ReportPageSnapshot)
            .snapshot
            .rows
            .single['id'],
        'reader-3-1',
      );
    },
  );

  test(
    'empty retained-window refresh preserves its complete snapshot subtype',
    () async {
      final reader = ReportPagedRead(ReportMetadataReuse());
      final pages = PagedListController<Map<String, dynamic>>();
      addTearDown(reader.dispose);
      addTearDown(pages.dispose);
      final initial = reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (q) async => _response(q['page'] as int),
        isCurrent: () => true,
        reusePages: false,
        canPrefetch: () => false,
      );
      pages.page = await initial.read(2);
      reader.accept(pages.page);
      pages.retainPages([2]);
      final refresh = reader.begin(
        endpoint: '/reports/example',
        query: {'size': 20},
        readerEpoch: 1,
        fetch: (_) async => _response(1, total: 0),
        isCurrent: () => true,
        reusePages: false,
        revalidatingWindow: true,
      );
      await pages.load(
        2,
        silent: true,
        fetch: () => refresh.read(2),
        fetchPage: refresh.read,
      );
      expect(pages.page, isA<ReportPageSnapshot>());
      expect(reader.accept(pages.page), isTrue);
      final snapshot = pages.page! as ReportPageSnapshot;
      expect(snapshot.snapshot.page, 1);
      expect(snapshot.snapshot.total, 0);
      expect(snapshot.snapshot.totals, isEmpty);
      expect(snapshot.snapshot.facets, isEmpty);
    },
  );
}
