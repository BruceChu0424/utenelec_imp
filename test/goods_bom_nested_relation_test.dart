import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'support/goods_bom_edit_test_api.dart';
import 'support/audit_screenshot_support.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

class _FakeGoodsBomRepository implements GoodsBomRepository {
  _FakeGoodsBomRepository({
    this.empty = false,
    this.nestedLearned = false,
    this.nestedHasChildren = false,
  });

  final bool empty;

  /// 嵌套组件是系统学出的组件(ADR-129 编辑/删除提示用例)。
  final bool nestedLearned;
  final bool nestedHasChildren;
  Object? grandchildReadFailureOnce;
  Completer<List<GoodsBomItem>>? grandchildRead;
  final listCalls = <String>[];
  final parent = const GoodsBomItem(
    id: 'row-b',
    componentGoodsId: 'goods-b',
    componentCode: 'B',
    componentName: 'Parent component',
    hasChildren: true,
    qty: 1,
  );

  late final nested = GoodsBomItem(
    id: 'row-c',
    componentGoodsId: 'goods-c',
    componentCode: 'C',
    componentName: 'Nested component',
    colorLegacyId: 9,
    qty: 2,
    price: 12,
    controlStage: BomControlStage.finish,
    consumptionBasis: BomConsumptionBasis.perPackage,
    basisOutputQty: 100,
    allowPartialPackage: false,
    hardGate: false,
    systemLearned: nestedLearned,
    hasChildren: nestedHasChildren,
  );
  final grandchild = const GoodsBomItem(
    id: 'row-d',
    componentGoodsId: 'goods-d',
    componentCode: 'D',
    componentName: 'Unloaded grandchild',
    qty: 3,
  );

  /// 批量删除调用记录：(父货品 id, 提交的关系行 id)。
  final batchDeleteCalls = <(String, List<String>)>[];
  String? updatedParentId;
  String? updatedItemId;
  Map<String, dynamic>? updatedBody;
  String? auditedParentId;
  String? auditedItemId;
  bool? auditedValue;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    if (empty) return const [];
    if (goodsId == 'goods-c') {
      final failure = grandchildReadFailureOnce;
      grandchildReadFailureOnce = null;
      if (failure != null) throw failure;
      return grandchildRead?.future ?? Future.value([grandchild]);
    }
    return switch (goodsId) {
      'goods-a' => [parent],
      'goods-b' => [nested],
      _ => const [],
    };
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async {
    batchDeleteCalls.add((goodsId, List<String>.of(itemIds)));
    return itemIds.length;
  }

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    updatedParentId = goodsId;
    updatedItemId = itemId;
    updatedBody = Map<String, dynamic>.from(body);
    return nested;
  }

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async => 0;

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async {
    auditedParentId = goodsId;
    auditedItemId = itemId;
    auditedValue = audited;
    return nested;
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async => throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async => throw UnimplementedError();
}

/// 编辑弹窗的「设计使用数量」输入框。
final _editQtyField = find.descendant(
  of: find.byKey(const Key('goods-bom-edit-qty')),
  matching: find.byType(TextField),
);

