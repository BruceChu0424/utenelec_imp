import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/quality/repositories/production_fqc_repository.dart';

FqcReportRow _row(String id, {bool lot = true}) {
  final data = <String, dynamic>{
    'id': id,
    'lotId': id,
    'sourceReportId': 'report-$id',
    'sourceReportItemId': 'item-$id',
    'reportedQty': 10,
    'remainingQty': 10,
    'status': 'PENDING',
    'members': <Object>[],
  };
  final row = FqcReportRow(
    lot
        ? ProductionFqcInspection.fromLot(
            ProductionFqcInspectionLot.fromJson(data),
          )
        : ProductionFqcInspection.fromJson(data),
  );
  addTearDown(row.dispose);
  return row;
}

Future<List<ProductionFqcDecisionResult>?> _send(
  List<FqcReportRow> rows,
  _ReportApi api, {
  Future<void> Function()? beforeSend,
}) => FqcReportRow.sendReport(
  rows: rows,
  reason: '外观缺陷',
  repository: ProductionFqcRepository(api),
  guard: (send, reject) async {
    await beforeSend?.call();
    return send();
  },
);

void main() {
  test(
    '20 mixed report rows freeze before one durable guard and one HTTP',
    () async {
      final rows = [for (var i = 0; i < 20; i++) _row('row-$i', lot: i != 19)];
      rows.first.pass.text = '3.25';
      rows.first.fail.text = '1.5';
      rows.first.disposition = 'SCRAP';
      final api = _ReportApi();
      var guards = 0;
      final result = await _send(
        rows,
        api,
        beforeSend: () async {
          guards++;
          expect(api.calls, isEmpty);
          // This is the exact data persisted by FormDraftMixin before dispatch.
          final draft =
              jsonDecode(
                    jsonEncode([for (final row in rows) row.toFormDraft()]),
                  )
                  as List;
          expect(draft, hasLength(20));
          expect(
            draft.cast<Map<String, dynamic>>().every(
              (value) =>
                  value['submission'] != null &&
                  value['submissionState'] == 'unknown',
            ),
            isTrue,
          );
        },
      );
      expect(guards, 1);
      expect(api.calls, hasLength(1));
      expect(result, hasLength(20));
      expect(rows.every((row) => row.completed && !row.selected), isTrue);
      final items = api.calls.single;
      expect(items.first['targetType'], 'LOT');
      expect(items.first['passQty'], 3.25);
      expect(items.first['failQty'], 1.5);
      expect(items.first['dispositionCode'], 'SCRAP');
      expect(items.first['reason'], '外观缺陷');
      expect(items.first.containsKey('decision'), isFalse);
      expect(items.last['targetType'], 'INSPECTION');
      expect(items.last['decision'], 'PASS');
      expect(items.every((item) => item['idempotencyKey'] != null), isTrue);
    },
  );

  test(
    'old frozen single and lot commands keep their keys, nulls and quantities on report retry',
    () async {
      final rows = [_row('lot'), _row('single', lot: false)];
      final originals = [
        {
          'decision': 'PARTIAL',
          'passQty': 2.5,
          'failQty': 1.0,
          'disposition': 'REWORK',
          'reason': '原原因',
        },
        {
          'decision': 'PASS',
          'passQty': null,
          'failQty': null,
          'disposition': null,
          'reason': null,
        },
      ];
      for (var i = 0; i < rows.length; i++) {
        rows[i].restoreFormDraft({
          ...rows[i].toFormDraft(),
          'idempotencyKey': 'old-single-command-$i',
          'submission': originals[i],
          'submissionState': 'unknown',
        });
        rows[i].pass.text = '9'; // Frozen evidence still owns the network body.
      }
      final api = _ReportApi();
      await _send(rows, api);
      expect(api.calls.single.first['idempotencyKey'], 'old-single-command-0');
      expect(api.calls.single.first['passQty'], 2.5);
      expect(api.calls.single.first['reason'], '原原因');
      expect(api.calls.single.last, {
        'targetType': 'INSPECTION',
        'targetId': 'single',
        'idempotencyKey': 'old-single-command-1',
        'decision': 'PASS',
      });
    },
  );

  test('draft failure sends no part of a report', () async {
    final rows = [_row('a'), _row('b')];
    final api = _ReportApi();
    expect(
      await _send(
        rows,
        api,
        beforeSend: () async => throw StateError('disk full'),
      ),
      isNull,
    );
    expect(api.calls, isEmpty);
    expect(
      rows.every(
        (row) =>
            row.submissionState == FqcSubmissionState.notSent &&
            row.submission == null,
      ),
      isTrue,
    );
  });

  test('definite report rejection releases only fresh commands', () async {
    final rows = [_row('fresh'), _row('old')];
    rows.last.freezeSubmission('old');
    rows.last.submissionState = FqcSubmissionState.unknown;
    final original = jsonEncode(rows.last.submission);
    final api = _ReportApi()
      ..error = ApiException('CONFLICT', '数量已变化', httpStatus: 409);
    expect(await _send(rows, api), isNull);
    expect(rows.first.submissionState, FqcSubmissionState.rejected);
    expect(rows.first.submission, isNull);
    expect(rows.last.needsReconciliation, isTrue);
    expect(jsonEncode(rows.last.submission), original);
    expect(rows.any((row) => row.completed), isFalse);
  });

  test(
    'lot commands and inspection events keep separate receipt ID domains',
    () async {
      final rows = [_row('a'), _row('b', lot: false)];
      final api = _ReportApi()..defect = 'duplicate-command';
      expect(await _send(rows, api), hasLength(2));
      expect(rows.every((row) => row.completed), isTrue);
    },
  );

  for (final defect in [
    'missing',
    'duplicate',
    'duplicate-command',
    'reordered',
    'wrong-key',
    'wrong-model',
    'empty-command',
  ]) {
    test(
      'malformed $defect report receipt confirms no row and retries exact body',
      () async {
        final rows = [_row('a'), _row('b')];
        final api = _ReportApi()..defect = defect;
        expect(await _send(rows, api), isNull);
        expect(
          rows.every((row) => row.needsReconciliation && !row.completed),
          isTrue,
        );
        final original = jsonEncode(api.calls.single);
        api.defect = null;
        expect(await _send(rows, api), hasLength(2));
        expect(jsonEncode(api.calls.last), original);
        expect(rows.every((row) => row.completed), isTrue);
      },
    );
  }
}

