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
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_master_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/procurement_source_terms.dart';

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
  Map<String, ProcurementSourceTerms> sourceTerms = const {},
  Map<String, String>? gifts,
  Map<String, String?>? exacts,
  Future<UtenDocLinkDetail<_Item>> Function(String)? detailLoader,
  bool allowOverRemaining = false,
  bool allowGiftOverRemaining = false,
  Future<UtenDocLinkParty?> Function()? pickParty,
  Future<void> Function(Set<String>)? loadPartyNames,
  void Function(String?)? onListParty,
  String detailPartyId = 's1',
}) {
  return UtenDocLinkPickerConfig<_Doc, _Item, Null>(
    step1Title: '从测试单引入',
    step1EmptyMessage: '暂无已审测试单',
    partyNoun: '供应商',
    allPartiesLabel: '全部供应商',
    allowOverRemaining: allowOverRemaining,
    allowGiftOverRemaining: allowGiftOverRemaining,
    docIdOf: (d) => d.id,
    partyIdOf: (d) => d.partyId,
    watchNames: (_) => null,
    pickParty: (_, _) =>
        pickParty?.call() ?? Future.value((id: 's1', name: '供应商一')),
    loadPartyNames: (_, ids) async => loadPartyNames?.call(ids),
    partyName: (_, partyId) => '供应商一',
    initNames: (_) async {},
    loadGoodsNames: (_, _) async {},
    listDocs: (ref, page, keyword, partyId, sort, order) async {
      onListParty?.call(partyId);
      return PagedResult(
        items: docs,
        page: 1,
        size: docs.length,
        total: docs.length,
        totalPages: 1,
      );
    },
    loadDetail: (ref, docId) async => detailLoader != null
        ? detailLoader(docId)
        : UtenDocLinkDetail<_Item>(
            partyId: detailPartyId,
            items: details[docId] ?? const [],
            docId: docId,
            sourceTerms: sourceTerms[docId],
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
    middleItemColumns: (_) => [
      if (gifts != null)
        EditableGridColumn<UtenDocLinkItemRow<_Item>>(
          key: 'gift',
          label: '本次赠品',
          width: 100,
          cellBuilder: (_, row) => TextField(
            key: ValueKey('test-link-gift-${row.item.id}'),
            controller: row.giftQty,
          ),
        ),
    ],
    remainQty: (it) => it.remain,
    remainQtyText: gifts == null && exacts == null
        ? null
        : (item) => exacts != null && exacts.containsKey(item.id)
              ? exacts[item.id]
              : item.remain.toString(),
    remainGiftQtyText: gifts == null ? null : (item) => gifts[item.id],
    createBlankRow: () => UtenDocLinkItemRow<_Item>(const _Item('', '', 0, 0)),
  );
}

/// 打开面板；面板 Future 写入 [resultHolder]['result'] 供断言返回值。
Future<void> _openPanel(
  WidgetTester tester,
  UtenDocLinkPickerConfig<_Doc, _Item, Null> config, {
  Map<String, Object?>? resultHolder,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
  testWidgets(
    'party field opens paged picker, refreshes exact UUID and preloads list/detail references',
    (tester) async {
      final selected = <String?>[];
      final proofs = <Set<String>>[];
      await _openPanel(
        tester,
        _config(
          docs: const [_Doc('doc-one', 'SOURCE-001', 'outside-first-page')],
          detailPartyId: 'outside-first-page',
          details: const {
            'doc-one': [_Item('line', 'goods', 2, 2)],
          },
          pickParty: () async => (id: 'outside-first-page', name: '远端供应商'),
          onListParty: selected.add,
          loadPartyNames: (ids) async {
            proofs.add({...ids});
          },
        ),
      );
      expect(selected, [null]);
      expect(proofs, [
        {'outside-first-page'},
      ]);
      await tester.tap(find.byType(UtenMasterPickerField<UtenDocLinkParty>));
      await tester.pumpAndSettle();
      expect(selected, [null, 'outside-first-page']);
      expect(proofs, [
        {'outside-first-page'},
        {'outside-first-page'},
      ]);
      await _doubleTapRow(tester, find.text('SOURCE-001'));
      await tester.pumpAndSettle();
      expect(proofs.last, {'outside-first-page'});
      expect(find.text('货品-goods'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown source quantities do not hide known selectable lines or become completed',
    (tester) async {
      final holder = <String, Object?>{};
      await _openPanel(
        tester,
        _config(
          docs: const [_Doc('mixed', 'MIXED-001', 's1')],
          details: const {
            'mixed': [
              _Item('unknown', 'unknown-goods', 10, 10),
              _Item('known', 'known-goods', 10, 2),
            ],
          },
          exacts: const {'unknown': null, 'known': '2'},
        ),
        resultHolder: holder,
      );
      await _doubleTapRow(tester, find.text('MIXED-001'));
      await tester.pump();
      expect(find.text('货品-unknown-goods'), findsNothing);
      expect(find.text('货品-known-goods'), findsOneWidget);
      expect(find.textContaining('来源数量不完整'), findsOneWidget);
      expect(find.text('该单据明细已全部完成，无剩余可引入'), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      final result =
          await (holder['result']! as Future<UtenDocLinkPickResult<_Item>?>);
      expect(result!.items.single.upstreamItemId, 'known');
    },
  );
  for (final locale in const [Locale('zh'), Locale('en'), Locale('ko')]) {
    testWidgets(
      'detail read failure is visible and recoverable in ${locale.languageCode}',
      (tester) async {
        var calls = 0;
        await _openPanel(
          tester,
          _config(
            docs: const [_Doc('retry', 'RETRY-001', 's1')],
            detailLoader: (id) async {
              if (calls++ == 0) {
                throw StateError('private implementation failure');
              }
              return const UtenDocLinkDetail(
                partyId: 's1',
                items: [_Item('good', 'g1', 10, 3)],
              );
            },
          ),
          locale: locale,
        );
        await _doubleTapRow(tester, find.text('RETRY-001'));
        await tester.pump();
        expect(
          find.text(lookupAppLocalizations(locale).docLinkDetailLoadFailed),
          findsOneWidget,
        );
        expect(find.textContaining('private implementation'), findsNothing);
        final table = tester.widget<MasterDataTableView<_Doc>>(
          find.byType(MasterDataTableView<_Doc>),
        );
        table.onRetry!();
        await tester.pumpAndSettle();
        await _doubleTapRow(tester, find.text('RETRY-001'));
        await tester.pump();
        expect(find.text('货品-g1'), findsOneWidget);
        expect(calls, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('specific source denial remains visible', (tester) async {
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('denied', 'DENIED-001', 's1')],
        detailLoader: (id) async =>
            throw ApiException('FORBIDDEN', '该来源单据权限已收回'),
      ),
    );
    await _doubleTapRow(tester, find.text('DENIED-001'));
    await tester.pump();
    expect(find.text('该来源单据权限已收回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'exact positive remainder remains visible when binary subtraction reached zero',
    (tester) async {
      final holder = <String, Object?>{};
      await _openPanel(
        tester,
        _config(
          docs: const [_Doc('exact-doc', 'EXACT-001', 's1')],
          details: const {
            'exact-doc': [_Item('exact-source', 'goods', 10, 0)],
          },
          exacts: const {'exact-source': '0.0001'},
          gifts: const {'exact-source': '0'},
        ),
        resultHolder: holder,
      );
      await _doubleTapRow(tester, find.text('EXACT-001'));
      await tester.pump();
      expect(find.text('货品-goods'), findsOneWidget);
      expect(find.text('0.0001 —'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      final result =
          await (holder['result']! as Future<UtenDocLinkPickResult<_Item>?>);
      expect(result!.items.single.qtyText, '0.0001');
      expect(result.items.single.upstreamItemId, 'exact-source');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'new-order source can replace one charged item by an extra gift despite declared gift zero',
    (tester) async {
      final holder = <String, Object?>{};
      await _openPanel(
        tester,
        _config(
          docs: const [_Doc('request-doc', 'REQUEST-001', 's1')],
          details: const {
            'request-doc': [_Item('request-source', 'goods', 10, 10)],
          },
          gifts: const {'request-source': '0'},
          exacts: const {'request-source': '10'},
          allowOverRemaining: true,
          allowGiftOverRemaining: true,
        ),
        resultHolder: holder,
      );
      await _doubleTapRow(tester, find.text('REQUEST-001'));
      await tester.pump();
      final grid = tester.widget<UtenEditableGrid<UtenDocLinkItemRow<_Item>>>(
        find.byType(UtenEditableGrid<UtenDocLinkItemRow<_Item>>),
      );
      final row = grid.controller.rows.single;
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.qty),
        ),
        '9',
      );
      await tester.enterText(
        find.byKey(const ValueKey('test-link-gift-request-source')),
        '1',
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      expect(
        find.byType(UtenEditableGrid<UtenDocLinkItemRow<_Item>>),
        findsNothing,
        reason:
            'The real user click should complete this valid order-source selection',
      );
      final result =
          await (holder['result']! as Future<UtenDocLinkPickResult<_Item>?>);
      expect(result!.items.single.qtyText, '9');
      expect(result.items.single.giftQtyText, '1');
      expect(tester.takeException(), isNull);
    },
  );
  for (final giftQuota in ['1', null]) {
    testWidgets(
      'default approved-source gift limit stays strict quota=$giftQuota',
      (tester) async {
        await _openPanel(
          tester,
          _config(
            docs: const [_Doc('strict-doc', 'STRICT-001', 's1')],
            details: const {
              'strict-doc': [_Item('strict-source', 'goods', 10, 10)],
            },
            gifts: giftQuota == null ? const {} : {'strict-source': giftQuota},
            allowOverRemaining: true,
          ),
        );
        await _doubleTapRow(tester, find.text('STRICT-001'));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('test-link-gift-strict-source')),
          '2',
        );
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        await tester.tap(find.text('引入'));
        await tester.pumpAndSettle();
        expect(
          find.byType(UtenEditableGrid<UtenDocLinkItemRow<_Item>>),
          findsOneWidget,
        );
        expect(find.textContaining('请修正标红'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final terms in [
    const ProcurementSourceTerms(
      currencyId: 'usd',
      exchangeRate: '7.123456',
      taxRate: '13.120001',
      settlementMethodId: 'monthly',
    ),
    const ProcurementSourceTerms(currencyId: 'usd'),
  ]) {
    testWidgets(
      'gift-only source remains selectable after charged capacity reaches zero',
      (tester) async {
        final holder = <String, Object?>{};
        await _openPanel(
          tester,
          _config(
            docs: const [_Doc('gift-doc', 'GIFT-001', 's1')],
            details: {
              'gift-doc': const [_Item('gift-source', 'same-goods', 0, 0)],
            },
            gifts: const {'gift-source': '1.0001'},
          ),
          resultHolder: holder,
        );
        await _doubleTapRow(tester, find.text('GIFT-001'));
        await tester.pump();
        expect(find.text('货品-same-goods'), findsOneWidget);
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        await tester.tap(find.text('引入'));
        await tester.pumpAndSettle();
        final result =
            await (holder['result']! as Future<UtenDocLinkPickResult<_Item>?>);
        expect(result!.items.single.qtyText, '0.0');
        expect(result.items.single.giftQtyText, '1.0001');
        expect(result.items.single.maxGiftQtyText, '1.0001');
        expect(result.items.single.upstreamItemId, 'gift-source');
      },
    );

    testWidgets(
      'selected document carries its exact or masked source terms ${terms.exchangeRate}',
      (tester) async {
        final holder = <String, Object?>{};
        await _openPanel(
          tester,
          _config(
            docs: const [_Doc('source-1', 'CG-FX-001', 's1')],
            details: const {
              'source-1': [_Item('line-1', 'goods-1', 4, 2)],
            },
            sourceTerms: {'source-1': terms},
          ),
          resultHolder: holder,
        );
        await _doubleTapRow(tester, find.text('CG-FX-001'));
        await tester.pump();
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        await tester.tap(find.text('引入'));
        await tester.pumpAndSettle();

        final result =
            await (holder['result'] as Future<UtenDocLinkPickResult<_Item>?>);
        expect(result?.sourceDocId, 'source-1');
        expect(result?.items.single.upstreamItemId, 'line-1');
        expect(result?.items.single.qty, 2);
        expect(result?.sourceTerms?.toJson(), terms.toJson());
      },
    );
  }

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

  // 2026-09-11 表头快速筛选补齐：Step2 明细表的「货品/颜色/单位」接表头下拉，
  // 同名货品合并成一个桶（视图级过滤，不动勾选与已填本次数量）。
  testWidgets('Step2 货品表头筛选收敛明细行', (tester) async {
    await _openPanel(
      tester,
      _config(
        docs: const [_Doc('d1', 'CG-001', 's1')],
        details: {
          'd1': const [
            _Item('i1', 'g1', 10, 4),
            _Item('i2', 'g2', 5, 2),
            _Item('i3', 'g1', 8, 3),
          ],
        },
      ),
    );

    await _doubleTapRow(tester, find.text('CG-001'));
    await tester.pump();
    expect(find.text('货品-g1'), findsNWidgets(2));

    final header = find.widgetWithText(GridHeaderFilterCell, '货品名称');
    expect(header, findsOneWidget);
    await tester.tap(header);
    await tester.pump();
    expect(find.text('货品-g1（2）'), findsOneWidget);
    expect(find.text('货品-g2（1）'), findsOneWidget);

    await tester.tap(find.text('货品-g1（2）'));
    await tester.pump();
    expect(find.text('货品-g2'), findsNothing);
    // 两行数据 + 表头显示的当前筛选值。
    expect(find.text('货品-g1'), findsNWidgets(3));
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
    expect(find.text('选择明细(供应商一)'), findsOneWidget);
  });
}
