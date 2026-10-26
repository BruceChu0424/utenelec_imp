import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

GoodsBomItem _item(String id, String goods, {bool branch = true}) =>
    GoodsBomItem(
      id: id,
      componentGoodsId: goods,
      componentName: id,
      componentCode: goods,
      componentUnitName: '个',
      hasChildren: branch,
      qty: 1,
    );

class _TreeRepo implements GoodsBomRepository {
  _TreeRepo()
    : tree = {
        'root': [
          _item('root-a', 'assembly-a'),
          _item('root-b', 'assembly-b'),
          _item('root-c', 'assembly-a'),
        ],
        'assembly-a': [_item('a-x', 'shared-x'), _item('a-y', 'part-y')],
        'assembly-b': [_item('b-x', 'shared-x'), _item('b-z', 'part-z')],
        'shared-x': [_item('shared-leaf', 'deep-leaf')],
        'deep-leaf': [_item('last-leaf', 'last', branch: false)],
        'part-y': [_item('y-leaf', 'leaf-y', branch: false)],
        'part-z': [_item('z-leaf', 'leaf-z', branch: false)],
      };

  final Map<String, List<GoodsBomItem>> tree;
  final calls = <String>[];
  final pending = <String, Completer<List<GoodsBomItem>>>{};
  final failOnce = <String>{};
  int active = 0;
  int peak = 0;
  int learningCalls = 0;
  int writes = 0;
  bool delayReads = false;

  int count(String id) => calls.where((call) => call == id).length;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    calls.add(goodsId);
    active++;
    if (active > peak) peak = active;
    try {
      if (failOnce.remove(goodsId)) throw StateError('read failed: $goodsId');
      if (pending[goodsId] case final request?) return await request.future;
      if (delayReads) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return List.of(tree[goodsId] ?? const []);
    } finally {
      active--;
    }
  }

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async {
    learningCalls++;
    return const GoodsBomLearningSummary();
  }

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async => const GoodsBomLearningSummary();

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    writes++;
    return tree[goodsId]!.firstWhere((item) => item.id == itemId);
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async {
    writes++;
    return itemIds.length;
  }

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async {
    writes++;
    return moves.length;
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    writes++;
    return BomPasteResult(
      targets: targets.length,
      added: items.length,
      removed: 0,
    );
  }

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async => throw UnimplementedError();
}

Future<GoodsBomEditTestApi> _pump(
  WidgetTester tester,
  _TreeRepo repo, {
  bool editing = false,
  Size size = const Size(1800, 1100),
  double fontScale = 1,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = GoodsBomEditTestApi(repo);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        bomComponentSuggestionsProvider.overrideWithValue(
          (ref, query) async => const [],
        ),
        apiClientProvider.overrideWithValue(api),
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
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(fontScale)),
          child: child!,
        ),
        home: const Scaffold(
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
  if (editing) await enterBomEdit(tester);
  return api;
}

Finder _row(String path) => find.byKey(ValueKey('row:$path'));

Finder _toggle(String path, String id) => find.descendant(
  of: _row(path),
  matching: find.byKey(ValueKey('goods-bom-tree-toggle-$id')),
);

Future<void> _ctrlTap(
  WidgetTester tester,
  Finder toggle, {
  bool settle = true,
}) async {
  await tester.ensureVisible(toggle);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.tap(toggle, warnIfMissed: false);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  if (settle) await tester.pumpAndSettle();
}

_TreeRepo _twelvePendingBranches() {
  final repo = _TreeRepo();
  repo.tree['root'] = [
    for (var index = 0; index < 12; index++)
      _item('row-$index', 'goods-$index'),
  ];
  for (var index = 0; index < 12; index++) {
    repo.tree['goods-$index'] = [
      _item('child-$index', 'leaf-$index', branch: false),
    ];
    repo.pending['goods-$index'] = Completer<List<GoodsBomItem>>();
  }
  return repo;
}

Future<void> _tapTwelveBranches(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    final toggle = _toggle('root/row-$index', 'row-$index');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
  }
}

void _completePendingBranches(_TreeRepo repo) {
  for (final entry in repo.pending.entries) {
    if (!entry.value.isCompleted) entry.value.complete(repo.tree[entry.key]!);
  }
}

