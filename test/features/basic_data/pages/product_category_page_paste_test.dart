import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_batch_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_component_picker.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_location_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _livePermissions = StateProvider<Set<String>?>((ref) => null);
final _liveIdentity = StateProvider<String>((ref) => 'operator-a');

const _source = GoodsDetail(
  id: 'source-goods',
  code: 'SRC001',
  name: '测试插座',
  nameEn: 'SOURCE SOCKET',
  categoryId: 'source-category',
  status: '使用',
  spec: '三极',
  model: 'P10',
  unitId: 'unit-piece',
  colorId: 'color-white',
  owningWarehouseId: 'warehouse-1',
  price: 20,
  discount: 0.9,
  subcontractAllowedLossPct: 7.25,
  version: 8,
);

const _component = GoodsBomItem(
  id: 'source-bom',
  componentGoodsId: 'component-1',
  qty: 2,
  summary: '原组件说明',
  colorId: 'component-color',
  defaultSupplierId: 'supplier-1',
);

Future<void> _rightClickAt(WidgetTester tester, Offset position) async {
  final gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder get _table => find.byType(MasterDataTableView<GoodsListItem>);

Future<void> _rightClickBlank(WidgetTester tester) async {
  final rect = tester.getRect(_table);
  // Hit the full empty viewport, away from the centered empty-state message.
  await _rightClickAt(tester, rect.bottomLeft + const Offset(45, -60));
}

Future<void> _pumpPage(
  WidgetTester tester,
  _GoodsRepository goods,
  _BomRepository bom, {
  bool canCreate = true,
  bool withClipboard = false,
  Set<String> bomPermissions = const {},
  GoodsBomBatchRepository? maintenance,
  Size surfaceSize = const Size(1600, 900),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        currentPermissionsProvider.overrideWith(
          (ref) =>
              ref.watch(_livePermissions) ??
              {
                Perm.goodsView,
                Perm.materialCategoryView,
                if (canCreate) Perm.goodsCreate,
                ...bomPermissions,
              },
        ),
        authenticatedScopeProvider.overrideWith(
          (ref) => AuthenticatedScope(userId: ref.watch(_liveIdentity)),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        productCategoryRepositoryProvider.overrideWithValue(_Categories()),
        goodsRepositoryProvider.overrideWithValue(goods),
        goodsLocationRepositoryProvider.overrideWithValue(
          _LocationRepository(goods),
        ),
        goodsBomRepositoryProvider.overrideWithValue(bom),
        if (maintenance != null)
          goodsBomBatchRepositoryProvider.overrideWithValue(maintenance),
        bomComponentPickerProvider.overrideWithValue(
          (context, ref) async => const [
            GoodsListItem(
              id: 'component-1',
              code: 'C01',
              name: '目标组件',
              unitName: '个',
            ),
          ],
        ),
        bomComponentRemovalPickerProvider.overrideWithValue(
          (context, ref) async => const [
            GoodsListItem(
              id: 'component-1',
              code: 'C01',
              name: '停用旧组件',
              status: '禁用',
            ),
          ],
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductCategoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (withClipboard) {
    ProviderScope.containerOf(tester.element(find.byType(ProductCategoryPage)))
        .read(goodsClipboardProvider.notifier)
        .copyGoods(
          const GoodsCopyClip(detail: _source, bomItems: [_component]),
        );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final permission in [Perm.goodsBomCreate, Perm.goodsBomDelete]) {
    testWidgets('组件$permission授权不能绕过编辑权限显示批量维护入口', (tester) async {
      await _pumpPage(
        tester,
        _GoodsRepository(),
        _BomRepository(),
        bomPermissions: {permission},
      );
      await tester.tap(find.text('原分类'));
      await tester.pumpAndSettle();
      await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
      expect(find.text('批量添加组件'), findsNothing);
      expect(find.text('批量移除指定组件'), findsNothing);
      expect(find.text('清空顶层组装清单'), findsNothing);
    });
  }

  testWidgets('货品列表多选右键仅提供获权ADD/REMOVE并用预览确认维护所选两品', (tester) async {
    final maintenance = _MaintenanceRepository();
    final bom = _BomRepository();
    await _pumpPage(
      tester,
      _GoodsRepository(targetCount: 2),
      bom,
      maintenance: maintenance,
      bomPermissions: {
        Perm.goodsBomEdit,
        Perm.goodsBomCreate,
        Perm.goodsBomDelete,
      },
    );
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    tester
        .widget<MasterDataTableView<GoodsListItem>>(_table)
        .onSelectedIdsChanged!({'existing-1', 'existing-2'});
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    expect(find.text('批量添加组件'), findsOneWidget);
    expect(find.text('批量移除指定组件'), findsOneWidget);
    expect(find.text('覆盖整份组装清单(使用已复制组件)'), findsNothing);
    expect(find.textContaining('批量粘贴组件'), findsNothing);
    await tester.tap(find.text('批量添加组件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-bom-batch-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
    await tester.pumpAndSettle();
    expect(maintenance.targets, ['existing-1', 'existing-2']);
    expect(maintenance.commits, 0);
    await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
    await tester.pumpAndSettle();
    expect(maintenance.commits, 1);
    expect(bom.pasted, isEmpty);
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).selectedIds,
      isEmpty,
    );
  });

  testWidgets('已有单品整份覆盖使用新预览且明确顶层清单语义', (tester) async {
    final maintenance = _MaintenanceRepository();
    final bom = _BomRepository();
    await _pumpPage(
      tester,
      _GoodsRepository(),
      bom,
      maintenance: maintenance,
      bomPermissions: {
        Perm.goodsBomEdit,
        Perm.goodsBomCreate,
        Perm.goodsBomDelete,
      },
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductCategoryPage)),
    );
    container.read(goodsClipboardProvider.notifier).copyBom(const [
      _component,
    ], '来源清单');
    await tester.tap(find.text('原分类'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
    await tester.scrollUntilVisible(
      find.text('覆盖整份组装清单(使用已复制组件)'),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('覆盖整份组装清单(使用已复制组件)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('嵌套共享子件自身的组装清单保持不变'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
    await tester.pumpAndSettle();
    expect(maintenance.action, BomBatchAction.overwrite);
    expect(maintenance.targets, [_source.id]);
    expect(maintenance.items.single['qty'], _component.qty);
    expect(maintenance.items.single['copiedFromBomItemId'], _component.id);
    expect(bom.pasted, isEmpty);
  });

  testWidgets('单品清空只预选现有顶层组件进入REMOVE预览而不再直接删除', (tester) async {
    final maintenance = _MaintenanceRepository();
    final bom = _BomRepository();
    await _pumpPage(
      tester,
      _GoodsRepository(),
      bom,
      maintenance: maintenance,
      bomPermissions: {Perm.goodsBomEdit, Perm.goodsBomDelete},
    );
    await tester.tap(find.text('原分类'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
    expect(find.text('批量添加组件'), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, -350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空顶层组装清单'));
    await tester.pumpAndSettle();
    expect(bom.listCalls, [_source.id]);
    await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
    await tester.pumpAndSettle();
    expect(maintenance.action, BomBatchAction.remove);
    expect(maintenance.components, [_component.componentGoodsId]);
    expect(maintenance.commits, 0);
  });

  for (final change in ['permission', 'account']) {
    testWidgets('复制组件回执迟到遇到$change变化不能写回新剪贴板', (tester) async {
      final bom = _BomRepository()
        ..pendingCopy = Completer<List<GoodsBomItem>>();
      await _pumpPage(tester, _GoodsRepository(), bom);
      await tester.tap(find.text('原分类'));
      await tester.pumpAndSettle();
      await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
      await tester.ensureVisible(find.text('复制组件信息'));
      await tester.tap(find.text('复制组件信息'));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCategoryPage)),
      );
      if (change == 'account') {
        container.read(_liveIdentity.notifier).state = 'operator-b';
      } else {
        container.read(_livePermissions.notifier).state = {Perm.goodsView};
      }
      await tester.pump();
      bom.pendingCopy!.complete(const [_component]);
      await tester.pumpAndSettle();
      expect(container.read(goodsClipboardProvider).bomItems, isNull);
      expect(bom.listCalls, [_source.id]);
    });
  }

  testWidgets('复制源分类货品后在空目标分类空白处粘贴，副本与组件写入目标且立即显示', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom);
    await tester.tap(find.text('原分类'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
    await tester.tap(find.text('复制货品'));
    await tester.pumpAndSettle();
    expect(goods.detailCalls, [_source.id]);
    expect(bom.listCalls, [_source.id]);

    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).items,
      isEmpty,
    );
    await _rightClickBlank(tester);
    expect(find.text('粘贴货品'), findsOneWidget);
    expect(find.text('复制货品'), findsNothing);
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();

    final body = goods.created.single;
    expect(body['categoryId'], 'target-category');
    expect(body['name'], '测试插座(1)');
    expect(body['spec'], _source.spec);
    expect(body['model'], _source.model);
    expect(body['unitId'], _source.unitId);
    expect(body['colorId'], _source.colorId);
    expect(body['owningWarehouseId'], _source.owningWarehouseId);
    for (final key in [
      'id',
      'code',
      'version',
      'nameEn',
      'price',
      'discount',
    ]) {
      expect(body, isNot(contains(key)), reason: 'Copies must not reuse $key');
    }
    final pasted = bom.pasted.single;
    expect(pasted.mode, BomPasteMode.append);
    expect(pasted.targets.single.goodsId, 'copy-1');
    expect(
      pasted.items.single['componentGoodsId'],
      _component.componentGoodsId,
    );
    expect(pasted.items.single['qty'], 2);
    expect(pasted.items.single['summary'], _component.summary);
    expect(pasted.items.single['colorId'], _component.colorId);
    expect(
      pasted.items.single['defaultSupplierId'],
      _component.defaultSupplierId,
    );
    expect(pasted.items.single, isNot(contains('id')));
    expect(find.text('测试插座(1)'), findsOneWidget);
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).items.single.id,
      'copy-1',
    );
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).selectedIds,
      {'copy-1'},
    );
    expect(tester.takeException(), isNull);
  });

  for (final canViewCost in [false, true]) {
    testWidgets('复制货品${canViewCost ? '有' : '无'}成本查看权限时'
        '${canViewCost ? '保留' : '省略'}来源委外损耗比例', (tester) async {
      final goods = _GoodsRepository();
      await _pumpPage(
        tester,
        goods,
        _BomRepository(),
        bomPermissions: {if (canViewCost) Perm.goodsCostView},
      );
      await tester.tap(find.text('原分类'));
      await tester.pumpAndSettle();
      await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
      await tester.tap(find.text('复制货品'));
      await tester.pumpAndSettle();
      final clipboard = ProviderScope.containerOf(
        tester.element(find.byType(ProductCategoryPage)),
      ).read(goodsClipboardProvider);
      // A source snapshot is not authorization to write the new record's cost.
      // Enforce permission even when a detail response contains a non-null value.
      expect(clipboard.goodsList.single.detail.subcontractAllowedLossPct, 7.25);
      await tester.tap(find.text('新分类'));
      await tester.pumpAndSettle();
      await _rightClickBlank(tester);
      await tester.tap(find.text('粘贴货品'));
      await tester.pumpAndSettle();
      final body = goods.created.single;
      expect(body['categoryId'], 'target-category');
      if (canViewCost) {
        expect(body['subcontractAllowedLossPct'], 7.25);
      } else {
        expect(body, isNot(contains('subcontractAllowedLossPct')));
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final canCreate in [false, true]) {
    testWidgets(canCreate ? '空分类剪贴板为空时粘贴禁用' : '空分类没有新增权限时粘贴禁用', (tester) async {
      final goods = _GoodsRepository();
      final bom = _BomRepository();
      await _pumpPage(
        tester,
        goods,
        bom,
        canCreate: canCreate,
        withClipboard: !canCreate,
      );
      await tester.tap(find.text('新分类'));
      await tester.pumpAndSettle();
      await _rightClickBlank(tester);
      for (final label in ['粘贴货品', '批量粘贴…']) {
        final item = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(tester.widget<InkWell>(item).onTap, isNull);
      }
      expect(goods.created, isEmpty);
      expect(bom.pasted, isEmpty);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空分类直接输入复制份数后所有副本进入当前分类并显示', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    await _rightClickBlank(tester);
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('goods-batch-paste-copies')),
      '2',
    );
    await tester.pump();
    expect(find.text('预计新增 2 个货品'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goods-batch-paste-confirm')));
    await tester.pumpAndSettle();
    expect(goods.created, hasLength(2));
    expect(
      goods.created.map((body) => body['categoryId']),
      everyElement('target-category'),
    );
    expect(bom.pasted, hasLength(2));
    expect(bom.pasted.map((call) => call.targets.single.goodsId), [
      'copy-1',
      'copy-2',
    ]);
    expect(find.text('测试插座(1)'), findsOneWidget);
    expect(find.text('测试插座(2)'), findsOneWidget);
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).selectedIds,
      {'copy-1', 'copy-2'},
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量粘贴非法份数不创建货品或组件且取消丢弃输入', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    await _rightClickBlank(tester);
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();

    final copies = find.byKey(const Key('goods-batch-paste-copies'));
    final confirm = find.byKey(const Key('goods-batch-paste-confirm'));
    for (final value in ['', '0', '51']) {
      await tester.enterText(copies, value);
      await tester.pump();
      expect(tester.widget<UtenButton>(confirm).onPressed, isNull);
      await tester.tap(confirm);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('批量粘贴货品'), findsOneWidget);
      expect(goods.created, isEmpty);
      expect(bom.pasted, isEmpty);
    }

    await tester.enterText(copies, '4');
    await tester.pump();
    expect(find.text('预计新增 4 个货品'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('批量粘贴货品'), findsNothing);
    expect(goods.created, isEmpty);
    expect(bom.pasted, isEmpty);
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).selectedIds,
      isEmpty,
    );

    await _rightClickBlank(tester);
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(copies).controller!.text, '1');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(goods.created, isEmpty);
    expect(bom.pasted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('157条分类中粘贴按实际编号位置定位，不假定副本在末页', (tester) async {
    final goods = _GoodsRepository(targetCount: 157, copyPrefix: 'AAA');
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    final beforePasteRequests = goods.mainPageRequests.length;
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(table.currentPage, 1);
    expect(table.totalPages, 8);
    // A neighbour may finish during the reload, but the settled page and its
    // rendered continuous window must both retain the located copy first.
    expect(table.rowsController, isNotNull);
    expect(table.rowsController!.items.first.id, 'copy-1');
    expect(table.items.first.id, 'copy-1');
    expect(
      goods.mainPageRequests.skip(beforePasteRequests),
      contains((
        categoryId: 'target-category',
        page: 1,
        sort: 'code',
        order: 'asc',
      )),
    );
    expect(table.selectedIds, {'copy-1'});
    expect(find.text('测试插座(1)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('粘贴跨过分页边界后自动进入新末页并显示副本', (tester) async {
    final goods = _GoodsRepository(targetCount: 20);
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    final beforePasteRequests = goods.mainPageRequests.length;
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).currentPage,
      1,
    );
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(table.currentPage, 2);
    expect(table.totalPages, 2);
    expect(table.items.single.id, 'copy-1');
    // The row menu completion must not clear the new selection after paste.
    expect(table.selectedIds, {'copy-1'});
    expect(
      goods.mainPageRequests.skip(beforePasteRequests),
      contains((
        categoryId: 'target-category',
        page: 2,
        sort: 'code',
        order: 'asc',
      )),
      reason: '定位副本读取目标页，允许随后准备相邻页',
    );
    expect(find.text('测试插座(1)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量粘贴后进入末页并自动滚动到超出视口的最后副本', (tester) async {
    final goods = _GoodsRepository(targetCount: 35);
    final bom = _BomRepository();
    await _pumpPage(
      tester,
      goods,
      bom,
      withClipboard: true,
      surfaceSize: const Size(1600, 600),
    );
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    final beforePasteRequests = goods.mainPageRequests.length;
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('goods-batch-paste-increase')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('goods-batch-paste-confirm')));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(goods.created, hasLength(5));
    expect(table.currentPage, 2);
    expect(table.items, hasLength(20));
    expect(table.items.last.id, 'copy-5');
    expect(table.selectedIds, {
      'copy-1',
      'copy-2',
      'copy-3',
      'copy-4',
      'copy-5',
    });
    expect(
      goods.mainPageRequests.skip(beforePasteRequests),
      contains((
        categoryId: 'target-category',
        page: 2,
        sort: 'code',
        order: 'asc',
      )),
      reason: '定位副本读取目标页，允许随后准备相邻页',
    );
    // No tester drag/ensureVisible: the product must scroll its own viewport.
    expect(find.text('测试插座(5)').hitTestable(), findsOneWidget);
    expect(find.text('已有货品 21').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨页批量粘贴默认选中所有成功副本且不包含原右键行', (tester) async {
    final goods = _GoodsRepository(targetCount: 39);
    await _pumpPage(tester, goods, _BomRepository(), withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('goods-batch-paste-increase')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('goods-batch-paste-confirm')));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(table.currentPage, 3);
    expect(table.items.map((item) => item.id), ['copy-2', 'copy-3']);
    expect(table.selectedIds, {'copy-1', 'copy-2', 'copy-3'});
    expect(find.text('测试插座(3)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量粘贴中途创建失败时只选中成功副本并保留逐条失败提示', (tester) async {
    final goods = _GoodsRepository(failCreateAttempt: 2);
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    await _rightClickBlank(tester);
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('goods-batch-paste-increase')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('goods-batch-paste-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('测试插座(2)'), findsOneWidget);
    expect(find.text('测试中第二份创建失败'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(goods.created, hasLength(2));
    expect(table.items.map((item) => item.id), ['copy-1', 'copy-3']);
    expect(table.selectedIds, {'copy-1', 'copy-3'});
    expect(bom.pasted.map((call) => call.targets.single.goodsId), [
      'copy-1',
      'copy-3',
    ]);
    expect(find.text('测试插座(2)'), findsNothing);
    expect(find.text('测试插座(3)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组件粘贴被服务端拒绝时结果弹窗逐行列出哪一行什么问题', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository()
      ..pasteFailure = ApiException(
        'CONFLICT',
        '粘贴没有生效：有 2 处问题，现有组件没有任何改动',
        fieldErrors: const [
          ApiFieldError(
            field: '第 1 行 UT3018 包装袋（优腾通用）',
            message: '目标「测试插座(1)」已有这个组件',
          ),
          ApiFieldError(
            field: '第 7 行 UT3118 6M圆标贴（响臻白）',
            message: '组件货品已删除或仅为迁移占位',
          ),
        ],
        httpStatus: 409,
      );
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    await _rightClickBlank(tester);
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();
    // 货品本体建成一条成功；组件失败行带概括句与逐行明细，不再只报「有 2 处问题」。
    expect(find.text('已粘贴 1 个，1 个没有处理'), findsOneWidget);
    expect(find.text('「测试插座(1)」的组件'), findsOneWidget);
    expect(find.textContaining('粘贴没有生效：有 2 处问题'), findsOneWidget);
    expect(
      find.textContaining('第 1 行 UT3018 包装袋（优腾通用）：目标「测试插座(1)」已有这个组件'),
      findsOneWidget,
    );
    expect(
      find.textContaining('第 7 行 UT3118 6M圆标贴（响臻白）：组件货品已删除或仅为迁移占位'),
      findsOneWidget,
    );
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(goods.created, hasLength(1));
    expect(bom.pasted, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

class _MaintenanceRepository implements GoodsBomBatchRepository {
  BomBatchAction? action;
  List<String> targets = [];
  List<String> components = [];
  List<Map<String, dynamic>> items = [];
  int commits = 0;
  @override
  Future<BomBatchPreview> preview({
    required BomBatchAction action,
    required List<String> targetGoodsIds,
    List<Map<String, dynamic>> items = const [],
    List<String> componentGoodsIds = const [],
  }) async {
    this.action = action;
    targets = List.of(targetGoodsIds);
    components = List.of(componentGoodsIds);
    this.items = [for (final item in items) Map.of(item)];
    return BomBatchPreview(
      previewToken: 'list-preview',
      action: action,
      selectedTargetCount: targets.length,
      changedTargetCount: targets.length,
      added: action == BomBatchAction.add ? targets.length : 0,
      updated: 0,
      removed: action == BomBatchAction.remove ? targets.length : 0,
      skipped: 0,
      targets: [
        for (final id in targets)
          BomBatchTarget(goodsId: id, goodsCode: id, goodsName: id),
      ],
      affectedProducts: const [],
      otherUsageCount: 0,
      hiddenUsageCount: 0,
    );
  }

  @override
  Future<BomBatchResult> commit(
    String previewToken, {
    required bool confirmSharedChanges,
  }) async {
    expect(previewToken, 'list-preview');
    expect(confirmSharedChanges, isTrue);
    commits++;
    return BomBatchResult(
      selectedTargetCount: targets.length,
      changedTargetCount: targets.length,
      added: 1,
      updated: 0,
      removed: 0,
      skipped: 0,
      targets: const [],
    );
  }
}

class _Categories implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    for (final source in [true, false])
      ProductCategoryNode(
        id: source ? 'source-category' : 'target-category',
        code: source ? 'SRC' : 'DST',
        name: source ? '原分类' : '新分类',
        level: 0,
        codePrefix: source ? 'SRC' : 'DST',
        children: const [],
      ),
  ];

  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      ProductCategoryDetail(
        id: id,
        code: id == 'source-category' ? 'SRC' : 'DST',
        name: id == 'source-category' ? '原分类' : '新分类',
        level: 0,
        path: id == 'source-category' ? '原分类' : '新分类',
        childCount: 0,
        codePrefix: id == 'source-category' ? 'SRC' : 'DST',
        effectivePrefix: id == 'source-category' ? 'SRC' : 'DST',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GoodsRepository implements GoodsRepository {
  _GoodsRepository({
    this.targetCount = 0,
    this.failCreateAttempt,
    this.copyPrefix = 'DST',
  });

  final int targetCount;
  final String copyPrefix;
  final int? failCreateAttempt;
  var _createAttempts = 0;
  final _createdNumbers = <int>[];
  final detailCalls = <String>[];
  final created = <Map<String, dynamic>>[];
  final mainPageRequests =
      <({String? categoryId, int page, String? sort, String? order})>[];

  String _copyCode(int number) =>
      '$copyPrefix${(targetCount + number).toString().padLeft(4, '0')}';

  @override
  Future<GoodsDetail> detail(String id) async {
    detailCalls.add(id);
    return _source;
  }

  @override
  Future<GoodsDetail> create(Map<String, dynamic> body) async {
    _createAttempts++;
    if (_createAttempts == failCreateAttempt) {
      throw ApiException('CONFLICT', '测试中第二份创建失败', httpStatus: 409);
    }
    created.add(Map<String, dynamic>.from(body));
    _createdNumbers.add(_createAttempts);
    return GoodsDetail.fromJson({
      ...body,
      'id': 'copy-$_createAttempts',
      'code': _copyCode(_createAttempts),
    });
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
    if (!disabledOnly && !stubOnly) {
      mainPageRequests.add((
        categoryId: categoryId,
        page: page,
        sort: sort,
        order: order,
      ));
    }
    final items = disabledOnly || stubOnly
        ? <GoodsListItem>[]
        : [
            if (categoryId == _source.categoryId)
              GoodsListItem(
                id: _source.id,
                name: _source.name,
                code: _source.code,
                categoryId: _source.categoryId,
                status: _source.status,
              ),
            if (categoryId == 'target-category')
              for (var i = 0; i < targetCount; i++)
                GoodsListItem(
                  id: 'existing-${i + 1}',
                  name: '已有货品 ${i + 1}',
                  code: 'DST${(i + 1).toString().padLeft(4, '0')}',
                  categoryId: categoryId,
                  status: '使用',
                ),
            for (var i = 0; i < created.length; i++)
              if (created[i]['categoryId'] == categoryId)
                GoodsListItem.fromJson({
                  ...created[i],
                  'id': 'copy-${_createdNumbers[i]}',
                  'code': _copyCode(_createdNumbers[i]),
                }),
          ];
    items.sort(
      (a, b) =>
          (order == 'desc' ? -1 : 1) * (a.code ?? '').compareTo(b.code ?? ''),
    );
    return PagedResult(
      items: items.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: items.length,
      totalPages: (items.length / size).ceil(),
    );
  }

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocationRepository extends GoodsLocationRepository {
  _LocationRepository(this.goods) : super(ApiClient(Dio()));
  final _GoodsRepository goods;
  @override
  Future<int?> locate({
    required String id,
    String? categoryId,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    int size = 20,
    bool excludeDisabled = false,
    bool includeRelated = false,
  }) async {
    final all = await goods.list(
      categoryId,
      size: 10000,
      sort: sort,
      order: order,
    );
    final index = all.items.indexWhere((item) => item.id == id);
    return index < 0 ? null : index ~/ size + 1;
  }
}

class _BomRepository implements GoodsBomRepository {
  Completer<List<GoodsBomItem>>? pendingCopy;
  ApiException? pasteFailure;
  final listCalls = <String>[];
  final pasted =
      <
        ({
          BomPasteMode mode,
          List<BomPasteTarget> targets,
          List<Map<String, dynamic>> items,
        })
      >[];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    if (pendingCopy != null) return pendingCopy!.future;
    return [_component];
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    pasted.add((mode: mode, targets: targets, items: items));
    if (pasteFailure != null) throw pasteFailure!;
    return BomPasteResult(
      targets: targets.length,
      added: items.length,
      removed: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
