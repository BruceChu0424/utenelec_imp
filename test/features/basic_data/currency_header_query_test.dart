import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'currency rate header sends exact original rate before paging and to export',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue({
              Perm.currencyView,
              Perm.currencyExport,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            currencyRepositoryProvider.overrideWithValue(repository),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(home: CurrencyPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('master-column-filter-exchangeRate')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '123456789012.123456..123456789012.123457',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        repository.filters.last['search.exchangeRate'],
        '123456789012.123456..123456789012.123457',
      );
      expect(repository.pages.last, 1);
      final table = tester.widget<MasterDataTableView<CurrencyListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<CurrencyListItem>,
        ),
      );
      final rate = table.columns.singleWhere(
        (column) => column.key == 'exchangeRate',
      );
      expect(rate.exactValueOf!(repository.item), '123456789012.123456');
      expect(
        tester
            .widget<UtenExportButton>(find.byType(UtenExportButton).first)
            .queryParams['search.exchangeRate'],
        repository.filters.last['search.exchangeRate'],
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'currency repository retains six digit decimal terms as strings',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': <Map<String, dynamic>>[],
                  'total': 0,
                  'page': 1,
                  'size': 20,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );
      await DioCurrencyRepository(
        ApiClient(dio),
      ).list(filters: {'search.exchangeRate': '123456789012.123456'});
      expect(
        captured.queryParameters['search.exchangeRate'],
        '123456789012.123456',
      );
    },
  );
}

class _Repository implements CurrencyRepository {
  final filters = <Map<String, String?>>[];
  final pages = <int>[];
  final item = const CurrencyListItem(
    id: 'currency-1',
    code: 'C-01',
    name: '测试币种',
    exchangeRate: 123456789012.12346,
    exchangeRateText: '123456789012.123456',
    status: '使用',
  );
  @override
  Future<PagedResult<CurrencyListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    this.filters.add(Map.of(filters));
    pages.add(page);
    return PagedResult(
      items: [item],
      total: 1,
      page: page,
      size: size,
      totalPages: 1,
    );
  }

  @override
  Future<CurrencyFacets> facets() async =>
      const CurrencyFacets(fields: {}, nullCounts: {});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
