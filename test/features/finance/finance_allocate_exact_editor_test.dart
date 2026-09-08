import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  for (final type in [
    FinanceDocType.expense,
    FinanceDocType.otherIncome,
    FinanceDocType.bankTransfer,
  ]) {
    testWidgets(
      '${type.name} untouched and changed money save decimal text without double conversion',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const original = '1234567890123.123456789012345678901234';
        const changed = '1234567890123.123456789012345678901235';
        final detail = <String, dynamic>{
          'id': 'document-1',
          'version': 3,
          'status': 0,
          'makerId': 'maker-1',
          'billNo': 'TEST-001',
          'billDate': '2026-09-07',
          'accountId': 'account-1',
          'outAccountId': 'account-1',
          'paymentMethodId': 'method-1',
          'receiptMethodId': 'method-1',
          'currencyId': 'currency-cny',
          'exchangeRate': 1,
          'exchangeRateExact': '1.000000',
          'amountOriginal': 1234567890123.1,
          'amountOriginalExact': original,
          'amountLocal': 1234567890123.1,
          'amountLocalExact': original,
          'items': [
            <String, dynamic>{
              'id': 'line-1',
              'amountOriginal': 1234567890123.1,
              'amountOriginalExact': original,
              'amountLocal': 1234567890123.1,
              'amountLocalExact': original,
              'qty': 2,
              'qtyExact': '2.0000',
              'price': 1.23456789,
              'priceExact': '1.2345678901',
              'expenseStyleId': 'style-1',
              'incomeStyleId': 'style-1',
              'inAccountId': 'account-2',
              'occurDate': '2026-09-07',
              'summary': '原始摘要',
              'remark': '原始备注',
            },
          ],
        };
        final api = _ExactEditorApi(detail);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              financeWriteAllDocumentScope(),
              apiClientProvider.overrideWithValue(api),
              sessionProvider.overrideWith(_TestSessionNotifier.new),
            ],
            child: MaterialApp(
              home: FinanceDocEditPage(docType: type, id: 'document-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
          find.byWidgetPredicate(
            (widget) => widget is UtenEditableGrid<FinanceGridRow>,
          ),
        );
        final row = grid.controller.rows.single;
        expect(row.amount.text, original);
        expect(row.qty.text, '2.0000');
        expect(row.price.text, '1.2345678901');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(api.bodies, hasLength(1));
        final first = (api.bodies.single['items'] as List).single as Map;
        expect(first['amountOriginal'], original);
        expect(first['amountLocal'], original);
        expect(first['summary'], '原始摘要');
        if (type != FinanceDocType.bankTransfer) {
          expect(first['qty'], '2.0000');
          expect(first['price'], '1.2345678901');
        }
        row.amount.text = changed;
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(api.bodies, hasLength(2));
        final second = (api.bodies.last['items'] as List).single as Map;
        expect(second['amountOriginal'], changed);
        expect(second['amountLocal'], changed);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _ExactEditorApi extends ApiClient {
  _ExactEditorApi(this.detail) : super(Dio());
  final Map<String, dynamic> detail;
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/accounts/dict') {
      return [
        for (final id in ['account-1', 'account-2'])
          {
            'id': id,
            'name': id,
            'currencyId': 'currency-cny',
            'currencyCode': 'CNY',
            'currencyName': '人民币',
            'baseCurrency': true,
            'status': '使用',
          },
      ];
    }
    if (path == '/master/currencies/dict') {
      return [
        {'id': 'currency-cny', 'name': '人民币'},
      ];
    }
    if (path.contains('payment-styles')) {
      return [
        {
          'id': 'style-1',
          'name': '实际项目',
          'status': '使用',
          'children': <Map<String, dynamic>>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    bodies.add(Map<String, dynamic>.from(body as Map));
    return detail;
  }
}
