// 即时库存与货品资料共用左右分类导航；小屏在抽屉内使用同一棵树。
// 搜索分类定位整类，搜索货品定位所在分类并过滤右侧库存。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required _RecordingStockRepository stock,
    Set<String> permissions = const <String>{},
    Size size = const Size(1600, 1000),
    _ProductCategoryRepo? categories,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_InventoryApi()),
          productCategoryRepositoryProvider.overrideWithValue(
            categories ?? _ProductCategoryRepo(),
          ),
          stockQueryRepositoryProvider.overrideWithValue(stock),
          currentPermissionsProvider.overrideWithValue(permissions),
        ],
        child: const MaterialApp(home: InstantInventoryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens unfiltered and loads the first page immediately', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    // 进入时全部分类直接显示第一页，左树无需先打开面板。
    expect(stock.calls, 1);
    expect(stock.lastCategoryId, isNull);
    expect(stock.lastKeyword, isNull);
    expect(
      find.byKey(const Key('instant-inventory-category-tree')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('instant-inventory-category-all')),
      findsOneWidget,
    );
  });

  testWidgets(
    'wide screen keeps a category tree beside the inventory and all clears selection',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      final tree = find.byKey(const Key('instant-inventory-category-tree'));
      final table = find.byType(MasterDataTableView<InstantInventoryRow>);
      expect(find.byType(UtenSplitView), findsOneWidget);
      expect(
        find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        findsOneWidget,
      );
      expect(tester.getRect(tree).right, lessThan(tester.getRect(table).left));
      expect(tester.getRect(tree).overlaps(tester.getRect(table)), isFalse);
      expect(find.text('成品(FINISHED)'), findsOneWidget);
      expect(find.textContaining('未分类（历史孤儿）'), findsNothing);
      expect(
        find.byKey(const Key('instant-inventory-open-categories')),
        findsNothing,
      );

      // 每次直接点左树切换，分类导航始终留在页面。
      await tester.tap(find.text('成品(FINISHED)'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'finished');
      expect(tree, findsOneWidget);

      await tester.tap(find.text('原材料(RAW)'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');

      await tester.tap(find.byKey(const Key('instant-inventory-category-all')));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, isNull);
    },
  );

  // V595 线边仓(车间内部直送的料架)退出即时库存：页面进来默认不要线边仓，
  // 只有用户自己点开「含线边仓」才把它算回来——默认值翻了就是业务口径回归。
  testWidgets('line-side stock stays out of instant inventory until asked', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    expect(stock.lastIncludeLineSide, isFalse);
    // 同一口径里不良品仓仍是默认计入的，别把两个开关搞混。
    expect(stock.lastIncludeDefective, isTrue);

    // 换仓库口径(主仓子树聚合)不得顺手把线边仓带回来。
    await tester.tap(find.byKey(const ValueKey('instant-inventory-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
    await tester.pumpAndSettle();
    expect(stock.lastWarehouseId, 'w1');
    expect(stock.lastIncludeLineSide, isFalse);

    // 回到「全部」后点开关 → 显式要线边仓才带 true，再点一次收回。
    await tester.tap(find.byKey(const ValueKey('instant-inventory-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('instant-inventory-line-side')));
    await tester.pumpAndSettle();
    expect(stock.lastIncludeLineSide, isTrue);

    await tester.tap(find.byKey(const Key('instant-inventory-line-side')));
    await tester.pumpAndSettle();
    expect(stock.lastIncludeLineSide, isFalse);
  });

  testWidgets(
    'warehouse field opens the panel and re-queries with warehouseId',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      await tester.tap(
        find.byKey(const ValueKey('instant-inventory-warehouse')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
      // 查询口径不钻层：主仓与子仓同屏，主仓一点即选（= 子树聚合）。
      expect(
        find.byKey(const Key('warehouse-picker-entry-w1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-w1a')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, 'w1');

      await tester.tap(
        find.byKey(const ValueKey('instant-inventory-warehouse')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-all')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, isNull);
    },
  );

  testWidgets(
    'category name or code search reveals a deep category without filtering goods',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      for (final query in ['插套分类', 'SOCKET']) {
        await tester.enterText(_searchEditable(), query);
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pumpAndSettle();
        expect(find.text('插套分类(SOCKET)'), findsOneWidget);
        expect(find.text('连接器(CONNECTORS)'), findsOneWidget);
        expect(find.text('原材料(RAW)'), findsNothing);
        expect(stock.lastCategoryId, 'socket');
        expect(stock.lastKeyword, isNull, reason: '分类名称/编号命中应展示整类库存，不能当成货品关键词');
      }

      await tester.tap(_clearSearch());
      await tester.pumpAndSettle();
      expect(find.text('原材料(RAW)'), findsOneWidget);
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, isNull);
    },
  );

  testWidgets(
    'goods search locates its category and clear keeps the selected location',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();

      expect(stock.searchQueries, ['HV-001']);
      expect(stock.searchRootScopes.single, isNot(contains('orphan')));
      expect(stock.searchRootScopes.single, isNotEmpty);
      expect(find.text('插套分类(SOCKET)'), findsOneWidget);
      expect(find.text('原材料(RAW)'), findsNothing);
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');

      // 点搜索命中路径上的父分类，仍在该子树内筛选货品。
      await tester.tap(find.text('成品(FINISHED)'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'finished');
      expect(stock.lastKeyword, 'HV-001');

      await tester.tap(_clearSearch());
      await tester.pumpAndSettle();
      expect(_searchText(tester), isEmpty);
      expect(find.text('原材料(RAW)'), findsOneWidget);
      expect(stock.lastCategoryId, 'finished');
      expect(stock.lastKeyword, isNull);

      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('instant-inventory-category-all')));
      await tester.pumpAndSettle();
      expect(_searchText(tester), isEmpty);
      expect(find.text('原材料(RAW)'), findsOneWidget);
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, isNull);
    },
  );

  testWidgets(
    'no search matches shows feedback and clearing restores the tree',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      await tester.enterText(_searchEditable(), '不存在的货品');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(stock.searchQueries, ['不存在的货品']);
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, '不存在的货品');
      expect(find.text('成品(FINISHED)'), findsNothing);
      expect(find.text('原材料(RAW)'), findsNothing);
      expect(find.textContaining('未找到'), findsWidgets);
      expect(
        find.byKey(const Key('instant-inventory-category-all')),
        findsOneWidget,
      );

      await tester.tap(_clearSearch());
      await tester.pumpAndSettle();
      expect(find.text('成品(FINISHED)'), findsOneWidget);
      expect(find.text('原材料(RAW)'), findsOneWidget);
      expect(stock.lastKeyword, isNull);
    },
  );

  testWidgets(
    'a late search cannot overwrite newer input during its debounce',
    (tester) async {
      final slowResult = Completer<Set<String>>();
      final stock = _RecordingStockRepository(
        delayedSearches: {'旧货品': slowResult},
      );
      await pumpPage(tester, stock: stock);

      await tester.enterText(_searchEditable(), '旧货品');
      await tester.pump(const Duration(milliseconds: 301));
      expect(stock.searchQueries, ['旧货品']);

      await tester.enterText(_searchEditable(), '插套分类');
      // 旧请求在新输入 300ms 防抖结束之前返回，也不得抢占右侧分类。
      slowResult.complete({'raw'});
      await tester.pump();
      expect(stock.lastCategoryId, isNot('raw'));
      expect(stock.lastKeyword, isNot('旧货品'));
      expect(_searchText(tester), '插套分类');

      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, isNull);
      expect(find.text('插套分类(SOCKET)'), findsOneWidget);
    },
  );

  testWidgets('a late search cannot replace an explicitly selected category', (
    tester,
  ) async {
    final slowResult = Completer<Set<String>>();
    final stock = _RecordingStockRepository(
      delayedSearches: {'成品': slowResult},
    );
    await pumpPage(tester, stock: stock);

    await tester.enterText(_searchEditable(), '成品');
    await tester.pump(const Duration(milliseconds: 301));
    expect(stock.searchQueries, ['成品']);
    await tester.tap(find.text('成品(FINISHED)'));
    await tester.pump();
    expect(stock.lastCategoryId, 'finished');
    expect(stock.lastKeyword, isNull);

    slowResult.complete({'raw'});
    await tester.pumpAndSettle();
    expect(stock.lastCategoryId, 'finished');
    expect(stock.lastKeyword, isNull);
    expect(_searchText(tester), '成品');
  });

  testWidgets(
    '375px screen opens searchable categories in a drawer and selection closes it',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock, size: const Size(375, 812));
      expect(tester.takeException(), isNull);
      expect(find.byType(UtenSplitView), findsNothing);
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('instant-inventory-open-categories')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsOneWidget,
      );
      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('插套分类(SOCKET)'), findsOneWidget);
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');

      await tester.tap(find.text('插套分类(SOCKET)'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsNothing,
      );
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const Key('instant-inventory-open-categories')),
      );
      await tester.pumpAndSettle();
      expect(_searchText(tester), 'HV-001');
      await tester.tap(find.byKey(const Key('instant-inventory-category-all')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsNothing,
      );
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh preserves the manually selected parent and its goods keyword',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);
      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(find.text('成品(FINISHED)'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'finished');

      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(stock.searchQueries, ['HV-001', 'HV-001']);
      expect(
        stock.lastCategoryId,
        'finished',
        reason: '刷新不能把用户选中的父分类跳回第一个货品命中叶子',
      );
      expect(stock.lastKeyword, 'HV-001');
      expect(_searchText(tester), 'HV-001');
    },
  );

  testWidgets(
    'a delayed refresh cannot resume search after a user selects a category',
    (tester) async {
      final refreshedTree = Completer<List<ProductCategoryNode>>();
      final categories = _ProductCategoryRepo(delayedRefresh: refreshedTree);
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock, categories: categories);
      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      expect(categories.treeCalls, 2);
      await tester.tap(find.text('成品(FINISHED)'));
      await tester.pump();
      expect(stock.lastCategoryId, 'finished');
      final callsAfterSelection = stock.calls;

      refreshedTree.complete(
        await _ProductCategoryRepo().treeWithGoodsCounts(),
      );
      await tester.pumpAndSettle();
      expect(stock.searchQueries, [
        'HV-001',
      ], reason: '手选后应取消旧刷新剩余的搜索定位，避免迟到操作重选分类');
      expect(stock.calls, callsAfterSelection);
      expect(stock.lastCategoryId, 'finished');
      expect(stock.lastKeyword, 'HV-001');
    },
  );

  testWidgets(
    'a failed search shows its error and retry resolves the requested goods',
    (tester) async {
      final stock = _RecordingStockRepository(searchFailuresRemaining: 1);
      await pumpPage(tester, stock: stock);
      final callsBeforeSearch = stock.calls;

      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.textContaining('货品定位失败：定位服务暂不可用'), findsOneWidget);
      expect(find.text('重试搜索'), findsOneWidget);
      expect(
        find.textContaining('未找到'),
        findsNothing,
        reason: '请求失败不得当作无匹配的成功结果',
      );
      expect(stock.calls, callsBeforeSearch);
      expect(stock.lastKeyword, isNull);

      await tester.tap(find.text('重试搜索'));
      await tester.pumpAndSettle();
      expect(stock.searchQueries, ['HV-001', 'HV-001']);
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');
      expect(find.text('插套分类(SOCKET)'), findsOneWidget);
      expect(find.textContaining('货品定位失败'), findsNothing);
      expect(find.text('重试搜索'), findsNothing);
    },
  );

  testWidgets(
    'closing the compact drawer before debounce completes still searches',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock, size: const Size(375, 812));
      await tester.tap(
        find.byKey(const Key('instant-inventory-open-categories')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'HV-001');
      expect(stock.searchQueries, isEmpty);

      // 系统返回直接收起抽屉，不选择节点，也不等待搜索框的防抖。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsNothing,
      );
      expect(stock.searchQueries, ['HV-001']);
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');
      expect(_searchText(tester), 'HV-001');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search completes when resizing across the drawer breakpoint during debounce',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);
      await tester.enterText(_searchEditable(), 'HV-001');
      tester.view.physicalSize = const Size(375, 812);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'socket');
      expect(stock.lastKeyword, 'HV-001');
      expect(_searchText(tester), 'HV-001');
      expect(tester.takeException(), isNull);

      await tester.enterText(_searchEditable(), '原材料');
      tester.view.physicalSize = const Size(1600, 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
      expect(stock.lastKeyword, isNull);
      expect(find.text('原材料(RAW)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'landscape screen keeps category navigation and the table usable',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock, size: const Size(812, 375));
      expect(tester.takeException(), isNull);
      final tree = find.byKey(const Key('instant-inventory-category-tree'));
      final table = find.byType(MasterDataTableView<InstantInventoryRow>);
      expect(tree, findsOneWidget);
      expect(table, findsOneWidget);
      expect(tester.getRect(tree).right, lessThan(tester.getRect(table).left));
      expect(tester.getSize(table).height, greaterThan(0));

      await tester.tap(find.text('原材料(RAW)'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cost column is removed for every account', (tester) async {
    final stock = _RecordingStockRepository();
    await pumpPage(
      tester,
      stock: stock,
      permissions: const <String>{Perm.goodsCostView},
    );

    final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
      find.byType(MasterDataTableView<InstantInventoryRow>),
    );
    final keys = table.columns.map((column) => column.key).toSet();
    // 数量/重量等运营事实列保留；台账金额即使持权也不出现在页面/打印。
    expect(
      keys,
      containsAll(<String>{'weight', 'qty', 'pendingQty', 'moreQty'}),
    );
    expect(keys, isNot(contains('costAmount')));
  });

  testWidgets('warehouse field, defective toggle and count share the toolbar', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    expect(find.text('仓库'), findsOneWidget);
    expect(
      find.byKey(const Key('instant-inventory-category-all')),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilterChip, '含不良品仓'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^共 \d+ 项$')), findsOneWidget);
  });

  // 2026-09-16 颜色/物料系列/单位表头筛选：选桶 → repository 收到对应参数。
  testWidgets('color, series and unit header filters re-query the API', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    MasterDataTableView<InstantInventoryRow> table() =>
        tester.widget<MasterDataTableView<InstantInventoryRow>>(
          find.byType(MasterDataTableView<InstantInventoryRow>),
        );

    table().onFilterChanged('color', 'color-1');
    await tester.pumpAndSettle();
    expect(stock.lastColorId, 'color-1');

    table().onFilterChanged('series', 'X系列');
    await tester.pumpAndSettle();
    expect(stock.lastSeries, 'X系列');

    table().onFilterChanged('unit', 'unit-1');
    await tester.pumpAndSettle();
    expect(stock.lastUnitId, 'unit-1');

    // 左侧换分类只改变分类范围，不丢掉既有仓库和表头筛选。
    await tester.tap(find.byKey(const Key('instant-inventory-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品(FINISHED)'));
    await tester.pumpAndSettle();
    expect(stock.lastCategoryId, 'finished');
    expect(stock.lastWarehouseId, 'w1');
    expect(stock.lastColorId, 'color-1');
    expect(stock.lastSeries, 'X系列');
    expect(stock.lastUnitId, 'unit-1');
    expect(stock.lastIncludeLineSide, isFalse);
    expect(stock.lastIncludeDefective, isTrue);

    // 取消筛选（选「所有」）→ 参数回到 null。
    table().onFilterChanged('unit', null);
    await tester.pumpAndSettle();
    expect(stock.lastUnitId, isNull);
  });

  // ADR-135：库存重量紧跟库存数量；估算「≈」、有库存没称过「未称」、本行无库存「—」，
  // 绝不把未知显示成 0；工具条「重量单位」切换显示单位，导出跟着带固定单位与表头筛选。
  testWidgets('weight follows quantity, marks estimates and unknowns, and '
      'the display unit drives cells and export', (tester) async {
    const rows = <InstantInventoryRow>[
      InstantInventoryRow(
        goodsId: 'g1',
        name: '螺丝',
        qty: 5000,
        weight: 11.55,
        weightEstimated: true,
      ),
      InstantInventoryRow(goodsId: 'g2', name: '垫片', qty: 20),
      InstantInventoryRow(goodsId: 'g3', name: '待检件', qty: 0),
    ];
    final stock = _RecordingStockRepository(rows: rows);
    await pumpPage(tester, stock: stock);

    MasterDataTableView<InstantInventoryRow> table() =>
        tester.widget<MasterDataTableView<InstantInventoryRow>>(
          find.byType(MasterDataTableView<InstantInventoryRow>),
        );
    MasterColumnDef<InstantInventoryRow> weightColumn() =>
        table().columns.firstWhere((c) => c.key == 'weight');

    final keys = [for (final c in table().columns) c.key];
    expect(keys.indexOf('weight'), keys.indexOf('qty') + 1);
    expect(weightColumn().type, 'weight');
    expect(weightColumn().value(rows[0]), '≈11.55 kg');
    expect(weightColumn().value(rows[1]), '未称');
    expect(weightColumn().value(rows[2]), '—');

    UtenExportButton exportButton() =>
        tester.widget<UtenExportButton>(find.byType(UtenExportButton));
    // 「自动」显示单位导出按千克 (文件数值列不混单位)。
    expect(exportButton().queryParams['weightUnit'], 'KG');

    await tester.tap(find.byKey(const ValueKey('weight-display-unit-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weight-unit-option-克')).last);
    await tester.pumpAndSettle();

    expect(weightColumn().value(rows[0]), '≈11,550 g');
    expect(exportButton().queryParams['weightUnit'], 'G');

    // 表头筛选同样进入导出口径。
    table().onFilterChanged('color', 'color-1');
    await tester.pumpAndSettle();
    expect(exportButton().queryParams['colorId'], 'color-1');
    // 偏好防抖推送计时器走完再结束 (未登录不推服务端)。
    await tester.pump(const Duration(seconds: 1));
  });
}

Finder _searchBar() {
  final drawer = find.byType(Drawer);
  final search = find.byKey(const Key('instant-inventory-search'));
  return drawer.evaluate().isEmpty
      ? search
      : find.descendant(of: drawer, matching: search);
}

Finder _searchEditable() =>
    find.descendant(of: _searchBar(), matching: find.byType(EditableText));

Finder _clearSearch() => find.descendant(
  of: _searchBar(),
  matching: find.byIcon(Icons.close_rounded),
);

String _searchText(WidgetTester tester) =>
    tester.widget<EditableText>(_searchEditable()).controller.text;

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());

  /// 仓库字典返一主一子（测仓库侧滑面板的主/子层级与子树聚合），其余字典返空表。
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('warehouses/dict')
      ? const <Map<String, dynamic>>[
          {'id': 'w1', 'name': '成品仓库', 'code': 'C04'},
          {'id': 'w1a', 'name': '成品不良品仓', 'code': 'C0401', 'parentId': 'w1'},
        ]
      : const <Map<String, dynamic>>[];
}

