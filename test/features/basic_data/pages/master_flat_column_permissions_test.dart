import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/pages/account_workspace_page.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final pages = [
    (
      name: '颜色',
      page: const ColorPage(),
      view: Perm.colorView,
      create: Perm.colorCreate,
      edit: Perm.colorEdit,
    ),
    (
      name: '币种',
      page: const CurrencyPage(),
      view: Perm.currencyView,
      create: Perm.currencyCreate,
      edit: Perm.currencyEdit,
    ),
    (
      name: '基本单位',
      page: const UnitPage(),
      view: Perm.unitView,
      create: Perm.unitCreate,
      edit: Perm.unitEdit,
    ),
    (
      name: '仓库',
      page: const WarehousePage(),
      view: Perm.warehouseView,
      create: Perm.warehouseCreate,
      edit: Perm.warehouseEdit,
    ),
    (
      name: '账户',
      page: const AccountPage(),
      view: Perm.accountView,
      create: Perm.accountCreate,
      edit: Perm.accountEdit,
    ),
    (
      name: '结算方式',
      page: const SettlementMethodPage(),
      view: Perm.settlementMethodView,
      create: Perm.settlementMethodCreate,
      edit: Perm.settlementMethodEdit,
    ),
  ];

  for (final page in pages) {
    testWidgets('${page.name}列表只有编辑权限可添加列，权限变更立即更新表头', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final permissions = StateProvider<Set<String>>((_) => {page.view});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_MasterListApi()),
            sharedPreferencesProvider.overrideWithValue(preferences),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWith(
              (ref) => ref.watch(permissions),
            ),
          ],
          child: MaterialApp(
            home: page.page,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byWidget(page.page)),
      );

      void expectColumnEditing(bool enabled) {
        final table = tester.widget<MasterDataTableView<dynamic>>(
          find.byWidgetPredicate((widget) => widget is MasterDataTableView),
        );
        expect(table.items, hasLength(1));
        expect(table.columnEditingEnabled, enabled);
        expect(find.byTooltip('添加列'), enabled ? findsOneWidget : findsNothing);
        expect(find.byTooltip('显示列'), enabled ? findsNothing : findsOneWidget);
      }

      expectColumnEditing(false);

      container.read(permissions.notifier).state = {page.view, page.create};
      await tester.pumpAndSettle();
      expectColumnEditing(false);

      container.read(permissions.notifier).state = {page.view, page.edit};
      await tester.pumpAndSettle();
      expectColumnEditing(true);

      container.read(permissions.notifier).state = {page.view};
      await tester.pumpAndSettle();
      expectColumnEditing(false);
      expect(tester.takeException(), isNull);
    });
  }
}

class _MasterListApi implements ApiClient {
  static const _item = <String, dynamic>{
    'id': 'master-1',
    'code': 'M001',
    'name': '测试资料',
    'status': '使用',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/facets')) {
      return {'fields': <String, dynamic>{}, 'nullCounts': <String, dynamic>{}};
    }
    if ({
      ApiEndpoints.colors,
      ApiEndpoints.currencies,
      ApiEndpoints.units,
      ApiEndpoints.warehouses,
      AccountEndpoints.base,
    }.contains(path)) {
      return {
        'items': [_item],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.settlementMethodsAdmin) return [_item];
    if (path == ApiEndpoints.warehouseKeeperAssignments) return [];
    throw StateError('Unexpected GET list $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
