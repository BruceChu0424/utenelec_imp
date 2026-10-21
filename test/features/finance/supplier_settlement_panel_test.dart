import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/repositories/supplier_settlement_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_settlement_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../support/filter_segment_tap.dart';

void main() {
  testWidgets('375px monthly list remains usable', (tester) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(
      tester,
      const SupplierSettlementPanel(),
      permissions: const {
        Perm.supplierSettlementView,
        Perm.supplierSettlementCreate,
      },
    );

    expect(
      find.byKey(const ValueKey('supplier-settlement-create')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('supplier-settlement-search')),
      findsOneWidget,
    );
    expect(find.text('人民币'), findsOneWidget);
    expect(find.text('001'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail exposes confirm dispute and reverse by permission', (
    tester,
  ) async {
    await _pump(
      tester,
      const SupplierSettlementDetailPanel(batchId: 'batch-1'),
      permissions: const {
        Perm.supplierSettlementView,
        Perm.supplierSettlementConfirm,
        Perm.supplierSettlementDispute,
        Perm.supplierSettlementReverse,
      },
    );

    expect(find.text('到期日(服务端)'), findsOneWidget);
    expect(find.textContaining('sha256-value'), findsOneWidget);
    expect(find.text('供应商确认'), findsOneWidget);
    expect(find.text('公司确认'), findsOneWidget);
    expect(find.text('登记争议'), findsOneWidget);
    expect(find.text('反转批次'), findsOneWidget);
  });

  testWidgets(
    'monthly status re-tap keeps its query and all removes only that query',
    (tester) async {
      tester.view.physicalSize = const Size(375, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      await _pump(
        tester,
        const SupplierSettlementPanel(),
        api: api,
        permissions: const {Perm.supplierSettlementView},
      );
      await selectFilterSegment(tester, '已冻结');
      await tester.pumpAndSettle();
      expect(api.listQueries.last['status'], 'FROZEN');
      expect(api.listQueries.last['page'], 1);
      final reads = api.listQueries.length;
      await selectFilterSegment(tester, '已冻结');
      await tester.pumpAndSettle();
      expect(api.listQueries.length, reads);
      expect(api.listQueries.last['status'], 'FROZEN');
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(api.listQueries.last.containsKey('status'), isFalse);
      expect(find.text('人民币'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('supplier-settlement-create')),
        findsNothing,
      );
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Set<String> permissions,
  _Api? api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supplierSettlementRepositoryProvider.overrideWithValue(
          SupplierSettlementRepository(api ?? _Api()),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

const _summary = <String, dynamic>{
  'id': 'batch-1',
  'batchNo': 'SET-001',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'currencyId': 'currency-cny',
  'currencyCode': '001',
  'currencyName': '人民币',
  'periodStart': '2026-07-01',
  'periodEnd': '2026-07-31',
  'dueDate': '2026-08-30',
  'status': 'FROZEN',
  'openingBalanceOriginal': '100.0000',
  'periodPostedOriginal': '80.0000',
  'periodPaidOriginal': '30.0000',
  'periodOffsetOriginal': '10.0000',
  'closingBalanceOriginal': '140.0000',
  'lineCount': 1,
  'version': 3,
  'snapshotHash': 'sha256-value',
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final listQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/batch-1')) {
      return {
        'summary': _summary,
        'lines': <Map<String, dynamic>>[],
        'events': <Map<String, dynamic>>[],
      };
    }
    listQueries.add({...?query});
    return {
      'items': [_summary],
      'page': 1,
      'size': 30,
      'total': 1,
      'totalPages': 1,
    };
  }
}
