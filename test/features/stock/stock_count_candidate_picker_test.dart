import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/features/stock/counts/widgets/stock_count_candidate_picker.dart';
import 'package:uten_imp/features/stock/counts/widgets/stock_count_inline_editor.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

const warehouse = StockCountWarehouse(
  id: 'bin',
  name: '注塑内料仓',
  kind: 'WORKSHOP',
  reviewRoute: 'WAREHOUSE',
);

CountStockRow row(String color, {String qty = '0', bool editable = true}) =>
    CountStockRow(
      goodsId: 'pp',
      goodsName: 'PP 颗粒',
      goodsCode: 'G-PP',
      colorId: color,
      colorName: color,
      categoryId: 'raw',
      unitId: 'kg',
      unitName: 'kg',
      qty: qty,
      goodsVersion: 1,
      allowedActions: editable ? ['EDIT'] : [],
    );

class _Repo extends StockCountRequestRepository {
  _Repo() : super(ApiClient(Dio()));
  Completer<PagedResult<CountStockRow>>? delayed;
  final requests = <String>[];

  @override
  Future<List<ProductCategoryNode>> candidateCategories(
    String warehouseId, {
    bool sheet = false,
  }) async => [
    ProductCategoryNode(
      id: 'raw',
      code: '',
      name: '原材料',
      level: 0,
      children: [],
    ),
    ProductCategoryNode(
      id: 'spare',
      code: '',
      name: '辅料',
      level: 0,
      children: [],
    ),
  ];

  @override
  Future<Set<String>> candidateCategoryIds(
    String warehouseId,
    String keyword,
  ) async => {'raw'};

  @override
  Future<PagedResult<CountStockRow>> candidates({
    required String warehouseId,
    String? keyword,
    String? categoryId,
    List<String> goodsIds = const [],
    bool stockedOnly = false,
    bool sheet = false,
    int page = 1,
    int size = 50,
  }) async {
    expectSync(warehouseId, 'bin');
    requests.add('$categoryId|$keyword|$page');
    if (keyword == '慢') return delayed!.future;
    return PagedResult(
      items: [
        row(
          keyword?.isNotEmpty == true
              ? '红'
              : page == 1
              ? '白'
              : '黑',
        ),
      ],
      page: page,
      size: 1,
      total: keyword?.isNotEmpty == true ? 1 : 2,
      totalPages: keyword?.isNotEmpty == true ? 1 : 2,
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repo repo,
  List<List<CountStockRow>> results, {
  Size size = const Size(1600, 1000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [stockCountRequestRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await showStockCountCandidatePicker(
                    context,
                    ref,
                    warehouse: warehouse,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('原材料'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('盘点物料到底滚轮续页，确认保留两页的货品颜色快照', (tester) async {
    final repo = _Repo();
    final results = <List<CountStockRow>>[];
    await _open(tester, repo, results);
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.pump();
    final pickerList = find.byKey(const Key('goods-picker-paged-list'));
    final list = find.descendant(
      of: pickerList,
      matching: find.byType(ListView),
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    final before = repo.requests.length;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pump();
    expect(repo.requests.length, before);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.requests.length, before + 1);
    expect(repo.requests.last, endsWith('|2'));
    expect(find.textContaining('G-PP · 白'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('G-PP · 黑'));
    await tester.tap(find.textContaining('G-PP · 黑'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.map((value) => value.key), ['pp|白', 'pp|黑']);
    expect(results.single.map((value) => value.goodsVersion), [1, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('盘点物料从第二页顶部上滚补第一页，旧页仍可选', (tester) async {
    final repo = _Repo();
    final results = <List<CountStockRow>>[];
    await _open(tester, repo, results);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('G-PP · 黑'));
    await tester.pump();
    final list = find.descendant(
      of: find.byKey(const Key('goods-picker-paged-list')),
      matching: find.byType(ListView),
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    scroll.jumpTo(scroll.minScrollExtent);
    await tester.pump();
    final before = repo.requests.length;
    final previousTop = tester.getTopLeft(find.textContaining('G-PP · 黑')).dy;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.requests.length, before + 1);
    expect(repo.requests.last, endsWith('|1'));
    expect(
      tester.getTopLeft(find.textContaining('G-PP · 黑')).dy,
      closeTo(previousTop, 1),
    );
    scroll.jumpTo(scroll.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.map((value) => value.key), ['pp|黑', 'pp|白']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体多选确认栏不溢出', (tester) async {
    final results = <List<CountStockRow>>[];
    await _open(
      tester,
      _Repo(),
      results,
      size: const Size(375, 750),
      textScale: 1.3,
    );
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.single.colorId, '白');
  });
  testWidgets('销售同款跨页跨搜索多选，保留同料不同颜色', (tester) async {
    final results = <List<CountStockRow>>[];
    await _open(tester, _Repo(), results);
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('G-PP · 黑'));
    await tester.enterText(find.byType(EditableText).first, '红');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.textContaining('G-PP · 红'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('goods-picker-selected-summary')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('goods-picker-selected-remove-pp|黑')),
    );
    await tester.pump();
    expect(find.text('已选货品（2）'), findsOneWidget);
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.map((r) => r.key), ['pp|白', 'pp|红']);
  });

  testWidgets('清空后不能确认，取消不返回候选', (tester) async {
    final results = <List<CountStockRow>>[];
    await _open(tester, _Repo(), results);
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.pump();
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('goods-picker-multi-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results.single, isEmpty);
  });

  testWidgets('旧搜索晚返回不覆盖新结果或已选项', (tester) async {
    final repo = _Repo()..delayed = Completer();
    final results = <List<CountStockRow>>[];
    await _open(tester, repo, results);
    await tester.tap(find.textContaining('G-PP · 白'));
    await tester.enterText(find.byType(EditableText).first, '慢');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.enterText(find.byType(EditableText).first, '红');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    repo.delayed!.complete(
      PagedResult(items: [row('旧')], page: 1, size: 1, total: 1, totalPages: 1),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('G-PP · 旧'), findsNothing);
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.single.key, 'pp|白');
  });

  test('重复批量添加保留原快照与输入，切换盘点会话拒绝旧结果', () {
    final editor = StockCountInlineController(_Repo())..begin(warehouse);
    addTearDown(editor.dispose);
    final session = editor.session;
    editor.addAll([row('白'), row('黑')], expectedSession: session);
    editor.rows['pp|白']!.qty.text = '1000';
    editor.rows['pp|白']!.weight.text = '900';
    editor.reason.text = '上线盘点';
    editor.addAll([
      row('白', qty: '500'),
      row('无权', editable: false),
    ], expectedSession: session);
    expect(editor.rows.length, 2);
    expect(editor.rows['pp|白']!.qty.text, '1000');
    expect(editor.rows['pp|白']!.weight.text, '900');
    expect(editor.addedRows['pp|白']!.qty, '0');
    expect(editor.reason.text, '上线盘点');
    editor.begin(warehouse);
    editor.addAll([row('旧弹窗')], expectedSession: session);
    expect(editor.rows, isEmpty);
  });
}
