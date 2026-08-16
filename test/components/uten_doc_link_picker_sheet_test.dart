// UtenDocLinkPickerSheet（采购/销售/委外共用的「从上游引入」两步面板）
// 结构收敛后的行为回归：
//  - Step1 分页拉单并渲染行；
//  - 双击行（MasterDataTableView 契约：单击选中、双击打开）进 Step2，
//    只显示剩余可引量 > 0 的明细，且"本次数量"预填剩余量；
//  - 全部明细无剩余时给定向空态文案；
//  - 勾选 + 引入返回归一化结果（goodsId/qty/maxQty/upstreamItemId/partyId）；
//  - 数量超剩余时不关闭面板，顶部报错。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Doc {
  const _Doc(this.id, this.billNo, this.partyId);
  final String id;
  final String billNo;
  final String? partyId;
}

class _Item {
  const _Item(this.id, this.goodsId, this.qty, this.remain);
  final String id;
  final String goodsId;
  final double qty;
  final double remain;
}

UtenDocLinkPickerConfig<_Doc, _Item, Null> _config({
  List<_Doc> docs = const [],
  Map<String, List<_Item>> details = const {},
}) {
  return UtenDocLinkPickerConfig<_Doc, _Item, Null>(
    step1Title: '从测试单引入',
    step1EmptyMessage: '暂无已审测试单',
    partyNoun: '供应商',
    allPartiesLabel: '全部供应商',
    docIdOf: (d) => d.id,
    partyIdOf: (d) => d.partyId,
    watchNames: (_) => null,
    partyEntries: (_) => const {'s1': '供应商一'},
    partyName: (_, partyId) => '供应商一',
    initNames: (_) async {},
    loadGoodsNames: (_, _) async {},
    listDocs: (ref, page, keyword, partyId, sort, order) async => PagedResult(
      items: docs,
      page: 1,
      size: docs.length,
      total: docs.length,
      totalPages: 1,
    ),
    loadDetail: (ref, docId) async => UtenDocLinkDetail<_Item>(
      partyId: 's1',
      items: details[docId] ?? const [],
    ),
    itemFields: UtenDocLinkItemFields<_Item>(
      goodsId: (it) => it.goodsId,
      colorId: (_) => null,
      unitId: (_) => null,
      price: (_) => 1.5,
      upstreamItemId: (it) => it.id,
    ),
    docColumns: (_) => [
      MasterColumnDef<_Doc>(
        key: 'billNo',
        label: '单据号',
        width: 140,
        value: (d) => d.billNo,
      ),
    ],
    goodsName: (_, goodsId) => '货品-$goodsId',
    colorName: (_, _) => '—',
    unitName: (_, _) => '—',
    middleItemColumns: (_) => [],
    remainQty: (it) => it.remain,
    createBlankRow: () => UtenDocLinkItemRow<_Item>(const _Item('', '', 0, 0)),
  );
}

/// 打开面板；面板 Future 写入 [resultHolder]['result'] 供断言返回值。
Future<void> _openPanel(
  WidgetTester tester,
  UtenDocLinkPickerConfig<_Doc, _Item, Null> config, {
  Map<String, Object?>? resultHolder,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Stack(
          children: [
            Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    final opened = showUtenDocLinkPickerSheet(
                      tester.element(find.byType(ElevatedButton)),
                      config,
                    );
                    resultHolder?['result'] = opened;
                  },
                  child: const Text('打开面板'),
                ),
              ),
            ),
            const Align(
              alignment: Alignment.topCenter,
              child: AppNotificationHost(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开面板'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 双击表格行（MasterDataTableView 契约：双击才触发 onRowTap）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets('Step1 渲染单据行，双击进入 Step2 并预填剩余量', (tester) async {
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('d1', 'CG-001', 's1')],
        details: {
          'd1': const [
            _Item('i1', 'g1', 10, 4),
            _Item('i2', 'g2', 5, 0), // 已引完，不显示
          ],
        },
      ),
    );

    expect(find.text('从测试单引入'), findsOneWidget);
    expect(find.text('CG-001'), findsOneWidget);

    await _doubleTapRow(tester, find.text('CG-001'));
    await tester.pump();

    // 只显示有剩余的明细；本次数量预填剩余量。
    expect(find.text('货品-g1'), findsOneWidget);
    expect(find.text('货品-g2'), findsNothing);
    final qtyField = tester.widget<TextField>(find.byType(TextField).last);
    expect(qtyField.controller?.text, '4.0');
  });

  testWidgets('全部明细无剩余时显示定向空态', (tester) async {
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('d1', 'CG-001', 's1')],
        details: {
          'd1': const [_Item('i1', 'g1', 10, 0)],
        },
      ),
    );

    await _doubleTapRow(tester, find.text('CG-001'));
    await tester.pump();

    expect(find.text('该单据明细已全部完成，无剩余可引入'), findsOneWidget);
  });

  testWidgets('勾选并引入返回归一化结果', (tester) async {
    final holder = <String, Object?>{};
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('d1', 'CG-001', 's1')],
        details: {
          'd1': const [_Item('i1', 'g1', 10, 4)],
        },
      ),
      resultHolder: holder,
    );

    await _doubleTapRow(tester, find.text('CG-001'));
    await tester.pump();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('已选 1 行'), findsOneWidget);

    await tester.tap(find.text('引入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final result =
        await (holder['result']! as Future<UtenDocLinkPickResult<_Item>?>);
    expect(result, isNotNull);
    expect(result!.items, hasLength(1));
    expect(result.items.single.goodsId, 'g1');
    expect(result.items.single.qty, 4);
    expect(result.items.single.maxQty, 4);
    expect(result.items.single.price, 1.5);
    expect(result.items.single.upstreamItemId, 'i1');
    expect(result.partyId, 's1');
    expect(find.text('从测试单引入'), findsNothing);
  });

  testWidgets('数量超过剩余时不关闭面板并顶部报错', (tester) async {
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('d1', 'CG-001', 's1')],
        details: {
          'd1': const [_Item('i1', 'g1', 10, 4)],
        },
      ),
    );

    await _doubleTapRow(tester, find.text('CG-001'));
    await tester.pump();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    await tester.enterText(find.byType(TextField).last, '9');
    await tester.tap(find.text('引入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('请修正标红的本次数量后再引入'), findsOneWidget);
    expect(find.text('选择明细（供应商一）'), findsOneWidget);
  });
}
