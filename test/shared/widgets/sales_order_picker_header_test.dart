import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/sales_order_picker.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders') return {};
    queries.add({...?query});
    final keyword = query?['search.billNo']?.toString() ?? '';
    final rows = [
      for (final number in ['SO-001', 'SO-002'])
        if (number.contains(keyword))
          {
            'id': number,
            'billNo': number,
            'billDate': '2026-10-01',
            'deliverDate': '2026-10-31',
            'status': 1,
            'sellerName': '销售员甲',
          },
    ];
    return {
      'items': rows,
      'page': query?['page'] ?? 1,
      'size': 20,
      'total': keyword.isEmpty ? 40 : rows.length,
      'totalPages': keyword.isEmpty ? 2 : 1,
    };
  }
}

void main() {
  testWidgets(
    'order picker header queries the server and confirms one source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      SalesDocListItem? selected;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({Perm.salesOrderView}),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    selected = await showSalesOrderPicker(context, ref);
                  },
                  child: const Text('选择来源'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择来源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单据号'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '002',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.queries.last['search.billNo'], '002');
      expect(api.queries.last['status'], kSalesStatusApproved);
      expect(api.queries.last['page'], 1);
      expect(find.text('SO-001'), findsNothing);
      expect(find.text('SO-002'), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.text('SO-002'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('SO-002'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.billNo, 'SO-002');
      expect(tester.takeException(), isNull);
    },
  );
}
