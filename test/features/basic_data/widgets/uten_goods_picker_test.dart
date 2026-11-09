import 'package:uten_imp/features/basic_data/repositories/business_reference_repository.dart';
import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_goods_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';

void main() {
  testWidgets(
    'completed same-query Enter refreshes category locations after an external category move',
    (tester) async {
      final repository = _FakeGoodsRepository()
        ..searchItemsOverride = const [_goodsA]
        ..searchCategoryIdsOverride = {'section-a'};
      await _pumpPicker(tester, repository);
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      UtenCategoryTreeView<ProductCategoryNode> tree() =>
          tester.widget(find.byType(UtenCategoryTreeView<ProductCategoryNode>));
      expect(repository.searchQueries, ['G-']);
      expect(repository.searchCategoryIdQueries, ['G-']);
      expect(tree().visibleFilterIds, {'section-a'});
      repository.searchItemsOverride = const [_goodsB];
      repository.searchCategoryIdsOverride = {'section-b'};
      await tester.showKeyboard(_searchEditable());
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.searchQueries, ['G-', 'G-']);
      expect(repository.searchCategoryIdQueries, ['G-', 'G-']);
      expect(repository.globalFacetScopes, hasLength(2));
      expect(tree().visibleFilterIds, {'section-b'});
      expect(_goodsName('连接器乙'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search category facets retain the current category and original business roots',
    (tester) async {
      final repository = _FakeGoodsRepository();
      final facetApi = _FacetApi();
      await _pumpPicker(
        tester,
        repository,
        facetRepository: GoodsFacetRepository(
          facetApi,
          queryBasePath: '/business-references/goods',
        ),
      );

      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分区乙'));
      await tester.pumpAndSettle();
      expect(repository.searchCategoryScopes.last, 'section-b');
      expect(repository.globalFacetCategories, [null, 'section-b']);
      expect(repository.globalFacetScopes, [
        {'finished-root'},
        {'finished-root'},
      ]);
      expect(
        repository.globalFacetScopes.last,
        repository.searchRootScopes.last,
      );
      await tester.tap(find.text('货品名称'));
      await tester.pumpAndSettle();
      expect(facetApi.queries, hasLength(1));
      expect(
        facetApi.queries.single['categoryId'],
        repository.searchCategoryScopes.last,
      );
      expect(
        (facetApi.queries.single['categoryRootIds'] as List).toSet(),
        repository.searchRootScopes.last,
      );
      expect(facetApi.queries.single['keyword'], 'G-');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fresh authorized rows can be selected and confirmed while auxiliary location is pending',
    (tester) async {
      final gate = Completer<Set<String>>();
      final repository = _FakeGoodsRepository()..locationGate = gate;
      GoodsListItem? selected;
      await _pumpPicker(
        tester,
        repository,
        onSelected: (value) => selected = value,
      );
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      await tester.pump();
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byKey(const Key('goods-picker-paged-list')),
      );
      expect(table.isLoading, false);
      expect(table.loadingMore, false);
      expect(repository.searchQueries, ['G-']);
      expect(repository.searchCategoryIdQueries, ['G-']);
      expect(gate.isCompleted, false);
      await tester.tap(_goodsName('连接器甲'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'goods-a');
      expect(_widePickerSheet(), findsNothing);
      gate.complete({'section-a', 'section-b'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached rows cannot be confirmed before their category metadata gate finishes',
    (tester) async {
      final repository = _FakeGoodsRepository(splitAcrossPages: true);
      GoodsListItem? selected;
      await _pumpPicker(
        tester,
        repository,
        onSelected: (value) => selected = value,
      );
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(_goodsName('连接器甲'));
      await tester.pump();
      final gate = repository.locationGate = Completer<Set<String>>();
      tester
          .widget<MasterDataTableView<GoodsListItem>>(
            find.byKey(const Key('goods-picker-paged-list')),
          )
          .onPageChange!(2);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(selected, isNull);
      expect(_widePickerSheet(), findsOneWidget);
      expect(gate.isCompleted, false);
      gate.complete({'section-a', 'section-b'});
      await tester.pumpAndSettle();
      await tester.tap(_goodsName('连接器乙'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'goods-b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing raw input cannot confirm an earlier selection during debounce',
    (tester) async {
      final repository = _FakeGoodsRepository();
      GoodsListItem? selected;
      await _pumpPicker(
        tester,
        repository,
        onSelected: (value) => selected = value,
      );
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(_goodsName('连接器甲'));
      await tester.pump();
      final gate = repository.categoryGate =
          Completer<PagedResult<GoodsListItem>>();
      // Row selection unfocuses the real native text input. Re-open its input
      // connection before sending the replacement editing value, as a user
      // does by clicking the search field again.
      await tester.tap(_searchEditable());
      await tester.pump();
      expect(
        tester.widget<EditableText>(_searchEditable()).focusNode.hasFocus,
        true,
      );
      await tester.enterText(_searchEditable(), '');
      expect(
        tester.widget<EditableText>(_searchEditable()).controller.text,
        isEmpty,
      );
      await tester.pump();
      expect(
        tester
            .widget<MasterDataTableView<GoodsListItem>>(
              find.byKey(const Key('goods-picker-paged-list')),
            )
            .isLoading,
        true,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(selected, isNull);
      expect(_widePickerSheet(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      expect(repository.listCalls, hasLength(1));
      expect(repository.listCalls.single, ('section-a', null));
      expect(
        tester
            .widget<MasterDataTableView<GoodsListItem>>(
              find.byKey(const Key('goods-picker-paged-list')),
            )
            .isLoading,
        true,
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(selected, isNull);
      expect(gate.isCompleted, false);
      expect(_widePickerSheet(), findsOneWidget);
      gate.complete(_page(const [_goodsA], page: 1, size: 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'goods-a');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied auxiliary category location still retires fresh selected rows',
    (tester) async {
      final gate = Completer<Set<String>>();
      final repository = _FakeGoodsRepository()..locationGate = gate;
      GoodsListItem? selected;
      await _pumpPicker(
        tester,
        repository,
        onSelected: (value) => selected = value,
      );
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      await tester.pump();
      await tester.tap(_goodsName('连接器甲'));
      await tester.pump();
      gate.completeError(ApiException('FORBIDDEN', '读取权限已撤回', httpStatus: 403));
      await tester.pumpAndSettle();
      expect(_widePickerSheet(), findsNothing);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-query Enter rechecks completed goods results without duplicating an active read',
    (tester) async {
      final repository = _FakeGoodsRepository(delayedQuery: 'G-');
      await _pumpPicker(tester, repository);
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'G-');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      await tester.showKeyboard(_searchEditable());
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.showKeyboard(_searchEditable());
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 400));
      expect(repository.searchQueries, ['G-']);
      repository.completeDelayedSearch(const [_goodsA]);
      await tester.pumpAndSettle();
      repository.delayedQuery = null;
      repository.searchItemsOverride = const [_goodsB];
      await tester.showKeyboard(_searchEditable());
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.searchQueries, ['G-', 'G-']);
      expect(_goodsName('连接器乙'), findsOneWidget);
      expect(_goodsName('连接器甲'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'default goods picker cannot reopen a stale tree after permission ABA',
    (tester) async {
      final epoch = _TestPickerEpoch();
      final categories = _HeldCategoryRepository();
      GoodsListItem? selected;
      await _pumpPicker(
        tester,
        _FakeGoodsRepository(),
        onSelected: (value) => selected = value,
        categories: categories,
        epoch: epoch,
      );
      await tester.tap(find.byKey(const Key('open-goods-picker')));
      await tester.pump();
      epoch.advance();
      await tester.pump();
      epoch.advance();
      categories.pending.complete(_tree);
      await tester.pumpAndSettle();
      expect(_widePickerSheet(), findsNothing);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single picker can opt into double-click confirmation', (
    tester,
  ) async {
    GoodsListItem? selected;
    await _pumpPicker(
      tester,
      _FakeGoodsRepository(),
      confirmOnDoubleTap: true,
      onSelected: (value) => selected = value,
    );
    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    await tester.tap(_goodsName('连接器甲'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(selected, isNull);
    await tester.tap(_goodsName('连接器甲'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'goods-a');
    expect(_widePickerSheet(), findsNothing);
  });

  testWidgets('点击侧边阴影取消多选，不提交勾选且再次打开没有旧选择', (tester) async {
    final repository = _FakeGoodsRepository();
    final results = <List<GoodsListItem>>[];
    await _pumpMultiPicker(tester, repository, results);
    await tester.tap(find.byKey(const Key('open-multi-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    await tester.tap(_goodsName('连接器甲'));
    await tester.pump();
    expect(find.text('确定(1)'), findsOneWidget);
    await tester.tapAt(const Offset(10, 450));
    await tester.pumpAndSettle();
    expect(_widePickerSheet(), findsNothing);
    expect(results, hasLength(1));
    expect(results.single, isEmpty);
    await tester.tap(find.byKey(const Key('open-multi-picker')));
    await tester.pumpAndSettle();
    expect(find.text('确定(0)'), findsOneWidget);
    expect(results, hasLength(1));
  });

  testWidgets('整范围读取完成后本地滚动与多选不再加载其他批次', (tester) async {
    final repository = _FakeGoodsRepository(
      splitAcrossPages: true,
      delayedPage: 2,
    );
    final results = <List<GoodsListItem>>[];
    await _pumpMultiPicker(tester, repository, results);
    await tester.tap(find.byKey(const Key('open-multi-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    expect(repository.searchPages, [1, 2]);
    expect(_goodsName('连接器甲'), findsNothing, reason: '尚未完成的摘要集合不能冒充完整列表');
    repository.completeDelayedPage();
    await tester.pumpAndSettle();
    expect(_goodsName('连接器甲'), findsOneWidget);
    expect(_goodsName('连接器乙'), findsOneWidget);
    final list = find.byKey(const Key('goods-picker-paged-list'));
    final originalElement = tester.element(list);
    await tester.tap(_goodsName('连接器甲'));
    await tester.pump();
    await _wheelOnGoods(tester, '连接器甲', 100);
    await _wheelOnGoods(tester, '连接器乙', -100);
    await tester.pumpAndSettle();
    expect(repository.searchPages, [1, 2]);
    expect(tester.element(list), same(originalElement));
    expect(repository.searchPolicies, everyElement((true, true)));
    await tester.tap(_goodsName('连接器乙'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.map((goods) => goods.id), ['goods-a', 'goods-b']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整查询中途失败可显式重试，完成后滚动不重查', (tester) async {
    final repository = _FakeGoodsRepository(splitAcrossPages: true)
      ..failNextPage = 2;
    GoodsListItem? selected;
    await _pumpPicker(
      tester,
      repository,
      onSelected: (value) => selected = value,
    );
    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(repository.searchPages, [1, 2]);
    expect(_goodsName('连接器乙'), findsNothing);
    expect(selected, isNull);
    await tester.tap(find.text('重试').last);
    await tester.pumpAndSettle();
    expect(repository.searchPages, [1, 2, 1, 2]);
    expect(_goodsName('连接器甲'), findsOneWidget);
    expect(_goodsName('连接器乙'), findsOneWidget);
    await _wheelOnGoods(tester, '连接器甲', 100);
    await _wheelOnGoods(tester, '连接器乙', -100);
    await tester.pumpAndSettle();
    expect(repository.searchPages, [1, 2, 1, 2]);
    await tester.tap(_goodsName('连接器甲'));
    await tester.pump();
    expect(selected, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'goods-a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('表头筛选下拉带候选桶：分类浏览与搜索态都按当前范围取 facets', (tester) async {
    final repository = _FakeGoodsRepository();
    await _pumpPicker(tester, repository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    // 懒载：点分类才加载货品，同时拉该分类子树的候选桶。
    await tester.tap(find.text('分区甲'));
    await tester.pumpAndSettle();
    expect(repository.facetsCalls, ['section-a']);

    // 列头漏斗下拉给候选值，不再显示「无匹配项」。
    await tester.tap(find.text('货品名称'));
    await tester.pumpAndSettle();
    expect(find.text('连接器甲 (3)'), findsOneWidget);
    expect(find.text('无匹配项'), findsNothing);
    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();

    // 搜索态：候选桶改走全局 facets，并带 picker 的业务范围根。
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(repository.globalFacetScopes, [
      {'finished-root'},
    ]);
    await tester.tap(find.text('货品名称'));
    await tester.pumpAndSettle();
    expect(find.text('连接器乙 (7)'), findsOneWidget);
    expect(find.text('无匹配项'), findsNothing);
  });

  testWidgets('统一搜索受 picker scope 限定并定位所有命中分类', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    final sheet = _widePickerSheet();
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.byType(TextField)),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(_searchTextField()).decoration?.hintText,
      '搜索分类/货品名称或编号',
    );

    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['G-']);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);
    // 展示提升不改变真实范围，根自身直接归属的货品也仍在授权查询范围内。
    expect(goodsRepository.searchRootScopes.single, {'finished-root'});
    expect(_goodsName('连接器甲'), findsOneWidget);
    expect(find.textContaining('G-001'), findsOneWidget);
    expect(_goodsName('连接器乙'), findsOneWidget);
    final goodsTable = tester.widget<MasterDataTableView<GoodsListItem>>(
      find.byKey(const Key('goods-picker-paged-list')),
    );
    expect(goodsTable.columns.map((column) => column.key), [
      'name',
      'code',
      'series',
      'model',
      'spec',
      'colorLegacyId',
      'unitLegacyId',
      'stockQty',
    ]);
    final second = goodsTable.items.firstWhere(
      (goods) => goods.id == 'goods-b',
    );
    expect(
      goodsTable.columns
          .firstWhere((column) => column.key == 'code')
          .value(second),
      'G-002',
    );
    expect(
      goodsTable.columns
          .firstWhere((column) => column.key == 'colorLegacyId')
          .value(second),
      '黑色',
    );

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.showSearch, isFalse);
    expect(tree.visibleFilterIds, {'section-a', 'section-b'});
    expect(tree.selectedIds, isEmpty);

    // 明确点击分类成为实际范围，关键词仍保留，右边仍是单表。
    final listCallsBeforeTap = goodsRepository.listCalls.length;
    await tester.tap(find.text('分区乙'));
    await tester.pumpAndSettle();
    expect(goodsRepository.listCalls.length, listCallsBeforeTap);
    expect(goodsRepository.searchCategoryScopes.last, 'section-b');
    expect(_goodsName('连接器甲'), findsNothing);
    expect(_goodsName('连接器乙'), findsOneWidget);
    expect(tester.widget<TextField>(_searchTextField()).controller?.text, 'G-');

    // 清除只退出搜索，保留当前位置并恢复分类列表（UtenSearchBar 内置清除按钮）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('uten-goods-picker-search')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(goodsRepository.listCalls.last, ('section-a', null));
    final clearedTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        );
    expect(clearedTree.visibleFilterIds, isNull);
    expect(clearedTree.selectedIds, {'section-a'});
  });

  testWidgets('右侧列表与货品资料同款排序（编号升序）', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    // 点分类：分类列表通道带编号升序（与货品资料页 defaultSortKey: 'code' 同款）。
    await tester.tap(find.text('分区乙'));
    await tester.pumpAndSettle();
    expect(goodsRepository.listSortOrders.single, ('code', 'asc'));

    // 全局搜索通道同款排序。
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(goodsRepository.searchSortOrders.single, ('code', 'asc'));
  });

  testWidgets('旧后端忽略 scope 时客户端拒绝展示范围外货品', (tester) async {
    final goodsRepository = _FakeGoodsRepository(returnOutOfScopeItem: true);
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'RAW-001');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
    expect(find.text('范围外原料(RAW-001)'), findsNothing);
  });

  testWidgets('服务端空结果不回退整类列表，显式分类范围保留关键词', (tester) async {
    final goodsRepository = _FakeGoodsRepository(categoryOnlyQuery: '分区');
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '分区');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['分区']);
    expect(goodsRepository.searchCategoryIdQueries, ['分区']);
    expect(goodsRepository.listCalls, isEmpty);
    expect(_goodsName('连接器甲'), findsNothing);

    await tester.tap(find.text('分区乙'));
    await tester.pumpAndSettle();

    expect(goodsRepository.listCalls, isEmpty);
    expect(
      tester.widget<TextField>(_searchTextField()).controller?.text,
      '分区',
      reason: '明确分类范围不能把关键词悄悄清掉',
    );
  });

  testWidgets('整范围搜索汇总全部分类且滚动不再查询定位', (tester) async {
    final goodsRepository = _FakeGoodsRepository(splitAcrossPages: true);
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'section-a', 'section-b'});
    expect(goodsRepository.searchPages, [1, 2]);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);

    await _wheelOnGoods(tester, '连接器甲', 100);
    await tester.pumpAndSettle();

    final pageTwoTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        );
    expect(pageTwoTree.visibleFilterIds, {'section-a', 'section-b'});
    expect(goodsRepository.searchPages, [1, 2]);
    expect(goodsRepository.searchCategoryIdQueries, [
      'G-',
    ], reason: '完整结果本地滚动不再重查定位');
  });

  testWidgets('旧慢请求晚返回不会覆盖较新的搜索结果', (tester) async {
    final goodsRepository = _FakeGoodsRepository(delayedQuery: '旧关键词');
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '旧关键词');
    await tester.pump(const Duration(milliseconds: 301));
    expect(goodsRepository.searchQueries, ['旧关键词']);

    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(_goodsName('连接器甲'), findsOneWidget);
    expect(find.textContaining('G-001'), findsOneWidget);

    goodsRepository.completeDelayedSearch(const [_outOfScopeGoods]);
    await tester.pumpAndSettle();

    expect(_goodsName('连接器甲'), findsOneWidget);
    expect(find.textContaining('G-001'), findsOneWidget);
    expect(find.text('范围外原料(RAW-001)'), findsNothing);
    expect(find.text('搜索货品失败，请稍后重试'), findsNothing);
  });

  testWidgets('定位未完成时点分类使旧全局响应失效，关键词继续带分类范围', (tester) async {
    final repository = _FakeGoodsRepository(delayedQuery: '分区');
    await _pumpPicker(tester, repository);
    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '分区');
    await tester.pump(const Duration(milliseconds: 301));

    // 分类名可立即命中，货品定位尚在请求中；此时不得把搜索悄悄变成全分类浏览。
    await tester.tap(find.text('分区乙'));
    await tester.pump();
    expect(repository.listCalls, isEmpty);
    expect(repository.searchCategoryScopes.last, 'section-b');
    repository.completeDelayedSearch(const [_goodsA]);
    await tester.pumpAndSettle();
    expect(repository.listCalls, isEmpty);
    expect(tester.widget<TextField>(_searchTextField()).controller?.text, '分区');
  });

  testWidgets('输入防抖期间点分类立即查询该范围，旧防抖不重复发起', (tester) async {
    final repository = _FakeGoodsRepository();
    await _pumpPicker(tester, repository);
    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '分区');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('分区乙'));
    await tester.pumpAndSettle();
    expect(repository.listCalls, isEmpty);
    expect(repository.searchQueries, ['分区']);
    expect(repository.searchCategoryScopes, ['section-b']);
    expect(_goodsName('连接器甲'), findsNothing);
    expect(_goodsName('连接器乙'), findsOneWidget);
  });

  testWidgets('单根提升 + 无缩进层级色 + 可拖分割线', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    // sellable 过滤后只剩单根「成品」，自动提升：包装根不再显示，直接列子类。
    expect(find.text('成品'), findsNothing);
    expect(find.text('分区甲'), findsOneWidget);
    expect(find.text('分区乙'), findsOneWidget);

    // medium+ 布局换成 UtenSplitView（可拖分割线，货品资料页同款）。
    expect(find.byType(UtenSplitView), findsOneWidget);

    // 一级行（提升后的三个根分类）：深绿实底（无缩进层级色模式）。整列卡片
    // 口径（2026-10-18）：首行上两角、末行下两角用系统圆角，中间行方角相接。
    final flatRows = find.byWidgetPredicate(
      (widget) => widget is Material && widget.color == UtenColors.deepGreen,
    );
    expect(flatRows, findsNWidgets(3));
    final rowRadii = [
      for (final row in tester.widgetList<Material>(flatRows))
        row.borderRadius as BorderRadius,
    ];
    expect(
      rowRadii[0].topLeft,
      const Radius.circular(UtenRadius.md),
      reason: '首行上两角为系统圆角',
    );
    expect(rowRadii[0].bottomLeft, Radius.zero);
    expect(rowRadii[1], BorderRadius.zero, reason: '中间行方角相接');
    expect(
      rowRadii[2].bottomLeft,
      const Radius.circular(UtenRadius.md),
      reason: '末行下两角为系统圆角',
    );
    expect(rowRadii[2].topLeft, Radius.zero);
    // flat 行间有 1px 分隔线：收起时整列同色（全是一级深绿行）也分得清一行一行。
    expect(
      find.descendant(
        of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              ((widget.decoration as BoxDecoration).border?.bottom.width ??
                      0) ==
                  1,
        ),
      ),
      findsWidgets,
    );
    // 左树默认宽度 = 最长一行内容的实测宽度（不取固定 240）。
    final split = tester.widget<UtenSplitView>(find.byType(UtenSplitView));
    expect(split.persistenceKey, 'goodsPicker.categoryTree');
    expect(split.initialLeadingWidth, greaterThan(240));
  });

  testWidgets('多选：底部「已选 N 项」滑层可逐项取消选择', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    final results = <List<GoodsListItem>>[];
    await _pumpMultiPicker(tester, goodsRepository, results);

    await tester.tap(find.byKey(const Key('open-multi-picker')));
    await tester.pumpAndSettle();

    // 懒载：先点根分类（提升后 = 分区甲）加载货品列表，再点货品行勾选。
    await tester.tap(find.text('分区甲'));
    await tester.pumpAndSettle();
    await tester.tap(_goodsName('连接器甲'));
    await tester.pumpAndSettle();
    final selectedTable = tester.widget<MasterDataTableView<GoodsListItem>>(
      find.byKey(const Key('goods-picker-paged-list')),
    );
    expect(selectedTable.selectedIds, {'goods-a'});
    // 切到分区乙再勾一条。
    await tester.tap(find.text('分区乙'));
    await tester.pumpAndSettle();
    await tester.tap(_goodsName('连接器乙'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);

    // 点「已选 2 项」从底部滑出已选清单。
    await tester.tap(find.byKey(const Key('goods-picker-selected-summary')));
    await tester.pumpAndSettle();
    expect(find.text('已选货品（2）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goods-picker-selected-row-goods-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('goods-picker-selected-row-goods-b')),
      findsOneWidget,
    );

    // 清单内逐项取消一条，标题与外部胶囊计数同步。
    await tester.tap(
      find.byKey(const ValueKey('goods-picker-selected-remove-goods-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选货品（1）'), findsOneWidget);

    // 收起滑层后确定，只返回剩余一条。
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect(results.single.map((goods) => goods.id), ['goods-b']);
  });
}

Future<void> _wheelOnGoods(
  WidgetTester tester,
  String name,
  double delta,
) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(_goodsName(name))),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpPicker(
  WidgetTester tester,
  GoodsRepository goodsRepository, {
  ValueChanged<GoodsListItem?>? onSelected,
  bool confirmOnDoubleTap = false,
  ProductCategoryRepository? categories,
  _TestPickerEpoch? epoch,
  GoodsFacetRepository? facetRepository,
}) async {
  tester.view.devicePixelRatio = 1;
  // Leave enough room for the fixture's longest complete category row and
  // the right pane. A 720px drawer now correctly falls back to its directory.
  tester.view.physicalSize = const Size(1800, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (epoch != null) exportContextEpochProvider.overrideWith(() => epoch),
        if (facetRepository != null)
          businessGoodsFacetRepositoryProvider.overrideWithValue(
            facetRepository,
          ),
        businessGoodsCategoryRepositoryProvider.overrideWithValue(
          categories ?? _FakeCategoryRepository(),
        ),
        businessGoodsReferenceRepositoryProvider.overrideWithValue(
          goodsRepository,
        ),
      ],
      child: MaterialApp(
        home: _PickerHarness(
          onSelected: onSelected,
          confirmOnDoubleTap: confirmOnDoubleTap,
        ),
      ),
    ),
  );
}

Future<void> _pumpMultiPicker(
  WidgetTester tester,
  GoodsRepository goodsRepository,
  List<List<GoodsListItem>> results,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1800, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        businessGoodsCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        businessGoodsReferenceRepositoryProvider.overrideWithValue(
          goodsRepository,
        ),
      ],
      child: MaterialApp(home: _MultiPickerHarness(results: results)),
    ),
  );
}

// 2026-10-17 滑窗口径：1800 屏 browse 档 = max(720, 1800 × 75%) = 1350。
Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 1350 &&
      widget.height == double.infinity,
);

/// 统一搜索已换成 UtenSearchBar：key 在组件上，输入/取控件须定位其内部输入框。
Finder _searchEditable() => find.descendant(
  of: find.byKey(const Key('uten-goods-picker-search')),
  matching: find.byType(EditableText),
);

Finder _searchTextField() => find.descendant(
  of: find.byKey(const Key('uten-goods-picker-search')),
  matching: find.byType(TextField),
);

class _PickerHarness extends ConsumerWidget {
  const _PickerHarness({this.onSelected, this.confirmOnDoubleTap = false});

  final ValueChanged<GoodsListItem?>? onSelected;
  final bool confirmOnDoubleTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ElevatedButton(
        key: const Key('open-goods-picker'),
        onPressed: () async {
          final selected = await showUtenGoodsPicker(
            context,
            ref,
            confirmOnDoubleTap: confirmOnDoubleTap,
          );
          onSelected?.call(selected);
        },
        child: const Text('打开货品选择'),
      ),
    );
  }
}