Future<void> _pumpBom(
  WidgetTester tester,
  _FakeGoodsBomRepository repo, {
  bool editMode = true,
  bool expandParent = true,
  bool screenshot = false,
  bool waitForSnapshot = true,
  ValueChanged<bool>? interactionChanged,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        bomComponentSuggestionsProvider.overrideWithValue(
          (ref, query) async => const [],
        ),
        apiClientProvider.overrideWithValue(GoodsBomEditTestApi(repo)),
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(null, web: true),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsBomEdit,
          Perm.goodsBomCreate,
          Perm.goodsBomDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: screenshot
            ? auditScreenshotTheme(
                buildLightTheme().copyWith(platform: platform),
              )
            : ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: RepaintBoundary(
          key: const Key('goods-bom-test-capture'),
          child: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: true,
              canEdit: true,
              canDelete: true,
              onInteractionChanged: interactionChanged,
            ),
          ),
        ),
      ),
    ),
  );
  if (!waitForSnapshot) return;
  await tester.pumpAndSettle();

  if (editMode) await enterBomEdit(tester);
  if (!expandParent) return;
  final parentToggle = find.byKey(
    const ValueKey('goods-bom-tree-toggle-row-b'),
  );
  await tester.ensureVisible(parentToggle);
  // 层级列的明确箭头负责展开；整行单击只负责选择。
  final toggleExtent = platform == TargetPlatform.android ? 48.0 : 32.0;
  expect(tester.getSize(parentToggle), Size.square(toggleExtent));
  await tester.tap(parentToggle);
  await tester.pumpAndSettle();
  expect(repo.listCalls, contains('goods-b'));
  final nestedName = find.textContaining('Nested component');
  expect(nestedName, findsOneWidget);
  expect(find.text('1.1'), findsNothing);
  expect(find.text('组件 2 级'), findsNothing);
  // 层级交给缩进和连续连接线；编号看独立「编号」列。
  expect(find.textContaining('路径：'), findsNothing);
  if (!editMode) return;
  // The name is now an editable input. Select the actual nested relationship
  // through its checkbox without replacing or focusing the component name.
  await tester.tap(
    find
        .descendant(
          of: find.byKey(const ValueKey('row-drag-slot:goods-a/row-b/row-c')),
          matching: find.byType(Checkbox),
        )
        .hitTestable()
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('完整预读后全部展开不增加读取，全部收起剪裁隐藏行勾选', (tester) async {
    final repo = _FakeGoodsBomRepository(nestedHasChildren: true);
    await _pumpBom(tester, repo, editMode: false, expandParent: false);
    final expansion = find.byKey(const Key('goods-bom-tree-expansion'));
    expect(find.text('Nested component'), findsNothing);
    expect(repo.listCalls, ['goods-a', 'goods-b', 'goods-c']);
    final readCount = repo.listCalls.length;
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Unloaded grandchild'), findsOneWidget);
    expect(repo.listCalls, hasLength(readCount), reason: '全部展开只投影已接受的完整快照');
    expect(find.text('全部收起'), findsOneWidget);
    final grandchildRow = find.byKey(
      const ValueKey('row:goods-a/row-b/row-c/row-d'),
    );
    await tester.tap(
      find.descendant(of: grandchildRow, matching: find.byType(Checkbox)).first,
    );
    await tester.pumpAndSettle();
    final selectedTable = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('goods-bom-table-true-false')),
    );
    expect(selectedTable.selectedIds, {'goods-c|row-d'});
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Nested component'), findsNothing);
    expect(find.text('Unloaded grandchild'), findsNothing);
    expect(find.text('全部展开'), findsOneWidget);
    final collapsedTable = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('goods-bom-table-true-false')),
    );
    expect(collapsedTable.selectedIds, isEmpty);
    expect(repo.listCalls, hasLength(readCount), reason: '收起只改变显示，不读写业务');
    expect(repo.updatedBody, isNull);
    expect(repo.batchDeleteCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑中全部展开及收起保留正在输入的原始数量和控制器', (tester) async {
    final repo = _FakeGoodsBomRepository(nestedHasChildren: true);
    await _pumpBom(tester, repo, expandParent: false);
    final activateQty = find.byKey(
      const ValueKey('goods-bom-activate-qty-goods-a/row-b'),
    );
    await tester.ensureVisible(activateQty);
    await tester.pumpAndSettle();
    await tester.tap(activateQty);
    await tester.pumpAndSettle();
    final qtyEditor = find.byKey(
      const ValueKey('goods-bom-inline-qty-goods-a/row-b'),
    );
    await tester.enterText(qtyEditor, '1.234500');
    final controller = tester.widget<TextField>(qtyEditor).controller!;
    final expansion = find.byKey(const Key('goods-bom-tree-expansion'));
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Unloaded grandchild'), findsOneWidget);
    expect(tester.widget<TextField>(qtyEditor).controller, same(controller));
    expect(controller.text, '1.234500');
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Nested component'), findsNothing);
    expect(tester.widget<TextField>(qtyEditor).controller, same(controller));
    expect(controller.text, '1.234500');
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Unloaded grandchild'), findsOneWidget);
    expect(tester.widget<TextField>(qtyEditor).controller, same(controller));
    expect(controller.text, '1.234500');
    expect(repo.updatedBody, isNull, reason: '展开、收起不暂存或提交用户输入');
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整预读失败不发布残缺树，重试与后续失败保留完整快照', (tester) async {
    final repo = _FakeGoodsBomRepository(nestedHasChildren: true)
      ..grandchildReadFailureOnce = StateError('temporary read failure');
    await _pumpBom(tester, repo, editMode: false, expandParent: false);
    final expansion = find.byKey(const Key('goods-bom-tree-expansion'));
    final tableFinder = find.byKey(
      const ValueKey('goods-bom-table-true-false'),
    );
    MasterDataTableView<dynamic> table() => tester.widget(tableFinder);
    expect(repo.listCalls, ['goods-a', 'goods-b', 'goods-c']);
    expect(table().items, isEmpty, reason: '根和子层读取成功也不能发布失败快照的一部分');
    expect(table().error, '加载组装信息失败');
    expect(find.text('Parent component'), findsNothing);
    expect(find.text('Nested component'), findsNothing);
    expect(find.text('Unloaded grandchild'), findsNothing);
    expect(find.text('全部收起'), findsNothing);
    expect(find.text('全部展开'), findsOneWidget);
    await tester.tap(
      find.descendant(of: tableFinder, matching: find.text('重试')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(repo.listCalls, [
      for (var attempt = 0; attempt < 2; attempt++) ...[
        'goods-a',
        'goods-b',
        'goods-c',
      ],
    ]);
    expect(table().error, isNull);
    expect(find.text('Parent component'), findsOneWidget);
    expect(find.text('Nested component'), findsNothing);
    expect(find.text('Unloaded grandchild'), findsNothing);
    final readCount = repo.listCalls.length;
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.text('Unloaded grandchild'), findsOneWidget);
    expect(find.text('全部收起'), findsOneWidget);
    expect(repo.listCalls, hasLength(readCount));

    await tester.tap(
      find.byKey(const Key('master-data-table-select-all')).hitTestable().last,
    );
    await tester.pumpAndSettle();
    const acceptedRelations = {
      'goods-a|row-b',
      'goods-b|row-c',
      'goods-c|row-d',
    };
    expect(table().selectedIds, acceptedRelations);
    final acceptedItems = List<Object?>.of(table().items);
    expect(acceptedItems, hasLength(3));
    repo.grandchildReadFailureOnce = StateError('refresh subtree failed');
    final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
    final refreshing = state.refresh();
    await tester.pumpAndSettle();
    await refreshing;
    expect(table().items, orderedEquals(acceptedItems));
    expect(table().selectedIds, acceptedRelations);
    expect(table().error, '加载组装信息失败');
    final retrying = state.refresh();
    await tester.pumpAndSettle();
    await retrying;
    expect(table().error, isNull);
    expect(table().items, hasLength(3));
    expect(table().selectedIds, acceptedRelations);
    expect(repo.listCalls, [
      for (var attempt = 0; attempt < 4; attempt++) ...[
        'goods-a',
        'goods-b',
        'goods-c',
      ],
    ]);
    expect(repo.updatedBody, isNull);
    expect(repo.batchDeleteCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整预读返回时页面已退出，不回写旧树', (tester) async {
    final pending = Completer<List<GoodsBomItem>>();
    final repo = _FakeGoodsBomRepository(nestedHasChildren: true)
      ..grandchildRead = pending;
    final interactions = <bool>[];
    await _pumpBom(
      tester,
      repo,
      editMode: false,
      expandParent: false,
      waitForSnapshot: false,
      interactionChanged: interactions.add,
    );
    for (
      var frame = 0;
      frame < 20 && !repo.listCalls.contains('goods-c');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(repo.listCalls, contains('goods-c'));
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('goods-bom-table-true-false')),
    );
    expect(table.items, isEmpty, reason: '读取未完成时没有可接受的部分树');
    expect(find.text('Parent component'), findsNothing);
    final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
    expect(await state.finishEditing(), isTrue, reason: '只读加载不拦离开页面');
    expect(interactions, isNot(contains(true)), reason: '只读展开不向宿主申请导航锁');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([repo.grandchild]);
    await tester.pumpAndSettle();
    expect(find.text('Unloaded grandchild'), findsNothing);
    expect(repo.updatedBody, isNull);
    expect(repo.batchDeleteCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'compact BOM keeps view, active editors and new rows aligned: $platform',
      (tester) async {
        final repo = _FakeGoodsBomRepository();
        await _pumpBom(tester, repo, editMode: false, platform: platform);
        final controlHeight = platform == TargetPlatform.android ? 48.0 : 32.0;
        final nestedRow = find.byKey(const ValueKey('row:goods-a/row-b/row-c'));
        void expectCompactRow(Finder row) {
          expect(row, findsOneWidget);
          expect(
            tester.getSize(row).height,
            inInclusiveRange(controlHeight + 8, controlHeight + 9),
            reason: '单行内容、公共桌面/触控控件与上下各4px留白决定行高',
          );
          expect(tester.takeException(), isNull);
        }

        expectCompactRow(nestedRow);
        await enterBomEdit(tester);
        expectCompactRow(nestedRow);

        final activateName = find.byKey(
          const ValueKey('goods-bom-activate-name-goods-a/row-b/row-c'),
        );
        await tester.ensureVisible(activateName);
        await tester.tap(activateName);
        await tester.pumpAndSettle();
        final nameEditor = find.byKey(
          const ValueKey('goods-bom-name-row:goods-b|row-c'),
        );
        expect(nameEditor, findsOneWidget);
        expectCompactRow(nestedRow);

        final activateQty = find.byKey(
          const ValueKey('goods-bom-activate-qty-goods-a/row-b/row-c'),
        );
        await tester.ensureVisible(activateQty);
        await tester.tap(activateQty);
        await tester.pumpAndSettle();
        final qtyEditor = find.byKey(
          const ValueKey('goods-bom-inline-qty-goods-a/row-b/row-c'),
        );
        await tester.enterText(qtyEditor, '3');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(qtyEditor).controller?.text, '3');
        expectCompactRow(nestedRow);
        for (final editor in [nameEditor, qtyEditor]) {
          final bounds = tester.getRect(nestedRow);
          final editorBounds = tester.getRect(editor);
          expect(editorBounds.top, greaterThanOrEqualTo(bounds.top));
          expect(editorBounds.bottom, lessThanOrEqualTo(bounds.bottom));
          expect(
            tester.getSize(editor).height,
            greaterThanOrEqualTo(controlHeight),
          );
        }

        final addChild = find.byKey(
          const ValueKey('goods-bom-add-child-goods-a/row-b/row-c'),
        );
        await tester.ensureVisible(addChild);
        await tester.tap(addChild);
        await tester.pumpAndSettle();
        final newChildRow = find.byKey(
          const ValueKey('row:goods-a/row-b/row-c/__new-child'),
        );
        expectCompactRow(newChildRow);
        final newChildEditor = find.descendant(
          of: find.byKey(const ValueKey('goods-bom-name-child:goods-c')),
          matching: find.byType(TextField),
        );
        await tester.enterText(newChildEditor, '待选子组件');
        await tester.pumpAndSettle();
        expectCompactRow(newChildRow);
        expect(
          tester.getRect(newChildEditor).bottom,
          lessThanOrEqualTo(tester.getRect(newChildRow).bottom),
        );
        expect(find.text('1.1.1'), findsNothing);
        expect(find.textContaining('组件 3 级'), findsNothing);
        expect(repo.updatedBody, isNull, reason: '几何与交互验证不提交草稿');
      },
    );
  }

  testWidgets(
    'goods:view + goods:bom:create cannot bypass edit mode permission',
    (tester) async {
      final repo = _FakeGoodsBomRepository(empty: true);
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            goodsBomRepositoryProvider.overrideWithValue(repo),
            sensitiveReadBoundaryProvider.overrideWithValue(
              SensitiveReadBoundary(
                identity: null,
                api: ApiClient(Dio()),
                permissions: {Perm.goodsView, Perm.goodsBomCreate},
                superAdmin: false,
              ),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.goodsView,
              Perm.goodsBomCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: Scaffold(
              body: GoodsBomTab(
                goodsId: 'goods-a',
                canCreate: true,
                canEdit: false,
                canDelete: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-edit-mode')), findsNothing);
      expect(find.text('暂无组装信息'), findsOneWidget);
      expect(find.byType(UtenFloatingWindow), findsNothing);
    },
  );

  testWidgets('preview button sits in the toolbar next to fullscreen', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var previews = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goodsBomRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: true,
              canEdit: true,
              canDelete: true,
              onPreview: () => previews++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 2026-09-12：「预览」从详情头部迁入表格工具条，紧挨「全屏」按钮（左簇
    // toolbarLeadingActions），样式同款；不传 onPreview 则不渲染。
    final preview = find.widgetWithText(UtenButton, '预览');
    final fullscreen = find.widgetWithText(UtenButton, '全屏');
    expect(preview, findsOneWidget);
    expect(fullscreen, findsOneWidget);
    expect(tester.getTopLeft(preview).dy, tester.getTopLeft(fullscreen).dy);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(previews, 1);
  });

  testWidgets('nested delete is one request scoped to the viewed goods tree', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // ADR-111：删除只剩批量这一条路径，且不再按父货品分组——请求挂在本页货品
    // (组装树的根)下，服务端核对嵌套行的父件在这棵树里、按它真正的父件软删。
    await saveBomEdit(tester);
    expect(repo.batchDeleteCalls.length, 1);
    expect(repo.batchDeleteCalls.first.$1, 'goods-a');
    expect(repo.batchDeleteCalls.first.$2, ['row-c']);
    // 旧的单条 DELETE 不再被页面调用(接口保留给其它调用方)。
    // 「删完按钮回灰」这条断言挪到 goods_bom_multi_select_delete_test.dart：
    // 页面改为按业务键剪裁勾选集(勾选不再被重载无条件清空)，要用一个真会
    // 删掉行的伪仓库才能验证，本文件的伪仓库并不真正移除数据。
  });

  testWidgets('nested edit keeps row color and uses the owning parent', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('goods-bom-tree-cell-row-c')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    // 字段名「设计使用数量」，打开时按 6 位去尾零回填原值。
    expect(_editQtyField, findsOneWidget);
    expect(
      tester.widget<TextField>(_editQtyField).decoration!.hintText,
      '设计使用数量',
    );
    expect(tester.widget<TextField>(_editQtyField).controller?.text, '2');
    await tester.enterText(_editQtyField, '3');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await saveBomEdit(tester);
    expect(repo.updatedParentId, 'goods-b');
    expect(repo.updatedItemId, 'row-c');
    // A legacy-only history row stays untouched; ordinary editing must not turn
    // its old integer shadow into a new runtime relationship.
    expect(repo.updatedBody?.containsKey('colorLegacyId'), isFalse);
    expect(repo.updatedBody?.containsKey('colorId'), isFalse);
    expect(repo.updatedBody?['qty'], 3);
    // 生产管控字段已从编辑器移除（服务端 apply() 在省略时保留既有值），
    // 故保存体不再包含 controlStage/consumptionBasis 等。
    expect(repo.updatedBody?.containsKey('controlStage'), isFalse);
    expect(repo.updatedBody?.containsKey('hardGate'), isFalse);
  });

  testWidgets('edit sends the design qty only when the user changed it', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository(nestedLearned: true);
    await _pumpBom(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('goods-bom-tree-cell-row-c')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    // 系统学出的组件：先用黄色提示说清改数量的后果。
    expect(
      find.text('这是系统按真实用料学出的组件；改设计使用数量后转为人工维护，真实使用数量照常累计'),
      findsOneWidget,
    );
    // 只改备注：请求里没有 qty，服务端保留原设计使用数量(学习组件不被接管)。
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == '备注',
      ),
      '换供应商试产',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await saveBomEdit(tester);
    expect(repo.updatedBody?.containsKey('qty'), isFalse);
    expect(repo.updatedBody?['summary'], '换供应商试产');
  });

  testWidgets('clearing the design qty is rejected instead of defaulting', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('goods-bom-tree-cell-row-c')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    await tester.enterText(_editQtyField, '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updatedBody, isNull, reason: '空的设计使用数量不能提交');
    expect(find.text('请填写设计使用数量'), findsOneWidget);
  });

  testWidgets('deleting a learned component explains it will not come back', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository(nestedLearned: true);
    await _pumpBom(tester, repo);

    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('goods-bom-delete-learned-note')),
      findsOneWidget,
    );
    expect(find.textContaining('删除后系统不会再自动加回'), findsOneWidget);
  });

  testWidgets('audit mode marks row audited on single tap', (tester) async {
    final repo = _FakeGoodsBomRepository();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsBomRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue({Perm.goodsBomAudit}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        // canEdit=false：审计与编辑权限解耦（质检可只有审计权）。
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: false,
              canEdit: false,
              canDelete: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('审计模式'));
    await tester.pumpAndSettle();
    expect(find.text('退出审计'), findsOneWidget);

    // 2026-09-25 审计改版：单击行只管选中；标记走「已审」列的圆形对勾按钮
    // (右键菜单是另一条等价路径)。首行即顶层组件 Parent component。
    final auditCell = find.byIcon(Icons.radio_button_unchecked).first;
    await tester.ensureVisible(auditCell);
    await tester.tap(auditCell);
    await tester.pumpAndSettle();

    expect(repo.auditedParentId, 'goods-a');
    expect(repo.auditedItemId, 'row-b');
    expect(repo.auditedValue, isTrue);
  });

  testWidgets('audit mode button hidden without goods:bom:audit', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsBomRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: false,
              canEdit: false,
              canDelete: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('审计模式'), findsNothing);
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
  });

  test('BOM 详情解析 UUID 真源颜色和默认供应商', () {
    final item = GoodsBomItem.fromJson({
      'id': 'line-1',
      'componentGoodsId': 'goods-1',
      'colorId': 'color-uuid',
      'colorLegacyId': 7,
      'defaultSupplierId': 'supplier-uuid',
      'vendLegacyId': 9,
    });

    expect(item.colorId, 'color-uuid');
    expect(item.defaultSupplierId, 'supplier-uuid');
  });

  testWidgets(
    'BOM compact editing visual fixture',
    (tester) async {
      await loadAuditScreenshotFonts(tester);
      final repo = _FakeGoodsBomRepository(nestedHasChildren: true);
      await _pumpBom(tester, repo, screenshot: true);
      await tester.tap(find.byKey(const Key('goods-bom-tree-expansion')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('goods-bom-activate-name-goods-a/row-b/row-c'),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('goods-bom-test-capture')),
      );
      await tester.runAsync(() async {
        final picture = await boundary.toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/goods-bom-compact-edit-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
      expect(tester.takeException(), isNull);
    },
    skip: !const bool.fromEnvironment('UTEN_BOM_CAPTURE'),
  );
}