class _ReportApi extends ApiClient {
  _ReportApi() : super(Dio());
  final calls = <List<Map<String, dynamic>>>[];
  String? defect;
  Exception? error;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path, '/production/quality-inspections/decisions/report');
    final items = [
      for (final item in (body! as Map)['items'] as List)
        Map<String, dynamic>.from(item as Map),
    ];
    calls.add(items);
    if (error != null) throw error!;
    final receipts = [
      for (final item in items)
        <String, dynamic>{
          'targetType': item['targetType'],
          'targetId': item['targetId'],
          'idempotencyKey': item['idempotencyKey'],
          'commandId': 'event-${item['targetId']}',
          'replay': false,
          if (item['targetType'] == 'LOT')
            'lot': {'lotId': item['targetId'], 'members': <Object>[]}
          else
            'inspection': {'id': item['targetId']},
        },
    ];
    switch (defect) {
      case 'missing':
        receipts.removeLast();
      case 'duplicate':
        receipts[1] = receipts.first;
      case 'duplicate-command':
        receipts.last['commandId'] = receipts.first['commandId'];
      case 'reordered':
        return {'items': receipts.reversed.toList()};
      case 'wrong-key':
        receipts.last['idempotencyKey'] = 'foreign';
      case 'wrong-model':
        receipts.last['lot'] = {'lotId': 'foreign'};
      case 'empty-command':
        receipts.last['commandId'] = '';
    }
    return {'items': receipts};
  }
}
