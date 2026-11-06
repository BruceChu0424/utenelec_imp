// 产品配件清单预览(ADR-129)：14 列，「设计使用数量」与只读「真实使用数量」
// 并列；没有真实数据显示「—」，保留当前货品用量格式。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_preview.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_table_output_scope.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/core/network/api_client.dart';
import '../../support/output_selection_wire_api.dart';

class _PreviewRepo extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => switch (goodsId) {
    'goods-a' => const [
      GoodsBomItem(
        id: 'row-1',
        componentGoodsId: 'plastic',
        componentCode: 'P01',
        componentName: '塑料',
        componentMaterial: 'PVC',
        componentStockQty: 12.3456,
        qty: 0.1,
        actual: BomActualUsage(
          qty: 0.105,
          status: BomActualStatus.actual,
          usesActual: true,
        ),
      ),
      GoodsBomItem(
        id: 'row-2',
        componentGoodsId: 'box',
        componentCode: 'B01',
        componentName: '纸箱',
        qty: 1,
        consumptionBasis: BomConsumptionBasis.perPackage,
        basisOutputQty: 50,
        allowPartialPackage: false,
        actual: BomActualUsage(status: BomActualStatus.notLinear),
      ),
    ],
    _ => const [],
  };
}

class _TreeRepo extends Fake implements GoodsBomRepository {
  _TreeRepo(this.tree);
  final Map<String, List<GoodsBomItem>> tree;
  final calls = <String>[];
  @override
  Future<List<GoodsBomItem>> list(String id) async {
    calls.add(id);
    return tree[id] ?? const [];
  }
}

