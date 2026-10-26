import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

import '../../support/goods_bom_edit_test_api.dart';

/// The target precedes the source: expanding its children moves the pressed
/// source outside the viewport while that source still owns the mouse gesture.
class _ExpandableBomRepo implements GoodsBomRepository {
  _ExpandableBomRepo({this.childCount = 1000, this.delayChildren = false})
    : children = [
        for (var i = 0; i < childCount; i++)
          GoodsBomItem(
            id: 'child-$i',
            componentGoodsId: 'child-goods-$i',
            componentName: '子件 $i',
            qty: 1,
          ),
      ];

  final int childCount;
  final bool delayChildren;
  final List<GoodsBomItem> children;
  final childRead = Completer<List<GoodsBomItem>>();
  final moveCalls = <List<GoodsBomMove>>[];
  int childReads = 0;
  final roots = <GoodsBomItem>[
    const GoodsBomItem(
      id: 'target',
      componentGoodsId: 'assembly',
      componentName: '层级组件',
      hasChildren: true,
      qty: 1,
    ),
    const GoodsBomItem(
      id: 'source',
      componentGoodsId: 'movable',
      componentName: '待移动组件',
      qty: 1,
    ),
    const GoodsBomItem(
      id: 'safe',
      componentGoodsId: 'safe-goods',
      componentName: '其他落点',
      qty: 1,
    ),
  ];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    if (goodsId == 'root') return List.of(roots);
    if (goodsId != 'assembly') return const [];
    childReads++;
    return delayChildren ? childRead.future : List.of(children);
  }

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async {
    moveCalls.add(List.of(moves));
    for (final move in moves) {
      final source = roots.firstWhere((item) => item.id == move.itemId);
      roots.remove(source);
      final siblings = move.targetParentGoodsId == 'assembly'
          ? children
          : roots;
      final anchor = siblings.indexWhere(
        (item) => item.id == move.anchorItemId,
      );
      siblings.insert(
        anchor < 0 ? siblings.length : anchor + (move.afterAnchor ? 1 : 0),
        source,
      );
    }
    return moves.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _slot(String occurrence) =>
    find.byKey(ValueKey('row-drag-slot:root/$occurrence'));

Finder get _retainedSource => find.byKey(
  const ValueKey('row-drag-slot:root/source'),
  skipOffstage: false,
);

Finder get _mountedSlots => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('row-drag-slot:');
}, skipOffstage: false);

MasterDataTableView<dynamic> _table(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate((widget) => widget is MasterDataTableView),
);

Future<GoodsBomEditTestApi> _pumpTab(
  WidgetTester tester,
  _ExpandableBomRepo repository,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = GoodsBomEditTestApi(repository);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(null, web: true),
        ),
        goodsBomRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.goodsView,
          Perm.goodsBomEdit,
          Perm.goodsBomCreate,
          Perm.goodsBomDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'root',
            canCreate: true,
            canEdit: true,
            canDelete: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await enterBomEdit(tester);
  return api;
}

