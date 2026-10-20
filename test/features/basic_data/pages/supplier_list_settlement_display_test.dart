import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'supplier list displays canonical default settlement while retaining the priceStyle layout key',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            Object data = <String, dynamic>{};
            if (request.path.endsWith('/supplier-categories/tree')) {
              data = [
                {
                  'id': 'category',
                  'code': 'S-UAT',
                  'name': '验收供应商分类',
                  'level': 0,
                  'codePrefix': 'GY',
                  'children': <Object>[],
                },
              ];
            } else if (request.path.endsWith('/supplier-categories/category')) {
              data = {
                'id': 'category',
                'code': 'S-UAT',
                'name': '验收供应商分类',
                'level': 0,
                'childCount': 0,
                'effectivePrefix': 'GY',
              };
            } else if (request.path.endsWith('/suppliers') ||
                request.path.endsWith('/suppliers/search')) {
              data = {
                'items': [
                  {
                    'id': 'modern',
                    'name': 'Local UAT Supplier',
                    'categoryId': 'category',
                    'status': '使用',
                    'defaultSettlementMethodId': 'method-uuid',
                    'defaultSettlementMethodName': 'Local UAT Net30',
                    'priceStyle': null,
                  },
                  {
                    'id': 'unrelated',
                    'name': '历史未关联供应商',
                    'categoryId': 'category',
                    'status': '使用',
                    'priceStyle': 30,
                  },
                ],
                'page': 1,
                'size': 20,
                'total': 2,
                'totalPages': 1,
              };
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio)),
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.supplierView,
              Perm.supplierCategoryView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SupplierCategoryPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('验收供应商分类'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<SupplierListItem>>(
        find.byType(MasterDataTableView<SupplierListItem>),
      );
      final column = table.columns.singleWhere(
        (column) => column.key == 'priceStyle',
      );
      expect(column.value(table.items.first), 'Local UAT Net30');
      expect(
        column.value(table.items.last),
        anyOf(isNull, '—'),
        reason:
            'A legacy numeric snapshot is not an authoritative settlement name',
      );
      expect(find.text('Local UAT Net30'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