class _MultiPickerHarness extends ConsumerWidget {
  const _MultiPickerHarness({required this.results});

  final List<List<GoodsListItem>> results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ElevatedButton(
        key: const Key('open-multi-picker'),
        onPressed: () async {
          final picked = await showUtenGoodsPickerMulti(
            context,
            ref,
            scope: UtenGoodsPickerScope.sellable,
          );
          results.add(picked);
        },
        child: const Text('打开多选货品选择'),
      ),
    );
  }
}

class _FakeCategoryRepository extends Fake
    implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => _tree;

  // 货品选择器不消费货品计数；沿用无计数树即可。
  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() async => _tree;
}

class _HeldCategoryRepository extends _FakeCategoryRepository {
  final pending = Completer<List<ProductCategoryNode>>();
  @override
  Future<List<ProductCategoryNode>> tree() => pending.future;
}

class _TestPickerEpoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

class _FacetApi extends ApiClient {
  _FacetApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add({...?query});
    return {
      'items': <Map<String, dynamic>>[
        {'value': 'B-value', 'label': 'B-value', 'count': 1},
      ],
      'hasMore': false,
    };
  }
}

class _FakeGoodsRepository extends Fake implements GoodsRepository {
  _FakeGoodsRepository({
    this.returnOutOfScopeItem = false,
    this.splitAcrossPages = false,
    this.delayedQuery,
    this.categoryOnlyQuery,
    this.delayedPage,
  });

