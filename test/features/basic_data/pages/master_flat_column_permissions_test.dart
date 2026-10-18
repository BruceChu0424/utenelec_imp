import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
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
  const createLabels = {
    '颜色': '添加颜色',
    '币种': '添加币种',
    '基本单位': '添加单位',
    '仓库': '添加仓库',
    '结算方式': '添加结算方式',
  };

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
        final tableFinder = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView,
        );
        final table = tester.widget<MasterDataTableView<dynamic>>(tableFinder);
        expect(table.items, hasLength(1));
        expect(table.columnEditingEnabled, enabled);
        final columnAction = find
            .descendant(
              of: tableFinder,
              matching: find.byKey(const Key('platform-table-add-column')),
            )
            .hitTestable();
        expect(columnAction, findsOneWidget);
        expect(
          tester.widget<IconButton>(columnAction).tooltip,
          enabled ? '添加列' : '显示列',
        );
      }

      expectColumnEditing(false);
      final createLabel = createLabels[page.name];
      if (createLabel != null) expect(find.text(createLabel), findsNothing);

      container.read(permissions.notifier).state = {page.view, page.create};
      await tester.pumpAndSettle();
      expectColumnEditing(false);
      if (createLabel != null) {
        _expectFloatingCreate(tester, createLabel, const Size(1440, 900));
      }
      if (page.name == '颜色') {
        // 行菜单启停/删除随权限灰置（2026-10-18 口径：批量也走右键菜单，
        // 常驻批量按钮已退役）。
        UtenMenuItem colorMenuEntry(String label) {
          final table = tester.widget<MasterDataTableView<ColorListItem>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<ColorListItem>,
            ),
          );
          return table
              .rowMenuBuilder!(table.items.single)
              .whereType<UtenMenuItem>()
              .firstWhere((e) => e.label == label);
        }

        expect(colorMenuEntry('禁用颜色').enabled, isFalse);
        expect(colorMenuEntry('删除颜色').enabled, isFalse);
        container.read(permissions.notifier).state = {
          page.view,
          page.create,
          Perm.colorStatus,
          Perm.colorDelete,
        };
        await tester.pumpAndSettle();
        expect(colorMenuEntry('禁用颜色').enabled, isTrue);
        expect(colorMenuEntry('删除颜色').enabled, isTrue);
        _expectFloatingCreate(tester, '添加颜色', const Size(1440, 900));
      }

      container.read(permissions.notifier).state = {page.view, page.edit};
      await tester.pumpAndSettle();
      expectColumnEditing(true);
      if (createLabel != null) expect(find.text(createLabel), findsNothing);

      container.read(permissions.notifier).state = {page.view};
      await tester.pumpAndSettle();
      expectColumnEditing(false);
      expect(tester.takeException(), isNull);
    });

    final createLabel = createLabels[page.name];
    if (createLabel == null) continue;
    testWidgets('${page.name}窄屏空态保留独立搜索和唯一右下角添加入口', (tester) async {
      const viewport = Size(360, 800);
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_MasterListApi(empty: true)),
            sharedPreferencesProvider.overrideWithValue(preferences),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue({
              page.view,
              page.create,
            }),
          ],
          child: MaterialApp(
            home: page.page,
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = find.byWidgetPredicate((w) => w is MasterDataTableView);
      final search = find.byType(UtenSearchBar);
      expect(search, findsOneWidget);
      expect(
        tester.getRect(search).bottom,
        lessThanOrEqualTo(tester.getRect(table).top),
      );
      expect(
        find.textContaining(RegExp(r'^(颜色|币种|单位|仓库|结算方式) \(\d+\)$')),
        findsNothing,
      );
      _expectFloatingCreate(tester, createLabel, viewport);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(createLabel));
      await tester.pumpAndSettle();
      expect(find.text(createLabel.replaceFirst('添加', '新增')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

void _expectFloatingCreate(WidgetTester tester, String label, Size viewport) {
  final create = find.text(label);
  expect(create, findsOneWidget);
  final group = find.ancestor(
    of: create,
    matching: find.byType(UtenFloatingActionGroup),
  );
  expect(group, findsOneWidget);
  expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
  final bounds = tester.getRect(create);
  expect(bounds.top, greaterThan(viewport.height / 2));
  expect(bounds.right, lessThanOrEqualTo(viewport.width));
  expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
}

class _MasterListApi implements ApiClient {
  _MasterListApi({this.empty = false});
  final bool empty;
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
        'items': [if (!empty) _item],
        'page': 1,
        'size': 20,
        'total': empty ? 0 : 1,
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
    if (path == ApiEndpoints.settlementMethodsAdmin) {
      return [if (!empty) _item];
    }
    if (path == ApiEndpoints.warehouseKeeperAssignments) return [];
    throw StateError('Unexpected GET list $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