class _RecordingStockRepository extends StockQueryRepository {
  _RecordingStockRepository({
    this.delayedSearches = const {},
    this.searchFailuresRemaining = 0,
    this.rows = const <InstantInventoryRow>[],
  }) : super(_InventoryApi());

  final List<InstantInventoryRow> rows;
  final Map<String, Completer<Set<String>>> delayedSearches;
  int searchFailuresRemaining;
  final searchQueries = <String>[];
  final searchRootScopes = <Set<String>>[];

  int calls = 0;
  String? lastCategoryId;
  String? lastWarehouseId;
  String? lastKeyword;
  String? lastOwningWarehouse;
  String? lastColorId;
  String? lastSeries;
  String? lastUnitId;
  bool? lastIncludeDefective;
  bool? lastIncludeLineSide;

  @override
  Future<Set<String>> instantInventorySearchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
  }) async {
    searchQueries.add(keyword);
    searchRootScopes.add(Set<String>.from(categoryRootIds));
    if (searchFailuresRemaining > 0) {
      searchFailuresRemaining--;
      throw ApiException('SEARCH_UNAVAILABLE', '定位服务暂不可用');
    }
    final pending = delayedSearches[keyword];
    if (pending != null) return pending.future;
    return keyword == 'HV-001' ? {'socket'} : <String>{};
  }

  @override
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = true,
    bool includeLineSide = false,
    String? keyword,
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? sort,
    String? order,
  }) {
    calls++;
    lastCategoryId = categoryId;
    lastWarehouseId = warehouseId;
    lastIncludeDefective = includeDefective;
    lastIncludeLineSide = includeLineSide;
    lastKeyword = keyword;
    lastOwningWarehouse = owningWarehouse;
    lastColorId = colorId;
    lastSeries = series;
    lastUnitId = unitId;
    return Future.value(
      PagedResult<InstantInventoryRow>(
        items: rows,
        page: 1,
        size: 20,
        total: rows.length,
        totalPages: 1,
      ),
    );
  }
}