Future<TestGesture> _pickUpSource(WidgetTester tester) async {
  final tree = find.byKey(const ValueKey('goods-bom-tree-cell-source'));
  final cell = tester.widget<UtenTreeTableCell>(tree);
  final bounds = tester.getRect(tree);
  final prefix = UtenTreeTableCell.prefixWidthOf(
    tester.element(tree),
    depth: cell.depth,
    indent: cell.indent,
    maxVisualDepth: cell.maxVisualDepth,
    desktopToggleExtent: cell.desktopToggleExtent,
  );
  // Start in the tree's empty prefix/name gap, outside editor/button gestures.
  final gesture = await tester.startGesture(
    Offset(bounds.left + prefix + 2, bounds.center.dy),
    pointer: 31,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  return gesture;
}

Future<void> _hoverTarget(WidgetTester tester, TestGesture gesture) async {
  final target = tester.getRect(_slot('target'));
  await gesture.moveTo(target.center);
  await tester.pump(const Duration(milliseconds: 750));
  await tester.pump();
}

Future<void> _dropAfter(
  WidgetTester tester,
  TestGesture gesture,
  String occurrence,
) async {
  final rect = tester.getRect(_slot(occurrence));
  await gesture.moveTo(Offset(rect.center.dx, rect.bottom - rect.height * .1));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('悬停展开千条子件保持视口构建，源行被推离屏仍能移到新子行', (tester) async {
    final repository = _ExpandableBomRepo();
    final api = await _pumpTab(tester, repository);
    final gesture = await _pickUpSource(tester);
    await _hoverTarget(tester, gesture);
    await tester.pumpAndSettle();

    expect(repository.childReads, 1);
    expect(_table(tester).items, hasLength(1003));
    expect(
      _mountedSlots.evaluate().length,
      lessThan(80),
      reason: '千条数据可用，但只应挂载视口和缓存范围及正在拖拽的源行',
    );
    expect(find.text('子件 999'), findsNothing);
    expect(_slot('target/child-0'), findsOneWidget);
    expect(
      _retainedSource,
      findsOneWidget,
      reason: '展开把源行推离屏后，必须保留它拥有的进行中长按手势',
    );

    await _dropAfter(tester, gesture, 'target/child-0');
    expect(repository.moveCalls, isEmpty, reason: '移动先进入编辑草稿');
    await saveBomEdit(tester);
    expect(api.commitCalls, 1, reason: '展开后离屏的源行仍必须收到 pointer up');
    final move = repository.moveCalls.single.single;
    expect(move.itemId, 'source');
    expect(move.targetParentGoodsId, 'assembly');
    expect(move.anchorItemId, 'child-0');
    expect(move.afterAnchor, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬停子级请求未完成时可继续拖到其他落点，不等待加载', (tester) async {
    final repository = _ExpandableBomRepo(delayChildren: true);
    final api = await _pumpTab(tester, repository);
    final gesture = await _pickUpSource(tester);
    await _hoverTarget(tester, gesture);

    expect(repository.childReads, 1);
    expect(repository.childRead.isCompleted, isFalse);
    expect(find.text('正在加载下级…'), findsOneWidget);
    expect(_slot('safe'), findsOneWidget);

    await _dropAfter(tester, gesture, 'safe');
    expect(repository.childRead.isCompleted, isFalse);
    expect(_table(tester).items, hasLength(3));
    expect(find.text('正在移动组件'), findsNothing);
    repository.childRead.complete(repository.children);
    await tester.pumpAndSettle();
    await saveBomEdit(tester);

    expect(api.commitCalls, 1);
    final move = repository.moveCalls.single.single;
    expect(move.itemId, 'source');
    expect(move.targetParentGoodsId, 'root');
    expect(move.anchorItemId, 'safe');
    expect(move.afterAnchor, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬停子级请求未完成时 ESC 立即取消拖拽，表体仍可选择', (tester) async {
    final repository = _ExpandableBomRepo(delayChildren: true);
    final api = await _pumpTab(tester, repository);
    final gesture = await _pickUpSource(tester);
    await _hoverTarget(tester, gesture);

    expect(find.text('正在加载下级…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.tap(
      find.descendant(of: _slot('safe'), matching: find.byType(Checkbox)).first,
    );
    await tester.pump();

    expect(repository.childRead.isCompleted, isFalse);
    expect(_table(tester).selectedIds, contains('root|safe'));
    expect(find.byKey(const ValueKey('row-drag-indicator')), findsNothing);
    expect(repository.moveCalls, isEmpty);
    repository.childRead.complete(repository.children);
    await tester.pumpAndSettle();
    await saveBomEdit(tester);
    expect(api.previewCalls, 0);
    expect(api.commitCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大层级展开后 ESC 取消即释放离屏源行，表体继续响应', (tester) async {
    final repository = _ExpandableBomRepo();
    final api = await _pumpTab(tester, repository);
    final gesture = await _pickUpSource(tester);
    await _hoverTarget(tester, gesture);
    await tester.pumpAndSettle();

    expect(_retainedSource, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_retainedSource, findsNothing, reason: '拖拽结束后释放临时保活，不能留下千条离屏行');
    await tester.tap(
      find
          .descendant(
            of: _slot('target/child-0'),
            matching: find.byType(Checkbox),
          )
          .first,
    );
    await tester.pump();
    expect(_table(tester).selectedIds, contains('assembly|child-0'));
    expect(find.byKey(const ValueKey('row-drag-indicator')), findsNothing);
    expect(_mountedSlots.evaluate().length, lessThan(80));
    await saveBomEdit(tester);
    expect(api.previewCalls, 0);
    expect(api.commitCalls, 0);
    expect(repository.moveCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏表格悬停大层级后仍保留源行手势并完成草稿移动', (tester) async {
    final repository = _ExpandableBomRepo();
    final api = await _pumpTab(tester, repository);
    await tester.tap(
      find
          .byKey(const ValueKey('master-table-fullscreen-toggle'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);

    final gesture = await _pickUpSource(tester);
    await _hoverTarget(tester, gesture);
    await tester.pumpAndSettle();
    expect(_retainedSource, findsOneWidget);
    expect(_mountedSlots.evaluate().length, lessThan(80));
    await _dropAfter(tester, gesture, 'target/child-0');
    await saveBomEdit(tester);

    expect(api.commitCalls, 1);
    final move = repository.moveCalls.single.single;
    expect(move.itemId, 'source');
    expect(move.targetParentGoodsId, 'assembly');
    expect(move.anchorItemId, 'child-0');
    expect(tester.takeException(), isNull);
  });
}
