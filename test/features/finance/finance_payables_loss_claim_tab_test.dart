import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/subcontract_loss_claim.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/subcontract_loss_claim_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/filter_segment_tap.dart';

void main() {
  testWidgets('claim-only user opens the embedded excess-loss workspace', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _ClaimListApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subcontractLossClaimRepositoryProvider.overrideWithValue(
            SubcontractLossClaimRepository(api),
          ),
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          settlementMethodOptionsProvider.overrideWith((_) async => const []),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractLossClaimView,
          }),
        ],
        child: const MaterialApp(home: FinancePayablesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('委外超耗责任 (1)'), findsOneWidget);
    expect(find.text('SW-001'), findsOneWidget);
    expect(find.text('待处理'), findsWidgets);
    expect(find.text('生成付款单'), findsNothing);

    final table = tester
        .widget<MasterDataTableView<SubcontractLossClaimSummary>>(
          find.byWidgetPredicate(
            (widget) =>
                widget is MasterDataTableView<SubcontractLossClaimSummary>,
          ),
        );
    final columnKeys = {for (final column in table.columns) column.key};
    expect(
      columnKeys,
      containsAll(<String>{'actualLossQty', 'allowedLossQty', 'excessLossQty'}),
    );
    expect(columnKeys, isNot(contains('lossBookValueLocal')));
    expect(columnKeys, isNot(contains('claimAmountLocal')));
    await selectFilterSegment(tester, '待处理');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], 'OPEN');
    final reads = api.listQueries.length;
    final facetReads = api.facetQueries.length;
    await selectFilterSegment(tester, '待处理');
    await tester.pumpAndSettle();
    expect(api.listQueries.length, reads);
    expect(api.listQueries.last['status'], 'OPEN');
    expect(api.listQueries.last['page'], 1);
    expect(api.facetQueries.length, facetReads);
    expect(api.facetQueries.last['status'], 'OPEN');
    await selectFilterSegment(tester, '全部');
    await tester.pumpAndSettle();
    expect(api.listQueries.last.containsKey('status'), isFalse);
    expect(api.facetQueries.last.containsKey('status'), isFalse);
    expect(find.text('生成付款单'), findsNothing);
  });
}

class _ClaimListApi extends ApiClient {
  _ClaimListApi() : super(Dio());
  final listQueries = <Map<String, dynamic>>[];
  final facetQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/subcontract-loss-claims/facets') {
      facetQueries.add({...?query});
      return const {'wasteBillNo': <Map<String, dynamic>>[]};
    }
    if (path != '/finance/subcontract-loss-claims') {
      throw StateError('Unexpected read: $path');
    }
    listQueries.add({...?query});
    return <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'case-1',
          'wasteId': 'waste-1',
          'wasteBillNo': 'SW-001',
          'supplierId': 'supplier-1',
          'supplierName': '精密加工厂',
          'status': 'OPEN',
          'actualLossQty': '10.0000',
          'allowedLossQty': '3.0000',
          'excessLossQty': '7.0000',
          'lossBookValueLocal': '70.0000',
          'claimAmountLocal': '0.0000',
          'version': 0,
        },
      ],
      'page': 1,
      'size': 30,
      'total': 1,
      'totalPages': 1,
    };
  }
}
