import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../support/native_detail_reader_overrides.dart';

void main() {
  for (final module in ['purchase', 'subcontract']) {
    for (final segment in ['receipts', 'returns']) {
      testWidgets('$module $segment 审核只读且通过不携带业务修改内容', (tester) async {
        final api = await _pump(tester, module, segment);
        expect(find.text('修改后审核'), findsNothing);
        expect(find.text('保存并审核'), findsNothing);
        expect(find.byType(UtenEditableGrid<PurchaseGridRow>), findsNothing);
        expect(find.byType(UtenEditableGrid<SubcontractGridRow>), findsNothing);
        expect(find.widgetWithText(UtenButton, '编辑'), findsNothing);
        expect(api.writes, isEmpty);
        await tester.tap(find.widgetWithText(UtenButton, '审核'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
        await tester.pumpAndSettle();
        expect(api.writes, [('/$module/$segment/source-draft/approve', null)]);
        expect(api.reviewReads, isEmpty);
        expect(tester.takeException(), isNull);
      });
      testWidgets('$module $segment 只有审核权限不能经普通编辑入口修改草稿', (tester) async {
        final api = await _pump(tester, module, segment, openEdit: true);
        expect(find.byType(PurchaseDocEditPage), findsNothing);
        expect(find.byType(SubcontractDocEditPage), findsNothing);
        expect(find.text('修改后审核'), findsNothing);
        expect(api.writes, isEmpty);
        expect(api.reviewReads, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Future<_ReadOnlyApi> _pump(
  WidgetTester tester,
  String module,
  String segment, {
  bool openEdit = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1700, 1250));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _ReadOnlyApi(module, segment);
  final base = '/$module/$segment/source-draft';
  final router = GoRouter(
    initialLocation: openEdit ? '$base/edit' : base,
    routes: [
      GoRoute(
        path: '$base/edit',
        builder: (_, _) => module == 'purchase'
            ? PurchaseDocEditPage(
                docType: segment == 'receipts'
                    ? PurchaseDocType.receipt
                    : PurchaseDocType.returnDoc,
                id: 'source-draft',
              )
            : SubcontractDocEditPage(
                docType: segment == 'receipts'
                    ? SubcontractDocType.receipt
                    : SubcontractDocType.returnDoc,
                id: 'source-draft',
              ),
      ),
      GoRoute(
        path: base,
        builder: (_, _) => module == 'purchase'
            ? PurchaseDocDetailPage(
                docType: segment == 'receipts'
                    ? PurchaseDocType.receipt
                    : PurchaseDocType.returnDoc,
                id: 'source-draft',
              )
            : SubcontractDocDetailPage(
                docType: segment == 'receipts'
                    ? SubcontractDocType.receipt
                    : SubcontractDocType.returnDoc,
                id: 'source-draft',
              ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        currentPermissionsProvider.overrideWithValue({
          '${module}_${segment == 'receipts' ? 'receipt' : 'return'}:view',
          '${module}_${segment == 'receipts' ? 'receipt' : 'return'}:approve',
        }),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _ReadOnlyApi extends ApiClient {
  _ReadOnlyApi(this.module, this.segment) : super(Dio());
  final String module;
  final String segment;
  final List<(String, Object?)> writes = [];
  final List<String> reviewReads = [];
  bool approved = false;

  Map<String, dynamic> get detail => {
    'id': 'source-draft',
    'status': approved ? 1 : 0,
    'writable': true,
    'canEdit': false,
    'makerId': 'maker-owner',
    'billDate': '2026-10-11',
    'supplierId': 'supplier',
    'warehouseId': 'warehouse',
    'currencyId': 'usd',
    'exchangeRateExact': '7.123456',
    'taxRateExact': '13.120001',
    'settlementMethodId': 'monthly',
    'items': [
      {
        'id': 'draft-line',
        'goodsId': 'goods',
        'goodsCodeSnapshot': 'G001',
        'goodsNameSnapshot': '货品',
        'unitId': 'piece',
        'unitRate': 1,
        'qty': 10.1256,
        'qtyExact': '10.1256',
        'price': 4.05,
        if (segment == 'receipts')
          'orderItemId': 'source-line'
        else
          'receiptItemId': 'source-line',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/review')) reviewReads.add(path);
    if (path == '/$module/$segment/source-draft') return detail;
    return const {'items': <Map<String, dynamic>>[], 'total': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add((path, body));
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add((path, body));
    approved = true;
    return detail;
  }
}
