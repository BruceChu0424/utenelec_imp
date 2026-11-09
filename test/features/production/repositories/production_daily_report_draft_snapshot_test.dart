import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/production/models/production_exact_quantity.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/repositories/production_daily_report_draft_snapshot.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;

import '../../../support/complete_read_plan_batches.dart';

String _task(int index) => 'task-${index.toString().padLeft(4, '0')}';

List<({int page, int size})> _pageRequests(_Api api) => [
  for (final request in api.requests)
    (page: request['page'] as int, size: request['size'] as int),
];
Map<String, dynamic> _claim(
  String? segment,
  String? qty, {
  bool surplus = false,
}) => {'executionSegmentId': segment, 'qty': qty, 'actualSurplus': surplus};

class _Api extends ApiClient {
  _Api(this.data) : super(Dio());
  final Map<String, List<Map<String, dynamic>>> data;
  final requests = <Map<String, dynamic>>[];
  int oldReads = 0;
  int? failPage;
  String? mutateSecond;
  bool malformedBody = false;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/production/daily-reports/draft-claims/query');
    final request = Map<String, dynamic>.from(body! as Map);
    requests.add(request);
    final ids = (request['executionSegmentIds'] as List).cast<String>();
    expect(ids.length, inInclusiveRange(1, 100));
    final page = request['page'] as int, size = request['size'] as int;
    // 2026-11-08 完整读取合同：每次请求都是共享阶梯计划在自身 offset 上的
    // 真实页（首批 50，之后 50 → 100 → 200 对齐增长，不超过服务端上限）。
    expect(size, CompleteReadBatchPlan.progressive.sizeAt((page - 1) * size));
    if (page == failPage) throw ApiException('OFFLINE', 'later batch failed');
    if (malformedBody) return {};
    final rows = <Map<String, dynamic>>[];
    for (final entry in data.entries) {
      if (!entry.value.any(
        (claim) => ids.contains(claim['executionSegmentId']),
      )) {
        continue;
      }
      final row = <String, dynamic>{
        'id': entry.key,
        'billNo': 'SR-${entry.key}',
        'billDate': '2026-11-05',
        'status': 0,
        'closed': false,
        'canceled': false,
        'rowVersion': '9007199254740993',
        'draftClaimsVersion': 1,
        'draftClaimsFingerprint': sha256
            .convert(
              utf8.encode(
                jsonEncode([entry.key, '9007199254740993', entry.value]),
              ),
            )
            .toString(),
        'draftClaims': entry.value,
      };
      if (requests.length == 2) {
        if (mutateSecond == 'version') row['rowVersion'] = '9007199254740994';
        if (mutateSecond == 'fingerprint') {
          row['draftClaimsFingerprint'] = 'b' * 64;
        }
        if (mutateSecond == 'schema') row['draftClaimsVersion'] = 2;
        if (mutateSecond == 'missing') row.remove('draftClaimsFingerprint');
      }
      rows.add(row);
    }
    return {
      'items': rows.skip((page - 1) * size).take(size).toList(),
      'page': page,
      'size': size,
      'total': rows.length,
      'totalPages': (rows.length + size - 1) ~/ size,
      'readScopeVersion': 'same-report-authority',
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    oldReads++;
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }
}

