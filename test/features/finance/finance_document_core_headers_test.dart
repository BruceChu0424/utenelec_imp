import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/native_detail_reader_overrides.dart';

class _Names extends Fake implements FinanceNameService {}

class _Api extends ApiClient {
  _Api({this.status = 1}) : super(Dio());
  int status;
  final List<(String, Object?)> writes = [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('scope')
      ? {'scope': 'finance', 'writeAll': false, 'writableOwnerIds': <String>[]}
      : {
          'id': 'finance-header-1',
          'makerId': 'header-maker-1',
          'billNo': 'TEST-HEADER-1',
          'billDate': '2026-10-11',
          'status': status,
          'closed': false,
          'allowedActions': ['VIEW'],
          'items': [
            {
              'id': 'line-1',
              'qty': 12.1256,
              'qtyExact': '12.1256',
              'price': 0.0001,
              'priceExact': '0.0001',
              'amountOriginal': 12.34567,
              'amountOriginalExact': '12.34567',
              'amountLocal': 12.34567,
              'amountLocalExact': '12.34567',
              'appliedBillNo': 'AP-1',
              'appliedAmountLocal': 12.34567,
              'appliedAmountLocalExact': '12.34567',
              'exchangeDiff': 0,
            },
          ],
        };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add((path, body));
    status = 1;
    return {'id': 'finance-header-1', 'status': status, 'items': <Object>[]};
  }
}

void main() {
  for (final type in FinanceDocType.values) {
    testWidgets('${type.name} 审核单据只读，普通审核只提交决定', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _Api(status: 0);
      final config = FinanceDocConfig.by(type);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(),
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue({
              config.listPerm,
              config.approvePerm!,
              Perm.financeViewAll,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: FinanceDocDetailPage(docType: type, id: 'finance-header-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('修改后审核'), findsNothing);
      expect(find.text('保存并审核'), findsNothing);
      expect(find.byType(UtenEditableGrid<FinanceGridRow>), findsNothing);
      expect(find.widgetWithText(UtenButton, '编辑'), findsNothing);
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.writes, [
        ('/finance/${type.pathSegment}/finance-header-1/approve', null),
      ]);
      expect(tester.takeException(), isNull);
    });
  }
  for (final (type, permission) in [
    (FinanceDocType.expense, Perm.financeExpenseView),
    (FinanceDocType.otherIncome, Perm.financeOtherIncomeView),
    (FinanceDocType.payment, Perm.financePaymentView),
  ]) {
    testWidgets('$type create and actual detail share core header meaning', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(),
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiClientProvider.overrideWithValue(_Api()),
            currentPermissionsProvider.overrideWithValue({
              permission,
              Perm.financeViewAll,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: FinanceDocDetailPage(docType: type, id: 'finance-header-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final finder = find.byType(MasterDataTableView<FinanceDocItem>);
      final table = tester.widget<MasterDataTableView<FinanceDocItem>>(finder);
      final detail = {
        for (final column in table.columns) column.key: column.label,
      };
      final context = tester.element(finder);
      final row = FinanceGridRow(
        mode: type == FinanceDocType.payment
            ? ItemMode.settle
            : ItemMode.allocate,
      );
      addTearDown(row.dispose);
      final create = financeGridColumns(
        row.mode,
        context: context,
        names: _Names(),
        type: type,
      );
      if (type == FinanceDocType.payment) {
        expect(create.map((column) => column.label), ['应付单号', '本次付款(原币)']);
        expect(detail['bill'], create.first.label);
        expect(detail['amountOriginal'], create.last.label);
        expect(table.columns.map((column) => column.key), [
          'bill',
          'amountOriginal',
          'amountLocal',
          'appliedAmountLocal',
          'exchangeDiff',
        ]);
        expect(
          table.columns
              .singleWhere((column) => column.key == 'amountOriginal')
              .value(table.items.single),
          '12.34567',
        );
      } else {
        expect(create.map((column) => column.label), [
          type == FinanceDocType.expense ? '费用项目' : '收入项目',
          '部门',
          '数量',
          '单价',
          '金额',
        ]);
        expect(detail.values, create.map((column) => column.label));
        expect(
          table.columns
              .singleWhere((column) => column.key == 'qty')
              .value(table.items.single),
          '12.1256',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
