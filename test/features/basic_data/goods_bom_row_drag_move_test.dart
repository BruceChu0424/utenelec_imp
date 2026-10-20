// 组装信息「长按拖拽移动」（2026-10-19）：单行同层换位 + 移入子级 + 批量。
//
// 钉住四件容易回归的事：
//  1. 长按行拖到另一行下缘 → 同层下移（move 的 targetParent = 目标行的父件、
//     afterAnchor 锚定目标行）；
//  2. 长按行拖到目标行中部 → 移入其子级（targetParent = 目标组件货品、无锚点
//     追加），且移动后该层级自动展开（_expandedIds 记住）；
//  3. 多选两行后长按其中一行 → 整批一起移动（below 逆序提交保序）；
//  4. 只读账号（canEdit=false）不挂拖拽——长按不产生任何 move 调用。
//
// 网络段是 UtenBusyOverlay（CircularProgressIndicator 无限动画），移动后只能
// 定量 pump。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 伪仓库：move 真的换行序/换父件，才能验出移动后的展开与勾选保持。
class _FakeBomRepo implements GoodsBomRepository {
  final Map<String, List<GoodsBomItem>> _tree = {
    'goods-a': [
      const GoodsBomItem(
        id: 'row-a1',
        componentGoodsId: 'goods-x',
        componentCode: 'K01',
        componentName: '外壳',
        qty: 1,
      ),
      const GoodsBomItem(
        id: 'row-a2',
        componentGoodsId: 'goods-y',
        componentCode: 'S01',
        componentName: '螺丝',
        hasChildren: true,
        qty: 4,
      ),
      const GoodsBomItem(
        id: 'row-a3',
        componentGoodsId: 'goods-w',
        componentCode: 'W01',
        componentName: '线材',
        qty: 2,
      ),
    ],
    'goods-y': [
      const GoodsBomItem(
        id: 'row-y1',
        componentGoodsId: 'goods-z',
        componentCode: 'D01',
        componentName: '垫片',
        qty: 2,
      ),
    ],
  };

  /// move 调用记录：(根货品, 每条 move)。
  final moveCalls = <(String, List<GoodsBomMove>)>[];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async =>
      List<GoodsBomItem>.of(_tree[goodsId] ?? const <GoodsBomItem>[]);

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async {
    moveCalls.add((goodsId, List<GoodsBomMove>.of(moves)));
    for (final m in moves) {
      _apply(goodsId, m);
    }
    return moves.length;
  }

  /// 与服务端同语义：换父件 + 锚点前后插入 + 整层重排。
  void _apply(String rootGoodsId, GoodsBomMove m) {
    GoodsBomItem? row;
    for (final rows in _tree.values) {
      for (final r in rows) {
        if (r.id == m.itemId) row = r;
      }
    }
    if (row == null) return;
    for (final rows in _tree.values) {
      rows.removeWhere((r) => r.id == m.itemId);
    }
    final siblings = _tree.putIfAbsent(m.targetParentGoodsId, () => []);
    var index = siblings.length;
    if (m.anchorItemId != null) {
      final at = siblings.indexWhere((r) => r.id == m.anchorItemId);
      if (at >= 0) index = m.afterAnchor ? at + 1 : at;
    }
    siblings.insert(index, row);
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async =>
      throw UnimplementedError();

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async => throw UnimplementedError();

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async => throw UnimplementedError();

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async => throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async => throw UnimplementedError();
}

Future<void> _pumpTab(
  WidgetTester tester,
  _FakeBomRepo repo, {
  bool canEdit = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: true,
            canEdit: canEdit,
            canDelete: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 长按拾起一行（按住 600ms）并保持手势。
Future<TestGesture> _pickUp(
  WidgetTester tester,
  Finder rowText, {
  int pointer = 7,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(rowText),
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
  return gesture;
}

Future<void> _dropAt(WidgetTester tester, TestGesture gesture, String rowKey,
    double band) async {
  final rect = tester.getRect(find.byKey(ValueKey(rowKey)));
  await gesture.moveTo(Offset(rect.center.dx, rect.top + rect.height * band));
  await tester.pumpAndSettle();
  await gesture.up();
  // 网络段遮罩是无限动画，定量 pump。
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('长按拖到另一行下缘 = 同层下移（锚定目标行 after）', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);

    final gesture = await _pickUp(tester, find.text('外壳'));
    await _dropAt(tester, gesture, 'row-drag-slot:goods-a/row-a3', 0.9);

    expect(repo.moveCalls, hasLength(1));
    final (root, moves) = repo.moveCalls.single;
    expect(root, 'goods-a');
    expect(moves, hasLength(1));
    expect(moves.single.itemId, 'row-a1');
    expect(moves.single.targetParentGoodsId, 'goods-a');
    expect(moves.single.anchorItemId, 'row-a3');
    expect(moves.single.afterAnchor, isTrue);
    // 伪仓库同语义应用后顺序变为：螺丝、线材、外壳。
    expect(
      repo._tree['goods-a']!.map((r) => r.id).toList(),
      ['row-a2', 'row-a3', 'row-a1'],
    );
  });

  testWidgets('拖到行中部 = 移入其子级，且移动后目标层级自动展开', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);

    final gesture = await _pickUp(tester, find.text('线材'));
    await _dropAt(tester, gesture, 'row-drag-slot:goods-a/row-a2', 0.5);

    expect(repo.moveCalls, hasLength(1));
    final moves = repo.moveCalls.single.$2;
    expect(moves.single.itemId, 'row-a3');
    expect(moves.single.targetParentGoodsId, 'goods-y'); // 螺丝之下
    expect(moves.single.anchorItemId, isNull);
    expect(moves.single.afterAnchor, isFalse);
    // 移入后「螺丝」自动展开：子级（垫片 + 线材）可见。
    await tester.pumpAndSettle();
    expect(find.text('垫片'), findsOneWidget);
    expect(find.text('线材'), findsOneWidget);
  });

  testWidgets('多选两行后长按 = 整批移动（below 逆序提交保序）', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);

    await tester.tap(find.text('外壳'));
    await tester.pump();
    await tester.tap(find.text('螺丝'));
    await tester.pump();

    final gesture = await _pickUp(tester, find.text('螺丝'));
    await _dropAt(tester, gesture, 'row-drag-slot:goods-a/row-a3', 0.9);

    expect(repo.moveCalls, hasLength(1));
    final moves = repo.moveCalls.single.$2;
    expect(moves, hasLength(2));
    // below：逆序提交，服务端逐条「插到参照后」恰好正序落位。
    expect(moves.map((m) => m.itemId).toList(), ['row-a2', 'row-a1']);
    expect(
      moves.every(
        (m) =>
            m.targetParentGoodsId == 'goods-a' &&
            m.anchorItemId == 'row-a3' &&
            m.afterAnchor,
      ),
      isTrue,
    );
    expect(
      repo._tree['goods-a']!.map((r) => r.id).toList(),
      ['row-a3', 'row-a1', 'row-a2'],
    );
  });

  testWidgets('只读账号不挂拖拽：长按不产生 move', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo, canEdit: false);

    final gesture = await _pickUp(tester, find.text('外壳'));
    // 只读态不挂拖拽配置：无拖拽槽可寻，直接对着目标行文本移动松手。
    final rect = tester.getRect(find.text('线材'));
    await gesture.moveTo(rect.center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(repo.moveCalls, isEmpty);
  });
}
