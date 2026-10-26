import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_supplier_picker.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_settlement_actions.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Prefs extends FinanceStatementReportPrefsNotifier {
  _Prefs(this.side);
  final String side;
  @override
  ReportFilterPrefs build() => ReportFilterPrefs(docType: side);
  @override
  void update(ReportFilterPrefs value) => state = value;
}

class _Identity extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() =>
      const AuthenticatedScope(userId: 'finance-reader');
  void change(String id) => state = AuthenticatedScope(userId: id);
}

final _identity = NotifierProvider<_Identity, AuthenticatedScope?>(
  _Identity.new,
);

class _Api extends ApiClient {
  _Api() : super(Dio());
  final listRequests = <(String, Map<String, dynamic>)>[];
  final reportQueries = <Map<String, dynamic>>[];
  final lookupIds = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/reports/')) {
      reportQueries.add({...?query});
      return {
        'columns': <Object>[],
        'rows': <Object>[],
        'facets': <String, Object>{},
        'page': 1,
        'total': 0,
        'totalPages': 0,
      };
    }
    if (path == '/master/clients' || path == '/master/suppliers') {
      listRequests.add((path, {...?query}));
      return {
        'items': [
          {
            'id': 'historical-party',
            'name': '历史禁用往来方',
            'code': 'H1',
            'categoryId': 'root',
            'status': '禁用',
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/dict') &&
        (path.contains('clients') || path.contains('suppliers'))) {
      throw StateError('Complete party dictionaries must never be read');
    }
    if (path.endsWith('-categories/tree')) {
      return [
        {
          'id': 'root',
          'code': 'ROOT',
          'name': '往来方分类',
          'level': 0,
          'children': <Object>[],
        },
      ];
    }
    if (path.endsWith('/lookup')) {
      lookupIds.add(query!['ids'] as String);
      return [
        {
          'id': 'historical-party',
          'name': '历史禁用往来方',
          'code': 'H1',
          'status': '禁用',
          'selectable': false,
        },
      ];
    }
    return [];
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Api api, {
  String side = 'AR',
  bool monthly = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://fixture.invalid/api'),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWithValue({
          Perm.clientView,
          Perm.supplierView,
          Perm.financeReportView,
          Perm.financeViewAll,
        }),
        financeStatementReportPrefsProvider.overrideWith(() => _Prefs(side)),
      ],
      child: MaterialApp(
        home: monthly
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        showSupplierSettlementCreatePanel(context: context),
                    child: const Text('创建月结'),
                  ),
                ),
              )
            : const FinanceStatementPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseHistoricalParty(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('历史禁用往来方'));
  await tester.pump();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'monthly freeze cannot return a command after its opening reader changes A-B-A',
    (tester) async {
      await _mount(tester, _Api(), monthly: true);
      await tester.tap(find.text('创建月结'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SupplierPickerField)),
      );
      container.read(_identity.notifier).change('other-reader');
      await tester.pumpAndSettle();
      expect(find.text('登录身份或读取范围已变化，请关闭后重新打开'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '冻结月结快照'))
            .onPressed,
        isNull,
      );
      container.read(_identity.notifier).change('finance-reader');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '冻结月结快照'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<SupplierPickerField>(find.byType(SupplierPickerField))
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final side in ['AR', 'AP']) {
    testWidgets(
      '$side statement preserves historical disabled UUID through paged party selector',
      (tester) async {
        final api = _Api();
        await _mount(tester, api, side: side);
        expect(api.listRequests, isEmpty);
        await tester.tap(
          side == 'AR'
              ? find.byType(ClientPickerField)
              : find.byType(SupplierPickerField),
        );
        await _chooseHistoricalParty(tester);
        expect(
          api.listRequests.single.$1,
          side == 'AR' ? '/master/clients' : '/master/suppliers',
        );
        expect(api.listRequests.single.$2['selectableOnly'], isNot(true));
        expect(api.lookupIds, ['historical-party']);
        expect(api.reportQueries.last['partyId'], 'historical-party');
        expect(api.reportQueries.last['side'], side);
        await tester.tap(find.byTooltip('清除选择'));
        await tester.pumpAndSettle();
        expect(api.reportQueries.last.containsKey('partyId'), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'monthly settlement uses historical supplier candidates and retains required selection',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, monthly: true);
      await tester.tap(find.text('创建月结'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SupplierPickerField));
      await _chooseHistoricalParty(tester);
      expect(api.listRequests.single.$1, '/master/suppliers');
      expect(api.listRequests.single.$2['selectableOnly'], isNot(true));
      expect(api.lookupIds, ['historical-party']);
      final field = tester.widget<SupplierPickerField>(
        find.byType(SupplierPickerField),
      );
      expect(field.initialId, 'historical-party');
      expect(field.allowClear, isFalse);
      expect(find.byTooltip('清除选择'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