Future<void> _open(
  WidgetTester tester,
  _TreeRepo repository, {
  UtenTableOutputSelection selection = const UtenTableOutputSelection(),
  OutputSelectionWireApi? wireApi,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = TableColumnProjectionController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repository),
        if (wireApi != null) apiClientProvider.overrideWithValue(wireApi),
        currentPermissionsProvider.overrideWithValue({Perm.goodsExport}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: TableColumnProjectionScope(
        controller: controller,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  controller.publish(
                    'bom-test',
                    TableColumnProjection(
                      tableKey:
                          'features.basic_data.widgets.goods_bom_tab.GoodsBomTabState.build.1',
                      columns: const [
                        TableProjectedColumn(
                          key: 'seq',
                          label: '序号',
                          width: 80,
                          type: 'text',
                        ),
                      ],
                      outputSelection: selection,
                    ),
                    contextOwner: ModalRoute.of(context),
                  );
                  showGoodsBomPreview(context: context, goodsId: 'root');
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'selected BOM caller wire keeps both frozen occurrences through version1 gate',
    (tester) async {
      final api = OutputSelectionWireApi();
      final repo = _TreeRepo({
        'root': const [
          GoodsBomItem(
            id: 'a',
            componentGoodsId: 'assembly',
            componentCode: 'A',
            qty: 1,
            hasChildren: true,
          ),
          GoodsBomItem(
            id: 'b',
            componentGoodsId: 'part',
            componentCode: 'P',
            qty: 1,
          ),
          GoodsBomItem(
            id: 'c',
            componentGoodsId: 'assembly',
            componentCode: 'A',
            qty: 1,
            hasChildren: true,
          ),
        ],
        'assembly': const [
          GoodsBomItem(
            id: 'shared',
            componentGoodsId: 'part',
            componentCode: 'P',
            componentName: '选中组件',
            qty: 1,
          ),
        ],
      });
      const selectors = [
        {'seq': '1.1', 'componentGoodsId': 'part'},
        {'seq': '3.1', 'componentGoodsId': 'part'},
      ];
      await _open(
        tester,
        repo,
        wireApi: api,
        selection: const UtenTableOutputSelection(
          ids: {'a/shared', 'c/shared'},
          rows: selectors,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('table-output-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenExportButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('uten-export-filename')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('table-output-selected')),
        findsNothing,
        reason: '预览内Excel沿用冻结范围，不再询问',
      );
      await tester.tap(find.text('直接下载'));
      await tester.pumpAndSettle();
      expect(api.capabilityReads, [OutputSelectionWireApi.capabilitiesPath]);
      expect(api.downloads, hasLength(1));
      expect(api.downloads.single.path, '/master/goods/root/bom/export');
      final projection =
          api.downloads.single.body['columnProjection'] as Map<String, dynamic>;
      expect(projection['rowSelection'], selectors);
      expect(
        (projection['rowSelection'] as List).any(
          (row) => (row as Map)['seq'] == '2',
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('同关系的两条已选出现路径全部保留且同组件其他路径不混入', (tester) async {
    final repo = _TreeRepo({
      'root': const [
        GoodsBomItem(
          id: 'a',
          componentGoodsId: 'assembly-a',
          componentCode: 'A',
          qty: 1,
          hasChildren: true,
        ),
        GoodsBomItem(
          id: 'b',
          componentGoodsId: 'assembly-b',
          componentCode: 'B',
          qty: 1,
          hasChildren: true,
        ),
        GoodsBomItem(
          id: 'c',
          componentGoodsId: 'assembly-a',
          componentCode: 'A',
          qty: 1,
          hasChildren: true,
        ),
      ],
      'assembly-a': const [
        GoodsBomItem(
          id: 'shared',
          componentGoodsId: 'shared-part',
          componentCode: 'PART',
          componentName: '选中的出现位置',
          qty: 1,
        ),
      ],
      'assembly-b': const [
        GoodsBomItem(
          id: 'other',
          componentGoodsId: 'shared-part',
          componentCode: 'PART',
          componentName: '未选中的其他关系',
          qty: 1,
        ),
      ],
    });
    const selectors = [
      {'seq': '1.1', 'componentGoodsId': 'shared-part'},
      {'seq': '3.1', 'componentGoodsId': 'shared-part'},
    ];
    await _open(
      tester,
      repo,
      selection: const UtenTableOutputSelection(
        ids: {'occurrence-a', 'occurrence-c'},
        rows: selectors,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('table-output-selected')));
    await tester.pumpAndSettle();
    expect(find.text('选中的出现位置'), findsNWidgets(2));
    expect(find.text('未选中的其他关系'), findsNothing);
    expect(
      tester
          .widget<UtenExportButton>(find.byType(UtenExportButton))
          .frozenProjection!
          .rowSelection,
      selectors,
    );
    expect(repo.calls.where((id) => id == 'assembly-a'), hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancelled output scope does not read any BOM rows', (
    tester,
  ) async {
    final repo = _TreeRepo({});
    await _open(tester, repo);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    expect(find.byType(UtenExportButton), findsNothing);
  });

  testWidgets(
    'selected preview and nested export retain the same frozen occurrence',
    (tester) async {
      final repo = _TreeRepo({
        'root': const [
          GoodsBomItem(
            id: 'one',
            componentGoodsId: 'a',
            componentCode: 'A',
            componentName: '组件甲',
            qty: 1,
          ),
          GoodsBomItem(
            id: 'two',
            componentGoodsId: 'b',
            componentCode: 'B',
            componentName: '组件乙',
            qty: 1,
            actual: BomActualUsage(
              qty: 0.10500000000000001,
              status: BomActualStatus.actual,
            ),
          ),
        ],
      });
      const selector = {'seq': '2', 'componentGoodsId': 'b'};
      await _open(
        tester,
        repo,
        selection: const UtenTableOutputSelection(
          ids: {'selected-b'},
          rows: [selector],
        ),
      );
      expect(repo.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('table-output-selected')));
      await tester.pumpAndSettle();
      expect(find.text('组件乙'), findsOneWidget);
      expect(find.text('组件甲'), findsNothing);
      // 学习统计沿用已有六位展示口径；冻结原记录不因排版回写或重算。
      expect(find.text('0.105'), findsOneWidget);
      expect(repo.tree['root']![1].actual.qty, 0.10500000000000001);
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.showOutputScope, isFalse);
      expect(export.frozenProjection!.rowSelection, [selector]);
      expect(repo.calls, ['root']);
    },
  );

  for (final kind in ['cycle', 'depth', 'rows']) {
    testWidgets(
      '$kind refuses the whole preview without publishing a partial tree',
      (tester) async {
        final tree = <String, List<GoodsBomItem>>{};
        if (kind == 'cycle') {
          tree['root'] = const [
            GoodsBomItem(
              id: 'cycle',
              componentGoodsId: 'root',
              componentCode: 'ROOT',
              qty: 1,
              hasChildren: true,
            ),
          ];
        } else if (kind == 'depth') {
          for (var i = 0; i < 12; i++) {
            tree[i == 0 ? 'root' : 'node-$i'] = [
              GoodsBomItem(
                id: 'edge-$i',
                componentGoodsId: 'node-${i + 1}',
                componentCode: 'NODE-$i',
                qty: 1,
                hasChildren: true,
              ),
            ];
          }
        } else {
          tree['root'] = [
            for (var i = 0; i < 2001; i++)
              GoodsBomItem(
                id: 'row-$i',
                componentGoodsId: 'goods-$i',
                componentCode: 'G$i',
                componentName: '不得发布的局部结果',
                qty: 1,
              ),
          ];
        }
        await _open(tester, _TreeRepo(tree));
        await tester.tap(find.byKey(const ValueKey('table-output-all')));
        await tester.pumpAndSettle();
        expect(find.text('不得发布的局部结果'), findsNothing);
        final print = tester.widget<UtenButton>(
          find.widgetWithText(UtenButton, '打印'),
        );
        final export = tester.widget<UtenExportButton>(
          find.byType(UtenExportButton),
        );
        expect(print.onPressed, isNull);
        expect(export.enabled, isFalse);
        expect(
          find.textContaining(
            kind == 'cycle'
                ? '循环引用'
                : kind == 'depth'
                ? '层级超过'
                : '2000 行',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final stockAccess in [false, true]) {
    testWidgets(
      'preview lists usage, material and permitted stock (stock=$stockAccess)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              goodsBomRepositoryProvider.overrideWithValue(_PreviewRepo()),
              currentPermissionsProvider.overrideWithValue({
                if (stockAccess) Perm.stockView,
              }),
              isSuperAdminProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showGoodsBomPreview(
                      context: context,
                      goodsId: 'goods-a',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('table-output-all')));
        await tester.pumpAndSettle();

        expect(find.text('设计使用数量'), findsOneWidget);
        expect(find.text('真实使用数量'), findsOneWidget);
        expect(find.text('数量'), findsNothing);
        expect(find.text('材质'), findsOneWidget);
        expect(find.text('PVC'), findsOneWidget);
        expect(find.text('库存数量'), stockAccess ? findsOneWidget : findsNothing);
        expect(
          find.text('12.3456'),
          stockAccess ? findsOneWidget : findsNothing,
        );
        final header = tester.widgetList<Table>(find.byType(Table)).last;
        expect(
          header.children.first.children,
          hasLength(stockAccess ? 16 : 15),
        );
        // 塑料显示实际 0.105；纸箱整包不适用 → 「—」，尾包「整包」。
        expect(find.text('0.105'), findsOneWidget);
        expect(find.text('0.10500000000000001'), findsNothing);
        expect(find.text('整包'), findsOneWidget);
        expect(find.text('50'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