Future<ProductionDailyReportDraftSnapshot> _load(
  _Api api,
  Iterable<String> ids,
) => loadProductionDailyReportDraftSnapshot(
  repository: ProductionDailyReportRepository(api),
  executionSegmentIds: ids,
  isCurrent: () => true,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'retired task scope is rejected before enumerating any identity',
    () async {
      final api = _Api({});
      var enumerated = 0;
      final ids = Iterable.generate(1000000, (i) {
        enumerated++;
        return _task(i);
      });
      await expectLater(
        loadProductionDailyReportDraftSnapshot(
          repository: ProductionDailyReportRepository(api),
          executionSegmentIds: ids,
          isCurrent: () => false,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(enumerated, 0);
      expect(api.requests, isEmpty);
    },
  );
  test(
    'large scope normalization yields and cancels before any request',
    () async {
      final api = _Api({});
      var enumerated = 0, current = true;
      final previousObserver = debugUiWorkSliceObserver;
      addTearDown(() => debugUiWorkSliceObserver = previousObserver);
      debugUiWorkSliceObserver = (_, _) => current = false;
      final ids = Iterable.generate(1000000, (i) {
        enumerated++;
        return _task(i);
      });
      await expectLater(
        loadProductionDailyReportDraftSnapshot(
          repository: ProductionDailyReportRepository(api),
          executionSegmentIds: ids,
          isCurrent: () => current,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(enumerated, inInclusiveRange(1, 256));
      expect(api.requests, isEmpty);
    },
  );
  test('scope deduplication preserves input order without sorting', () async {
    final api = _Api({});
    await _load(api, ['b', 'a', 'b']);
    expect(api.requests.single['executionSegmentIds'], ['b', 'a']);
  });
  test(
    'exact large draft sums leave a real positive 0.0001 report quota',
    () async {
      final api = _Api({
        'large': [_claim('current', '90071992547409.1234')],
        'small': [_claim('current', '0.0001')],
      });
      final result = await _load(api, ['current']);
      expect(result.quantities['current'], '90071992547409.1235');
      final preview = ProductionReportPreview(
        remaining: '90071992547409.1236',
        draft: result.quantities['current'],
      );
      expect(preview.remainingText, '0.0001');
      expect(preview.fullyClaimed, isFalse);
      expect(preview.atMostThreshold, isFalse);
    },
  );
  test(
    'few current tasks never scan 1101 unrelated authorized draft headers',
    () async {
      final api = _Api({
        for (var i = 0; i < 1101; i++)
          'report-$i': [_claim(i == 1100 ? 'current' : 'unrelated-$i', '7.25')],
        'multi': [
          _claim('current', '2.5'),
          _claim('other-task', null),
          _claim('current', '99', surplus: true),
        ],
      });
      final result = await _load(api, ['current']);
      expect(api.requests, hasLength(1));
      expect(api.requests.single['executionSegmentIds'], ['current']);
      expect(result.quantities, {'current': '9.75'});
      expect(result.reports['current'], hasLength(2));
      expect(result.reports['other-task']!.single.id, 'multi');
      expect(api.oldReads, 0);
    },
  );
  test(
    'all 1101 current task identities are covered in bounded scope groups without truncation',
    () async {
      final api = _Api({
        for (var i = 0; i < 1101; i++) 'report-$i': [_claim(_task(i), '1')],
      });
      final result = await _load(api, List.generate(1101, _task));
      // Every bounded scope group (≤100 identities) starts at page 1 exactly
      // once; together they cover all 1101 identities in input order.
      final scopes = [
        for (final request in api.requests)
          if (request['page'] == 1)
            (request['executionSegmentIds'] as List).cast<String>(),
      ];
      expect(
        scopes.map((ids) => ids.length),
        everyElement(inInclusiveRange(1, 100)),
      );
      expect(scopes.expand((ids) => ids).toList(), List.generate(1101, _task));
      // Each group then reads its own drafts completely on the shared ladder.
      expect(api.requests, [
        for (final ids in scopes)
          for (final batch in completeReadPlanBatches(ids.length))
            {
              'executionSegmentIds': ids,
              'page': batch.page,
              'size': batch.size,
            },
      ]);
      expect(result.quantities, hasLength(1101));
      expect(result.reports[_task(1100)]!.single.id, 'report-1100');
      expect(api.oldReads, 0);
    },
  );
  test(
    'one current task can reach every real draft batch and source quantities',
    () async {
      final api = _Api({
        for (var i = 0; i < 201; i++) 'report-$i': [_claim('current', '2.5')],
      });
      final result = await _load(api, ['current']);
      expect(_pageRequests(api), completeReadPlanBatches(201));
      expect(result.reports['current'], hasLength(201));
      expect(result.quantities['current'], '502.5');
    },
  );
  test(
    'one multi-task report across ID groups counts each complete claim exactly once',
    () async {
      final api = _Api({
        'shared': [
          _claim(_task(0), '2'),
          _claim(_task(100), '3'),
          _claim(_task(0), '100', surplus: true),
        ],
      });
      final result = await _load(api, List.generate(101, _task));
      expect(api.requests, hasLength(2));
      expect(result.quantities, {_task(0): '2', _task(100): '3'});
      expect(result.reports[_task(0)], hasLength(1));
      expect(result.reports[_task(0)]!.single.rowVersion, '9007199254740993');
    },
  );
  for (final mutation in ['version', 'fingerprint', 'schema', 'missing']) {
    test(
      'conflicting or missing same-header proof rejects the whole query: $mutation',
      () async {
        final api = _Api({
          'shared': [_claim(_task(0), '2'), _claim(_task(100), '3')],
        })..mutateSecond = mutation;
        await expectLater(
          _load(api, List.generate(101, _task)),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'no partial/fallback result',
              isIn(['SNAPSHOT_CHANGED', 'INCOMPLETE_DRAFT_CLAIMS']),
            ),
          ),
        );
        expect(api.oldReads, 0);
      },
    );
  }
  test(
    'a later page failure never returns partially accumulated claims or falls back globally',
    () async {
      final api = _Api({
        for (var i = 0; i < 201; i++) 'report-$i': [_claim('current', '1')],
      })..failPage = 2;
      await expectLater(_load(api, ['current']), throwsA(isA<ApiException>()));
      // The second ladder batch (page 2) fails; nothing is read after it.
      expect(_pageRequests(api), completeReadPlanBatches(201).take(2));
      expect(api.oldReads, 0);
    },
  );
  test('known empty current task set sends no request', () async {
    final api = _Api({});
    final result = await _load(api, []);
    expect(api.requests, isEmpty);
    expect(result.quantities, isEmpty);
    expect(result.reports, isEmpty);
  });
  test(
    'malformed page body is unknown, never a checked empty result',
    () async {
      final api = _Api({})..malformedBody = true;
      await expectLater(_load(api, ['current']), throwsFormatException);
      expect(api.oldReads, 0);
    },
  );
  test(
    'v1 retains original decimal text and explicit nulls and rejects malformed claims',
    () {
      const exact = '0.123456789012345678901234567890';
      final item = ProductionDailyReportListItem.fromJson({
        'id': 'report',
        'draftClaimsVersion': 1,
        'draftClaims': [_claim('segment', exact), _claim(null, null)],
      });
      expect(item.draftClaims!.first.qtyExact, exact);
      expect(item.draftClaims!.last.qtyExact, isNull);
      expect(item.draftClaims!.last.executionSegmentId, isNull);
      for (final value in [
        null,
        {'qty': '1'},
        [_claim('x', 'NaN')],
        ['bad'],
      ]) {
        expect(
          () => ProductionDailyReportListItem.fromJson({
            'id': 'report',
            'draftClaimsVersion': 1,
            'draftClaims': value,
          }),
          throwsFormatException,
        );
      }
      expect(
        ProductionDailyReportListItem.fromJson({'id': 'old'}).draftClaims,
        isNull,
      );
    },
  );
  test(
    'ordinary original report lists keep the compatible default request',
    () async {
      final api = _Api({});
      await ProductionDailyReportRepository(api).list();
      expect(api.oldReads, 1);
      expect(api.requests, isEmpty);
    },
  );
}
