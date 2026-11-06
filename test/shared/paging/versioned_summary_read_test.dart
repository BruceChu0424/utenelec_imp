import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/paging/versioned_summary_read.dart';

class _SummarySource {
  final requests = <(int, int, String?)>[];
  String? invalid;
  Completer<void>? tail;

  Future<Map<String, dynamic>> read(
    int page,
    int size,
    String? revision,
  ) async {
    requests.add((page, size, revision));
    if (page == 2 && tail != null) await tail!.future;
    if (invalid == 'legacy') return {'items': <Object?>[]};
    if (invalid == 'network' && page == 2) {
      throw ApiException('NETWORK', '尾批失败');
    }
    return {
      'page': invalid == 'fractional-page' ? 1.5 : page,
      'size': size,
      'total': invalid == 'total' && page == 2 ? 202 : 201,
      'totalPages': (201 + size - 1) ~/ size,
      'readScopeVersion': invalid == 'missing-auth'
          ? null
          : invalid == 'auth' && page == 2
          ? 'different-authority'
          : 'auth-A',
      'readSnapshotRevision': invalid == 'revision' && page == 2
          ? 'changed'
          : 'snapshot-A',
      'items': [
        if (!(invalid == 'empty' && page == 1))
          for (var i = (page - 1) * size; i < page * size && i < 201; i++)
            {
              'id': invalid == 'duplicate' && page == 2 ? 'row-0' : 'row-$i',
              'amount': '90071992547409.123456789012345678901234',
              'source': '原来源',
              'currencyId': 'original-currency',
              'quantity': '1.000000000000000000000001',
            },
      ],
    };
  }
}

void main() {
  test(
    'complete page retains authoritative facets totals and separate domain proof',
    () async {
      final source = _SummarySource();
      final snapshot = await readVersionedSummarySnapshot<Map<String, dynamic>>(
        isCurrent: () => true,
        loadPage: (page, size, revision) async => {
          ...await source.read(page, size, revision),
          'readDataVersion': 'shared-domain-A',
          'windowAsOf': '2026-11-06T12:00:00Z',
          'facets': {
            'source': [
              {'value': 'source-id', 'label': '原来源', 'count': 201},
            ],
          },
          'facetNullCounts': {'source': 0},
          'totals': [
            {
              'key': 'amount',
              'label': '原金额',
              'type': 'money',
              'groupKey': 'currencyId',
              'groups': [
                {
                  'unit': '人民币',
                  'identity': 'original-currency',
                  'value': '90071992547409.123456789012345678901234',
                },
              ],
            },
          ],
        },
        decode: (row) => row,
        idOf: (row) => row['id'],
      );
      expect(snapshot.items, hasLength(201));
      expect(snapshot.page.facets['source']!.single.label, '原来源');
      expect(snapshot.page.facets['source']!.single.count, 201);
      expect(snapshot.page.facetNullCounts, {'source': 0});
      expect(
        snapshot.page.totals.single.groups.single.valueText,
        '90071992547409.123456789012345678901234',
      );
      expect(snapshot.dataVersion, 'shared-domain-A');
      expect(snapshot.metadata['windowAsOf'], '2026-11-06T12:00:00Z');
      expect(snapshot.metadata.containsKey('items'), isFalse);
    },
  );
  test(
    'unchanged query revision cannot hide a changed domain version',
    () async {
      final source = _SummarySource();
      await expectLater(
        readCompleteVersionedSummaries<Map<String, dynamic>>(
          isCurrent: () => true,
          loadPage: (page, size, revision) async => {
            ...await source.read(page, size, revision),
            'readDataVersion': page == 1 ? 'domain-A' : 'domain-B',
          },
          decode: (row) => row,
          idOf: (row) => row['id'],
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
        ),
      );
    },
  );
  for (final batch in [100, 1000]) {
    test(
      'complete versioned summary uses bounded read$batch and retains every original scalar unchanged',
      () async {
        final source = _SummarySource();
        final rows = await readCompleteVersionedSummaries<Map<String, dynamic>>(
          loadPage: source.read,
          isCurrent: () => true,
          batchSize: batch,
          decode: (row) => Map<String, dynamic>.unmodifiable(row),
          idOf: (row) => row['id'],
        );
        expect(rows, hasLength(201));
        expect(rows.last['id'], 'row-200');
        expect(
          rows.every(
            (row) =>
                row['amount'] == '90071992547409.123456789012345678901234' &&
                row['source'] == '原来源' &&
                row['currencyId'] == 'original-currency' &&
                row['quantity'] == '1.000000000000000000000001',
          ),
          isTrue,
        );
        expect(source.requests.first.$3, isNull);
        expect(
          source.requests
              .skip(1)
              .every((request) => request.$3 == 'snapshot-A'),
          isTrue,
        );
        expect(source.requests.every((request) => request.$2 == batch), isTrue);
        expect(source.requests, hasLength(batch == 100 ? 3 : 1));
      },
    );
  }
  for (final invalid in [
    'legacy',
    'revision',
    'auth',
    'total',
    'duplicate',
    'empty',
    'network',
    'missing-auth',
    'fractional-page',
  ]) {
    test(
      'versioned summary $invalid is a terminal error, never a complete prefix',
      () async {
        final source = _SummarySource()..invalid = invalid;
        await expectLater(
          readCompleteVersionedSummaries<Map<String, dynamic>>(
            loadPage: source.read,
            isCurrent: () => true,
            decode: (row) => row,
            idOf: (row) => row['id'],
          ),
          throwsA(isA<ApiException>()),
        );
        source.invalid = null;
        final rows = await readCompleteVersionedSummaries<Map<String, dynamic>>(
          loadPage: source.read,
          isCurrent: () => true,
          decode: (row) => row,
          idOf: (row) => row['id'],
        );
        expect(rows, hasLength(201));
      },
    );
  }
  test(
    'scope retirement during a versioned tail cannot publish old data or start another page',
    () async {
      final gate = Completer<void>();
      final source = _SummarySource()..tail = gate;
      var current = true;
      final pending = readCompleteVersionedSummaries<Map<String, dynamic>>(
        loadPage: source.read,
        isCurrent: () => current,
        decode: (row) => row,
        idOf: (row) => row['id'],
      );
      for (var turn = 0; turn < 100 && source.requests.length < 2; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(source.requests, hasLength(2));
      current = false;
      gate.complete();
      await expectLater(pending, throwsA(isA<UiWorkCancelled>()));
      expect(source.requests, hasLength(2));
    },
  );
  for (final invalid in [0, 1001]) {
    test(
      'versioned summary rejects out-of-bound read size$invalid before transport',
      () async {
        final source = _SummarySource();
        await expectLater(
          readCompleteVersionedSummaries<Map<String, dynamic>>(
            loadPage: source.read,
            isCurrent: () => true,
            batchSize: invalid,
            decode: (row) => row,
            idOf: (row) => row['id'],
          ),
          throwsRangeError,
        );
        expect(source.requests, isEmpty);
      },
    );
  }
}