class _ProductCategoryRepo implements ProductCategoryRepository {
  _ProductCategoryRepo({this.delayedRefresh});

  final Completer<List<ProductCategoryNode>>? delayedRefresh;
  int treeCalls = 0;

  @override
  Future<List<ProductCategoryNode>> tree() => treeWithGoodsCounts();

  /// A three-level branch verifies locating a leaf without opening each parent.
  /// Empty legacy roots remain hidden, as before the split-view change.
  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() async {
    treeCalls++;
    if (treeCalls > 1 && delayedRefresh != null) return delayedRefresh!.future;
    return <ProductCategoryNode>[
      ProductCategoryNode(
        id: 'goods-root',
        code: 'G',
        name: '货品资料',
        level: 0,
        goodsCount: 4,
        children: [
          ProductCategoryNode(
            id: 'finished',
            code: 'FINISHED',
            name: '成品',
            level: 1,
            goodsCount: 3,
            children: [
              ProductCategoryNode(
                id: 'connectors',
                code: 'CONNECTORS',
                name: '连接器',
                level: 2,
                goodsCount: 3,
                children: [
                  ProductCategoryNode(
                    id: 'socket',
                    code: 'SOCKET',
                    name: '插套分类',
                    level: 3,
                    goodsCount: 3,
                    children: const <ProductCategoryNode>[],
                  ),
                ],
              ),
            ],
          ),
          ProductCategoryNode(
            id: 'raw',
            code: 'RAW',
            name: '原材料',
            level: 1,
            goodsCount: 1,
            children: const <ProductCategoryNode>[],
          ),
        ],
      ),
      ProductCategoryNode(
        id: 'orphan',
        code: 'ORPHAN',
        name: '未分类（历史孤儿）',
        level: 0,
        goodsCount: 0,
        children: const <ProductCategoryNode>[],
      ),
    ];
  }

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDeletePreview> deletePreview(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}