  final bool returnOutOfScopeItem;
  final bool splitAcrossPages;
  String? delayedQuery;
  List<GoodsListItem>? searchItemsOverride;
  Set<String>? searchCategoryIdsOverride;
  Completer<Set<String>>? locationGate;
  Completer<PagedResult<GoodsListItem>>? categoryGate;
  final String? categoryOnlyQuery;
  final int? delayedPage;
  int? failNextPage;
  final _delayedSearch = Completer<PagedResult<GoodsListItem>>();
  final _delayedPage = Completer<PagedResult<GoodsListItem>>();
  final searchQueries = <String>[];
  final searchPages = <int>[];
  final searchRootScopes = <Set<String>>[];
  final searchCategoryScopes = <String?>[];
  final searchSortOrders = <(String?, String?)>[];
  final searchPolicies = <(bool, bool)>[];
  final searchCategoryIdQueries = <String>[];
  final listCalls = <(String, String?)>[];
  final listSortOrders = <(String?, String?)>[];
  final facetsCalls = <String>[];
  final globalFacetScopes = <Set<String>>[];
  final globalFacetCategories = <String?>[];

  void completeDelayedSearch(List<GoodsListItem> items) {
    _delayedSearch.complete(_page(items, page: 1, size: 100));
  }

  // The split server keeps its own one-row page size (row offset == page - 1),
  // so the complete reader continues exactly on that size.
  void completeDelayedPage() => _delayedPage.complete(
    const PagedResult(
      items: [_goodsB],
      page: 2,
      size: 1,
      total: 2,
      totalPages: 2,
    ),
  );

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
    String? categoryId,
    bool includeRelated = false,
  }) async {
    searchQueries.add(keyword);
    searchPages.add(page);
    searchRootScopes.add({...categoryRootIds});
    searchCategoryScopes.add(categoryId);
    searchSortOrders.add((sort, order));
    searchPolicies.add((excludeDisabled, excludeStub));
    if (page == failNextPage) {
      failNextPage = null;
      throw StateError('page temporarily unavailable');
    }
    if (page == delayedPage) return _delayedPage.future;
    if (keyword == delayedQuery && categoryId == null) {
      return _delayedSearch.future;
    }
    if (searchItemsOverride != null) {
      return _page(searchItemsOverride!, page: page, size: size);
    }
    if (keyword == categoryOnlyQuery) {
      return _page(const [], page: page, size: size);
    }
    if (categoryId != null) {
      return _page(
        categoryId == 'section-b' ? const [_goodsB] : const [_goodsA],
        page: page,
        size: size,
      );
    }
    if (splitAcrossPages) {
      // One row per server page: page/size/total/totalPages stay exact.
      return PagedResult(
        items: page == 1 ? const [_goodsA] : const [_goodsB],
        page: page,
        size: 1,
        total: 2,
        totalPages: 2,
      );
    }
    return _page(
      returnOutOfScopeItem
          ? const [_outOfScopeGoods]
          : const [_goodsA, _goodsB],
      page: page,
      size: size,
    );
  }

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? categoryId,
    bool includeRelated = false,
  }) async {
    searchCategoryIdQueries.add(keyword);
    if (locationGate != null) return locationGate!.future;
    if (searchCategoryIdsOverride != null) return searchCategoryIdsOverride!;
    if (returnOutOfScopeItem) return const {'raw-root'};
    if (keyword == categoryOnlyQuery) return const <String>{};
    if (categoryId != null) return {categoryId};
    return const {'section-a', 'section-b'};
  }

  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  }) async {
    listCalls.add((categoryId!, keyword));
    listSortOrders.add((sort, order));
    if (categoryGate != null) return categoryGate!.future;
    final items = categoryId == 'section-b' ? const [_goodsB] : const [_goodsA];
    return _page(items, page: page, size: size);
  }

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    facetsCalls.add(categoryId);
    return const GoodsFacets(
      fields: {
        'name': [MasterFacetBucket(value: '连接器甲', count: 3)],
      },
      nullCounts: {},
    );
  }

  @override
  Future<GoodsFacets> globalFacets({
    String? categoryId,
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    Set<String> categoryRootIds = const {},
  }) async {
    globalFacetScopes.add({...categoryRootIds});
    globalFacetCategories.add(categoryId);
    return const GoodsFacets(
      fields: {
        'name': [MasterFacetBucket(value: '连接器乙', count: 7)],
      },
      nullCounts: {},
    );
  }
}

