// ADR-148: 品质批量审批按实物批办理。检查单里一批实物(需求 1000 + 实际超产 100)只占一行,
// 显示服务端算好的拆分; 勾选提交时带上批内各份的检查任务(服务端整批全合格), 不会只放行勾到的一份。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _sheetId = '20000000-0000-0000-0000-000000000001';
const _lotId = '20000000-0000-0000-0000-000000000009';
const _demand = '20000000-0000-0000-0000-000000000011';
const _surplus = '20000000-0000-0000-0000-000000000012';

class _Api extends ApiClient {
  _Api() : super(Dio());

  Map<String, dynamic>? passAllBody;

  Map<String, dynamic> _slice(String id, int rank, String kind, num qty) => {
    'id': id,
    'sourceReportId': 'report-1',
    'sourceReportItemId': 'item-$rank',
    'reportNo': 'RB20261005001',
    'planNo': 'SJ20261005001',
    'goodsCode': 'UK01',
    'goodsName': 'UK开关滑杆',
    'unitName': '个',
    'reportedQty': qty,
    'passedQty': 0,
    'failedQty': 0,
    'remainingQty': qty,
    'authorizedInboundQty': 0,
    'status': 'PENDING',
    'createdAt': '2026-10-05T01:00:00Z',
    'updatedAt': '2026-10-05T01:00:00Z',
    'sheetId': _sheetId,
    'sheetNo': 'PZ20261005001',
    'lotId': _lotId,
    'sliceRank': rank,
    'sliceKind': kind,
    'lotSliceCount': 2,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.productionQualityInspectionSheet(_sheetId));
    return {
      'sheet': {
        'id': _sheetId,
        'sheetNo': 'PZ20261005001',
        'itemCount': 2,
        'activeCount': 2,
        'status': 'ACTIVE',
        'createdAt': '2026-10-05T01:00:00Z',
      },
      'inspections': [
        _slice(_demand, 0, 'DEMAND', 1000),
        _slice(_surplus, 2, 'ACTUAL_SURPLUS', 100),
      ],
      'lots': [
        {
          'lotId': _lotId,
          'sourceReportId': 'report-1',
          'reportNo': 'RB20261005001',
          'planNo': 'SJ20261005001',
          'goodsCode': 'UK01',
          'goodsName': 'UK开关滑杆',
          'unitName': '个',
          'reportedQty': 1100,
          'passedQty': 0,
          'failedQty': 0,
          'remainingQty': 1100,
          'demandQty': 1000,
          'publicQty': 0,
          'actualSurplusQty': 100,
          'splitText': '需求 1000 · 实际超产 100',
          'status': 'PENDING',
          'members': [
            {
              'inspectionId': _demand,
              'sourceReportItemId': 'item-0',
              'sliceRank': 0,
              'kind': 'DEMAND',
              'reportedQty': 1000,
              'remainingQty': 1000,
              'status': 'PENDING',
            },
            {
              'inspectionId': _surplus,
              'sourceReportItemId': 'item-2',
              'sliceRank': 2,
              'kind': 'ACTUAL_SURPLUS',
              'reportedQty': 100,
              'remainingQty': 100,
              'status': 'PENDING',
            },
          ],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path, ApiEndpoints.productionQualityInspectionPassAll);
    passAllBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    return {
      'batchId': 'b1',
      'replay': false,
      'processedCount': 2,
      'items': <Object>[],
    };
  }
}

void main() {
  testWidgets('one physical lot is one row and passing it sends every slice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _Api();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: TextButton(
              key: const Key('open-approval'),
              onPressed: () => context.push('/approve'),
              child: const Text('打开审批'),
            ),
          ),
        ),
        GoRoute(
          path: '/approve',
          builder: (context, state) => QualityBatchApprovalPage(
            selection: QualityBatchApprovalSelection(
              sheets: [
                ProductionFqcInspectionSheet(
                  id: _sheetId,
                  sheetNo: 'PZ20261005001',
                  itemCount: 2,
                  activeCount: 2,
                  status: 'ACTIVE',
                  createdAt: DateTime.utc(2026, 10, 5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-approval')));
    await tester.pumpAndSettle();

    // 一批一行: 不再有「UK开关滑杆 1000」「UK开关滑杆 100」两行可以分开勾。
    expect(find.text('UK开关滑杆'), findsOneWidget);
    expect(find.text('需求 1000 · 实际超产 100'), findsOneWidget);
    expect(find.text('勾选即整批全部合格'), findsOneWidget);

    await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect((api.passAllBody?['inspectionIds'] as List?)?.toSet(), {
      _demand,
      _surplus,
    });
    expect(
      ProviderScope.containerOf(
        tester.element(find.byKey(const Key('open-approval'))),
        listen: false,
      ).read(appNotificationProvider).map((n) => n.message),
      contains(contains('自制产成品全部合格 1 批')),
    );
  });
}
