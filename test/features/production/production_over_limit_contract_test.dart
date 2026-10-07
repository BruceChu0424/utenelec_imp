import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/notice/widgets/review_pending_dialog.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_daily_report_create_request.dart';
import 'package:uten_imp/features/production/repositories/production_over_limit_repository.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final writes = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastQuery;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    lastQuery = query;
    return {
      'items': [
        {
          'id': 'case',
          'rowVersion': 7,
          'status': 'PENDING',
          'overLimitQty': 100,
        },
      ],
      'page': 2,
      'size': 20,
      'total': 23,
      'totalPages': 2,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(Map<String, dynamic>.from(body! as Map));
    return {
      'id': 'case',
      'status': 'ACCEPTED',
      'rowVersion': 8,
      'canDecide': false,
    };
  }
}

void main() {
  test(
    '1200 actual and 1100 allowance retain 100 for disposition without changing demand',
    () {
      final row = DailyGridRow()
        ..maxReportQty = 1000
        ..remainingActualSurplusQty = 100
        ..allowActualOverproduction = true
        ..qty.text = '1200'
        ..overLimitReason.text = '同批生产多出';
      addTearDown(row.dispose);
      expect(row.reportQtyCap, 1100);
      expect(row.estimatedOverLimitQty, 100);
      expect(row.maxReportQty, 1000);
      expect(row.qty.text, '1200');
      final copied = row.clone();
      addTearDown(copied.dispose);
      expect(copied.overLimitReason.text, '同批生产多出');
      expect(copied.qty.text, '1200');
      row.fqcRecoveryAuthorizationId = 'recovery';
      expect(row.canRecordOverLimit, isFalse);
      expect(row.reportQtyCap, 1000);
      row.fqcRecoveryAuthorizationId = null;
      row.supplementProofId = 'legacy-proof';
      expect(row.canRecordOverLimit, isFalse);
      final fixedCopy = row.clone();
      addTearDown(fixedCopy.dispose);
      expect(fixedCopy.overLimitReason.text, isEmpty);
      expect(fixedCopy.qty.text, isEmpty);
    },
  );

  test(
    'batch editing restores the reason from over-limit slice and only one total',
    () {
      final group = ProductionDailyReportInputGroup([
        ProductionDailyReportItem.fromJson({
          'id': 'demand',
          'qty': 1000,
          'outputBatchId': 'batch',
          'outputBatchQty': 1200,
          'outputKind': 'PLANNED',
        }),
        ProductionDailyReportItem.fromJson({
          'id': 'tolerance',
          'qty': 100,
          'publicOutput': true,
          'actualSurplus': true,
          'outputBatchId': 'batch',
          'outputBatchQty': 1200,
          'outputKind': 'ACTUAL_SURPLUS',
        }),
        ProductionDailyReportItem.fromJson({
          'id': 'over',
          'qty': 100,
          'publicOutput': true,
          'overLimit': true,
          'outputBatchId': 'batch',
          'outputBatchQty': 1200,
          'outputKind': 'OVER_LIMIT',
          'overLimitReason': '同批多出',
          'dispositionId': 'case',
        }),
      ]);
      expect(group.qty, 1200);
      expect(group.overLimitReason, '同批多出');
      expect(group.items.last.dispositionId, 'case');
      expect(group.items.last.outputKindLabel, '超限产出');
    },
  );

  test(
    'reason participates in create proof without changing older empty payload hashes',
    () {
      Map<String, dynamic> body([String? reason]) => {
        'items': [
          {'qty': 1200, 'overLimitReason': ?reason},
        ],
      };
      expect(
        dailyReportCreateRequestHash(body()),
        dailyReportCreateRequestHash(body('')),
      );
      expect(
        dailyReportCreateRequestHash(body()),
        dailyReportCreateRequestHash(body('  ')),
      );
      expect(
        dailyReportCreateRequestHash(body('同批多出')),
        isNot(dailyReportCreateRequestHash(body('实际计数更正'))),
      );
    },
  );

  test(
    'decision retry binds version action and reason without modifying output quantity',
    () async {
      final api = _Api();
      final repo = ProductionOverLimitRepository(api);
      const source = ProductionOverLimitDisposition({
        'id': 'case',
        'rowVersion': 7,
        'status': 'PENDING',
      });
      await repo.decide(source, action: 'ACCEPT_PUBLIC', reason: ' 本批留作备货 ');
      await repo.decide(source, action: 'ACCEPT_PUBLIC', reason: '本批留作备货');
      expect(api.writes.first, api.writes.last);
      expect(api.writes.first['expectedVersion'], 7);
      expect(api.writes.first['reason'], '本批留作备货');
      expect(api.writes.first.containsKey('qty'), isFalse);
      await repo.decide(source, action: 'HOLD', reason: '本批留作备货');
      expect(
        api.writes.last['idempotencyKey'],
        isNot(api.writes.first['idempotencyKey']),
      );
      final page = await repo.list(page: 2);
      expect(page.items.single.overLimitQty, '100');
      expect(page.total, 23);
      expect(page.page, 2);
      expect(api.lastQuery, {'status': 'PENDING', 'page': 2, 'size': 20});
    },
  );

  test(
    'plan queue and scoped detail have separate view gates with the same permission surface',
    () {
      expect(requiredAnyPermFor(RouteName.productionOverLimitDispositions), [
        Perm.productionPlanApprove,
      ]);
      final detail = RoutePath.productionOverLimitDisposition('case');
      expect(
        requiredAnyPermFor(detail),
        containsAll([
          Perm.productionPlanView,
          Perm.productionExecutionView,
          Perm.productionDailyReportView,
        ]),
      );
      expect(pagePermissionScopeFor(detail)?.surfaceKey, 'production.plan');
      expect(
        workbenchRouteFor('PRODUCTION_OVER_LIMIT_PENDING'),
        RouteName.productionOverLimitDispositions,
      );
    },
  );
}