PagedResult<GoodsListItem> _page(
  List<GoodsListItem> items, {
  required int page,
  required int size,
}) => PagedResult(
  items: items,
  page: page,
  size: size,
  total: items.length,
  totalPages: 1,
);

const _goodsA = GoodsListItem(
  id: 'goods-a',
  code: 'G-001',
  name: '连接器甲',
  categoryId: 'section-a',
);
const _goodsB = GoodsListItem(
  id: 'goods-b',
  code: 'G-002',
  name: '连接器乙',
  categoryId: 'section-b',
  colorName: '黑色',
);
const _outOfScopeGoods = GoodsListItem(
  id: 'raw-goods',
  code: 'RAW-001',
  name: '范围外原料',
  categoryId: 'raw-root',
);

final _tree = <ProductCategoryNode>[
  ProductCategoryNode(
    id: 'finished-root',
    code: 'FINISHED',
    name: '成品',
    level: 0,
    children: [
      ProductCategoryNode(
        id: 'section-a',
        code: 'A',
        name: '分区甲',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
      ProductCategoryNode(
        id: 'section-b',
        code: 'B',
        name: '分区乙',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
      ProductCategoryNode(
        id: 'long-cat',
        code: 'LONG',
        name: '名字特别特别特别特别特别特别长的分类',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
    ],
  ),
  ProductCategoryNode(
    id: 'raw-root',
    code: 'RAW',
    name: '原材料',
    level: 0,
    legacyId: 2113,
    children: const [],
  ),
];

Finder _goodsName(String name) => find.descendant(
  of: find.byKey(const Key('goods-picker-paged-list')),
  // Tooltip OverlayPortal text is a logical descendant too. Target the
  // actual cell's direct text, rather than its rich floating disclosure.
  matching: find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == name,
  ),
);