void main() {
  testWidgets('树展开收起逐帧保留已经呈现的名称列宽', (tester) async {
    final repo = _TreeRepo();
    repo.tree['root'] = [
      const GoodsBomItem(
        id: 'root-a',
        componentGoodsId: 'assembly-a',
        componentName: 'MainAssembly12345678901234567890',
        hasChildren: true,
        qty: 1,
      ),
    ];
    await _pump(tester, repo);
    final root = find.byKey(const ValueKey('goods-bom-tree-cell-root-a'));
    final settledWidth = tester.getSize(root).width;
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.tap(_toggle('root/root-a', 'root-a'));
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getSize(root).width,
          greaterThanOrEqualTo(settledWidth - 0.5),
          reason: '第$cycle次切换第$frame帧不能先缩回表头宽度再变宽',
        );
      }
      await tester.pumpAndSettle();
    }
    expect(repo.count('assembly-a'), 1, reason: '折叠保留同代子层数据');
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通十二箭头连点只发送四次，失败释放槽且可重试', (tester) async {
    final repo = _twelvePendingBranches();
    await _pump(tester, repo);
    await _tapTwelveBranches(tester);
    expect(repo.calls.length, 5, reason: '一个根清单和四个实际子清单，其余八个排队');
    expect(repo.peak, 4);
    repo.pending['goods-0']!.completeError(StateError('first read failed'));
    for (var frame = 0; frame < 10 && repo.count('goods-4') == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(repo.count('goods-4'), 1, reason: '失败立即把实际请求槽交给排队读取');
    _completePendingBranches(repo);
    await tester.pumpAndSettle();
    expect(repo.peak, 4);
    expect(repo.calls.length, 13);
    repo.pending.remove('goods-0');
    final first = _toggle('root/row-0', 'row-0');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(repo.count('goods-0'), 2);
    expect(_row('root/row-0/child-0'), findsOneWidget);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通排队时刷新退休未发请求，新代不等待旧慢请求', (tester) async {
    final repo = _twelvePendingBranches();
    await _pump(tester, repo);
    await _tapTwelveBranches(tester);
    final refreshing = tester
        .state<GoodsBomTabState>(find.byType(GoodsBomTab))
        .refresh();
    await tester.pumpAndSettle();
    await refreshing;
    expect(repo.count('root'), 2);
    expect(repo.calls.length, 6);
    final last = _toggle('root/row-11', 'row-11');
    await tester.ensureVisible(last);
    await tester.tap(last);
    await tester.pump();
    expect(repo.count('goods-11'), 1, reason: '新读取代次有独立槽，不等旧四个慢GET');
    _completePendingBranches(repo);
    await tester.pumpAndSettle();
    for (var index = 4; index < 11; index++) {
      expect(repo.count('goods-$index'), 0, reason: '退休的旧排队项未发送');
    }
    for (var index = 0; index < 4; index++) {
      expect(
        _row('root/row-$index/child-$index'),
        findsNothing,
        reason: '旧已发回包不发布',
      );
    }
    expect(_row('root/row-11/child-11'), findsOneWidget);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通排队时离开页面不再发送旧队列且观察已发请求完成', (tester) async {
    final repo = _twelvePendingBranches();
    await _pump(tester, repo);
    await _tapTwelveBranches(tester);
    expect(repo.calls.length, 5);
    await tester.pumpWidget(const SizedBox.shrink());
    _completePendingBranches(repo);
    await tester.pumpAndSettle();
    expect(repo.calls.length, 5);
    expect(repo.active, 0);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深层组件自动列宽计入树前缀，正常长度名称不被提前截断', (tester) async {
    final repo = _TreeRepo();
    repo.tree['root'] = [_item('node-0', 'g-0')];
    for (var depth = 0; depth < 5; depth++) {
      repo.tree['g-$depth'] = [
        _item('node-${depth + 1}', 'g-${depth + 1}', branch: depth < 4),
      ];
    }
    repo.tree['g-4'] = [
      const GoodsBomItem(
        id: 'node-5',
        componentGoodsId: 'g-5',
        componentName: 'DeepComponent1234',
        qty: 1,
      ),
    ];
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('goods-bom-tree-expansion')));
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(
      find
          .descendant(
            of: find.byKey(const ValueKey('goods-bom-tree-cell-node-5')),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl展开根层兄弟仅加载一层，共享组件只读一次', (tester) async {
    final repo = _TreeRepo();
    await _pump(tester, repo);
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'));
    expect(_row('root/root-a/a-x'), findsOneWidget);
    expect(_row('root/root-b/b-x'), findsOneWidget);
    expect(_row('root/root-c/a-x'), findsOneWidget);
    expect(repo.count('assembly-a'), 1);
    expect(repo.count('assembly-b'), 1);
    expect(repo.count('shared-x'), 0, reason: 'Ctrl不递归请求孙层');
    expect(repo.count('deep-leaf'), 0);
    final calls = repo.calls.length;
    await _ctrlTap(tester, _toggle('root/root-b', 'root-b'));
    expect(_row('root/root-a/a-x'), findsOneWidget, reason: '已展开兄弟不被收起');
    expect(repo.calls, hasLength(calls));
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl内层限定occurrence父路径，刷新后也不展开其他父树alias', (tester) async {
    final repo = _TreeRepo();
    await _pump(tester, repo);
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'));
    await _ctrlTap(tester, _toggle('root/root-a/a-x', 'a-x'));
    expect(_row('root/root-a/a-x/shared-leaf'), findsOneWidget);
    expect(_row('root/root-a/a-y/y-leaf'), findsOneWidget);
    expect(_row('root/root-b/b-x/shared-leaf'), findsNothing);
    expect(_row('root/root-c/a-x/shared-leaf'), findsNothing);
    expect(repo.count('shared-x'), 1);
    expect(repo.count('part-y'), 1);
    expect(repo.count('part-z'), 0);
    expect(repo.count('deep-leaf'), 0);
    final refreshing = tester
        .state<GoodsBomTabState>(find.byType(GoodsBomTab))
        .refresh();
    await tester.pumpAndSettle();
    await refreshing;
    expect(_row('root/root-a/a-x/shared-leaf'), findsOneWidget);
    expect(_row('root/root-b/b-x/shared-leaf'), findsNothing);
    expect(_row('root/root-c/a-x/shared-leaf'), findsNothing);
    expect(repo.count('assembly-a'), 2, reason: '显式刷新取得新快照，别名共用本次读取');
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享组件普通展开并发去重，完成后其他alias复用同代快照', (tester) async {
    final repo = _TreeRepo();
    final pending = Completer<List<GoodsBomItem>>();
    repo.pending['assembly-a'] = pending;
    await _pump(tester, repo);
    await tester.tap(_toggle('root/root-a', 'root-a'));
    await tester.pump();
    await tester.tap(_toggle('root/root-c', 'root-c'));
    await tester.pump();
    expect(repo.count('assembly-a'), 1);
    pending.complete(repo.tree['assembly-a']!);
    await tester.pumpAndSettle();
    expect(_row('root/root-a/a-x'), findsOneWidget);
    expect(_row('root/root-c/a-x'), findsOneWidget);
    final count = repo.calls.length;
    await tester.tap(_toggle('root/root-c', 'root-c'));
    await tester.pumpAndSettle();
    await tester.tap(_toggle('root/root-c', 'root-c'));
    await tester.pumpAndSettle();
    expect(repo.calls, hasLength(count));
    expect(tester.takeException(), isNull);
  });

  testWidgets('慢Ctrl重复点击不重复请求，编辑原始输入和控制器保全', (tester) async {
    final repo = _TreeRepo();
    final api = await _pump(tester, repo, editing: true);
    final activateQty = find.byKey(
      const ValueKey('goods-bom-activate-qty-root/root-a'),
    );
    await tester.ensureVisible(activateQty);
    await tester.tap(activateQty);
    await tester.pumpAndSettle();
    final qty = find.byKey(const ValueKey('goods-bom-inline-qty-root/root-a'));
    await tester.enterText(qty, '1.23000');
    final controller = tester.widget<TextField>(qty).controller;
    final a = Completer<List<GoodsBomItem>>();
    final b = Completer<List<GoodsBomItem>>();
    repo.pending['assembly-a'] = a;
    repo.pending['assembly-b'] = b;
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'), settle: false);
    await tester.pump();
    await _ctrlTap(tester, _toggle('root/root-b', 'root-b'), settle: false);
    expect(repo.count('assembly-a'), 1);
    expect(repo.count('assembly-b'), 1);
    expect(
      await tester
          .state<GoodsBomTabState>(find.byType(GoodsBomTab))
          .finishEditing(),
      isFalse,
    );
    a.complete(repo.tree['assembly-a']!);
    b.complete(repo.tree['assembly-b']!);
    await tester.pumpAndSettle();
    expect(_row('root/root-c/a-x'), findsOneWidget);
    expect(tester.widget<TextField>(qty).controller, same(controller));
    expect(controller?.text, '1.23000');
    expect(api.previewCalls, 0);
    expect(api.commitCalls, 0);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部展开收起反复操作零额外读取，显式刷新仍读新快照', (tester) async {
    final repo = _TreeRepo();
    await _pump(tester, repo);
    final button = find.byKey(const Key('goods-bom-tree-expansion'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    final reads = repo.calls.length;
    final learning = repo.learningCalls;
    expect(repo.calls.toSet(), hasLength(reads), reason: '首轮每个真实父件只读一次');
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(_row('root/root-a/a-x'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('全部收起'), findsOneWidget);
      expect(repo.calls, hasLength(reads));
      expect(repo.learningCalls, learning, reason: '显示切换不重查学习业务数据');
    }
    final refreshing = tester
        .state<GoodsBomTabState>(find.byType(GoodsBomTab))
        .refresh();
    await tester.pumpAndSettle();
    await refreshing;
    expect(repo.count('root'), 2);
    expect(repo.calls.length, reads * 2);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl十二个兄弟读取并发有界四个', (tester) async {
    final repo = _TreeRepo()..delayReads = true;
    repo.tree['root'] = [
      for (var index = 0; index < 12; index++)
        _item('row-$index', 'goods-$index'),
    ];
    for (var index = 0; index < 12; index++) {
      repo.tree['goods-$index'] = [
        _item('child-$index', 'leaf-$index', branch: false),
      ];
    }
    await _pump(tester, repo);
    await _ctrlTap(tester, _toggle('root/row-0', 'row-0'));
    expect(repo.peak, lessThanOrEqualTo(4));
    for (var index = 0; index < 12; index++) {
      expect(repo.count('goods-$index'), 1);
    }
    expect(_row('root/row-0/child-0'), findsOneWidget);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl一支失败立即退busy，不等待挂起兄弟，重试合并原挂起请求', (tester) async {
    final repo = _TreeRepo();
    final pending = Completer<List<GoodsBomItem>>();
    repo.pending['assembly-b'] = pending;
    repo.failOnce.add('assembly-a');
    await _pump(tester, repo);
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'));
    expect(pending.isCompleted, isFalse);
    expect(_row('root/root-a/a-x'), findsNothing);
    expect(
      tester.widget<IconButton>(_toggle('root/root-a', 'root-a')).onPressed,
      isNotNull,
      reason: '一个兄弟失败后不等待另一个慢响应就恢复重试入口',
    );
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'), settle: false);
    await tester.pump();
    expect(repo.count('assembly-a'), 2);
    expect(repo.count('assembly-b'), 1, reason: '重试共享仍进行中的真实GET');
    pending.complete(repo.tree['assembly-b']!);
    await tester.pumpAndSettle();
    expect(_row('root/root-a/a-x'), findsOneWidget);
    expect(_row('root/root-b/b-x'), findsOneWidget);
    expect(_row('root/root-c/a-x'), findsOneWidget);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('2倍字体深树窄列激活名称及清除按钮无溢出: $platform', (tester) async {
      final repo = _TreeRepo();
      repo.tree['root'] = [_item('node-0', 'g-0')];
      for (var depth = 0; depth < 5; depth++) {
        repo.tree['g-$depth'] = [
          _item('node-${depth + 1}', 'g-${depth + 1}', branch: depth < 4),
        ];
      }
      final api = await _pump(
        tester,
        repo,
        platform: platform,
        fontScale: 2,
        size: const Size(1000, 1000),
      );
      await tester.tap(find.byKey(const Key('goods-bom-tree-expansion')));
      await tester.pumpAndSettle();
      Finder header() {
        final containers = find.ancestor(
          of: find.text('组件名称'),
          matching: find.byType(Container),
        );
        for (final element in containers.evaluate()) {
          final container = element.widget as Container;
          final constraints = container.constraints;
          if (constraints != null &&
              constraints.maxWidth.isFinite &&
              constraints.minWidth == constraints.maxWidth) {
            return find.byWidget(container);
          }
        }
        throw TestFailure('组件名称表头缺失');
      }

      Future<void> narrow() async {
        final grip = find.descendant(
          of: header(),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is GestureDetector &&
                widget.onHorizontalDragUpdate != null &&
                widget.onHorizontalDragStart == null &&
                widget.behavior == HitTestBehavior.opaque,
          ),
        );
        await tester.ensureVisible(grip);
        await tester.dragFrom(
          tester.getCenter(grip) - const Offset(2, 0),
          const Offset(-1000, 0),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await narrow();
      const path = 'root/node-0/node-1/node-2/node-3/node-4/node-5';
      final deepest = find.byKey(const ValueKey('goods-bom-tree-cell-node-5'));
      expect(deepest, findsOneWidget);
      final viewWidth = tester.getSize(header()).width;
      await enterBomEdit(tester);
      await narrow();
      expect(tester.getSize(header()).width, greaterThan(viewWidth));
      final activateName = find.byKey(
        const ValueKey('goods-bom-activate-name-$path'),
      );
      await tester.ensureVisible(activateName);
      await tester.tap(activateName);
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: deepest,
        matching: find.byType(TextField),
      );
      await tester.enterText(name, '尚未选择的组件名称');
      await tester.pumpAndSettle();
      final clear = find.descendant(
        of: deepest,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              (widget.tooltip?.startsWith('清除') ?? false),
        ),
      );
      expect(clear, findsOneWidget);
      for (final button
          in find
              .descendant(of: deepest, matching: find.byType(IconButton))
              .evaluate()) {
        final bounds = tester.getRect(
          find.byElementPredicate((element) => identical(element, button)),
        );
        expect(
          bounds.right,
          lessThanOrEqualTo(tester.getRect(deepest).right + 1),
        );
      }
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller?.text, isEmpty);
      expect(api.previewCalls, 0);
      expect(api.commitCalls, 0);
      expect(repo.writes, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小窗大字展开两千行保留完整模型和编辑内容，仅挂载可见窗口', (tester) async {
    final repo = _TreeRepo();
    repo.tree['root'] = [_item('root-a', 'assembly-a')];
    repo.tree['assembly-a'] = [
      for (var index = 0; index < 2000; index++)
        _item('leaf-$index', 'leaf-$index', branch: false),
    ];
    await _pump(
      tester,
      repo,
      editing: true,
      size: const Size(1100, 700),
      fontScale: 1.6,
    );
    final activateQty = find.byKey(
      const ValueKey('goods-bom-activate-qty-root/root-a'),
    );
    await tester.ensureVisible(activateQty);
    await tester.tap(activateQty);
    await tester.pumpAndSettle();
    final qty = find.byKey(const ValueKey('goods-bom-inline-qty-root/root-a'));
    await tester.enterText(qty, '2.50000');
    await _ctrlTap(tester, _toggle('root/root-a', 'root-a'));
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('goods-bom-table-true-false')),
    );
    expect(table.items, hasLength(2001), reason: '让帧和虚拟化不截断业务模型');
    expect(find.byType(UtenTreeTableCell).evaluate().length, lessThan(300));
    expect(tester.widget<TextField>(qty).controller?.text, '2.50000');
    final bounds = tester.getRect(_row('root/root-a'));
    expect(tester.getRect(qty).top, greaterThanOrEqualTo(bounds.top));
    expect(tester.getRect(qty).bottom, lessThanOrEqualTo(bounds.bottom));
    expect(repo.count('assembly-a'), 1);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
  });
}
