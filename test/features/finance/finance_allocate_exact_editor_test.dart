import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../support/document_scope_capability_overrides.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'new finance draft survives hard close without submitting incomplete money',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryFormDraftStorage();
      final prefs = await SharedPreferences.getInstance();
      Future<
        ({ProviderContainer container, GoRouter router, _ExactEditorApi api})
      >
      open(String location) async {
        final api = _ExactEditorApi({'id': 'server-created'});
        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            apiBaseUrlProvider.overrideWithValue(
              'https://finance-draft.test/api',
            ),
            sessionProvider.overrideWith(_TestSessionNotifier.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'finance-operator'),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.financeExpenseView,
              Perm.financeExpenseCreate,
            }),
            sharedPreferencesProvider.overrideWithValue(prefs),
            formDraftStorageProvider.overrideWithValue(storage),
          ],
        );
        final router = GoRouter(
          initialLocation: location,
          routes: [
            DraftAwareGoRoute(
              path: '/finance/expenses/new',
              builder: (_, _) =>
                  const FinanceDocEditPage(docType: FinanceDocType.expense),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        return (container: container, router: router, api: api);
      }

      var env = await open('/finance/expenses/new');
      expect(env.container.read(formDraftsProvider), isEmpty);
      final grid = tester
          .widget<UtenEditableGrid<FinanceGridRow>>(
            find.byType(UtenEditableGrid<FinanceGridRow>),
          )
          .controller;
      grid[0].qty.text = '12.';
      grid[0].amount.text = '1234567890123.123456789012345678901235';
      grid[0].remark.text = '未完成的费用明细';
      grid.setSelected([grid[0]], true);
      await tester.pump();
      final state =
          tester.state(find.byType(FinanceDocEditPage))
              as FormDraftMixin<FinanceDocEditPage>;
      await state.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['accountId'], isNull);
      expect(env.api.bodies, isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await open(draft.resumeLocation);
      final recovered = tester
          .widget<UtenEditableGrid<FinanceGridRow>>(
            find.byType(UtenEditableGrid<FinanceGridRow>),
          )
          .controller;
      expect(recovered[0].qty.text, '12.');
      expect(
        recovered[0].amount.text,
        '1234567890123.123456789012345678901235',
      );
      expect(recovered[0].remark.text, '未完成的费用明细');
      expect(recovered.isSelected(recovered[0]), isTrue);
      expect(env.api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'form snapshot keeps raw money, settlement provenance and row selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            financeWriteAllDocumentScope(),
            apiClientProvider.overrideWithValue(
              _ExactEditorApi({
                'id': 'document-1',
                'status': 0,
                'makerId': 'maker-1',
                'items': <Map<String, dynamic>>[],
              }),
            ),
            sessionProvider.overrideWith(_TestSessionNotifier.new),
          ],
          child: const MaterialApp(
            home: FinanceDocEditPage(
              docType: FinanceDocType.expense,
              id: 'document-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(FinanceDocEditPage))
              as FormDraftMixin<FinanceDocEditPage>;
      final saved = state.captureFormDraft();
      saved['remark'] = '尚未填写完';
      saved['rows'] = [
        {
          'amount': '1234567890123.123456789012345678901235',
          'qty': '12.',
          'price': '',
          'appliedLedgerId': 'ledger-original',
          'sourceDocType': 'PURCHASE_RECEIPT',
          'sourceDocNo': 'SH-001',
          'authoritativeSalesOrderId': 'order-source',
          'salesOrderIds': ['order-source'],
          'salesOrderNos': ['XD-001'],
          'balanceOriginalText': '999999999999999.000001',
        },
      ];
      saved['selected'] = [0];
      await state.restoreFormDraft(saved);
      await tester.pumpAndSettle();
      final roundTrip = state.captureFormDraft();
      final row = (roundTrip['rows'] as List).single as Map;
      expect(row['amount'], '1234567890123.123456789012345678901235');
      expect(row['qty'], '12.');
      expect(row['price'], '');
      expect(row['appliedLedgerId'], 'ledger-original');
      expect(row['salesOrderIds'], ['order-source']);
      expect(row['balanceOriginalText'], '999999999999999.000001');
      expect(roundTrip['selected'], [0]);
      expect(tester.takeException(), isNull);
    },
  );

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
        // ADR-112: 本币由服务端按表头汇率派生, 请求只带实际金额原文。
        expect(first.containsKey('amountLocal'), isFalse);
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
        expect(second.containsKey('amountLocal'), isFalse);
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
