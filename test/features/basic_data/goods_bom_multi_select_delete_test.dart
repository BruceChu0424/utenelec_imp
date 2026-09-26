import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
// 组装信息页签的多选批量删除(2026-09-21 用户口径「组件信息最前面加个多选框，
// 然后可以多选，批量删除」)。
//
// 钉住五件容易回归的事：
//  1. 勾两行后「删除」可用、「编辑」反而要灰掉(目标不唯一)，确认框列出两个组件名；
//  2. 勾到子级行时确认框必须出跨层级警告(删的是那个子件自己的组装清单)；
//  3. 审计模式下勾选框照常在（2026-09-25 起审计模式也要能多选批量删除，
//     「标记已核对」改走右键菜单），退出审计清空勾选不留残留；
//  4. 折叠父级后子级行的勾选被剪掉——看到的勾选 = 提交的内容；
//  5. 勾选横跨多层时按所属父货品分组提交，删完的行自动退出勾选。
//
// 删除确认之后只能**定量 pump**：批量删除的遮罩 UtenBusyOverlay 里是
// CircularProgressIndicator(无限动画)，pumpAndSettle 会死循环。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 伪仓库：批量删除**真的**把行从树里移除，否则验不出「删完勾选自动退出」。
///
/// 树：goods-a → 外壳 / 螺丝(螺丝自己还有下级)；goods-y(螺丝本体)→ 垫片。
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

  /// 批量删除调用记录：(父货品 id, 本次提交的关系行 id)。
  final batchCalls = <(String, List<String>)>[];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async =>
      List<GoodsBomItem>.of(_tree[goodsId] ?? const <GoodsBomItem>[]);

  /// ADR-111：一次请求可横跨组装树多层，服务端按本货品的树核对，这里按行 id 在整棵树里删。
  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async {
    batchCalls.add((goodsId, List<String>.of(itemIds)));
    var removed = 0;
    for (final rows in _tree.values) {
      final before = rows.length;
      rows.removeWhere((r) => itemIds.contains(r.id));
      removed += before - rows.length;
    }
    return removed;
  }

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
  ) async => _tree[goodsId]!.firstWhere((r) => r.id == itemId);
}

Future<void> _pumpTab(
  WidgetTester tester,
  _FakeBomRepo repo, {
  Set<String> permissions = const <String>{},
  bool canCreate = true,
  bool canEdit = true,
  bool canDelete = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: canCreate,
            canEdit: canEdit,
            canDelete: canDelete,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _deleteFinder = find.byKey(const Key('goods-bom-delete-selected'));
final _toggleScrew = find.byKey(const ValueKey('goods-bom-tree-toggle-row-a2'));

UtenButton _deleteButton(WidgetTester tester) =>
    tester.widget<UtenButton>(_deleteFinder);

UtenButton _editButton(WidgetTester tester) =>
    tester.widget<UtenButton>(find.widgetWithText(UtenButton, '编辑'));

/// 点「螺丝」行的展开箭头(展开或收起)。
///
/// 故意不调 ensureVisible：表体是被横向裁剪的内层视口, 而勾选列是钉在左边的,
/// ensureVisible 会把箭头一路滚到 x=0 也就是钉住列的底下(裁剪区外), 之后 tap 只
/// 会命中空白, 表现为「点了没反应」。1600 宽的测试画布里箭头本来就在视口内,
/// 不需要滚。
Future<void> _tapScrewToggle(WidgetTester tester) async {
  await tester.tap(_toggleScrew);
  await tester.pumpAndSettle();
}

/// 展开「螺丝」，让它的子级行(垫片)出现在表里。
Future<void> _expandScrew(WidgetTester tester) => _tapScrewToggle(tester);

void main() {
  testWidgets('勾两行后删除可用，确认框列出两个组件名', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);

    // 首列勾选框由统一表格自己渲染(表头三态 + 每行一个)。
    expect(find.byType(Checkbox), findsWidgets);
    expect(_deleteButton(tester).onPressed, isNull, reason: '没勾行时删除必须灰着');

    await tester.tap(find.text('外壳'));
    await tester.pump();
    await tester.tap(find.text('螺丝'));
    await tester.pump();

    expect(_deleteButton(tester).onPressed, isNotNull);
    // 勾了两条，「编辑」的目标不唯一 —— 宁可灰掉也不替用户猜。
    expect(_editButton(tester).onPressed, isNull);

    await tester.tap(_deleteFinder);
    await tester.pumpAndSettle();

    expect(find.text('删除 2 个组件'), findsOneWidget);
    expect(find.textContaining('确定把下面 2 个组件'), findsOneWidget);
    // 确认框里两个组件名都在(一行一条：级联号 + 名称 + 编号)。
    expect(find.textContaining('1 外壳 K01'), findsOneWidget);
    expect(find.textContaining('2 螺丝 S01'), findsOneWidget);
    // 两条都直接挂在本货品下，不该出跨层级警告。
    expect(find.textContaining('不是直接装在本货品上的'), findsNothing);
  });

  testWidgets('勾到子级行时确认框给出跨层级警告', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);
    await _expandScrew(tester);
    expect(find.text('垫片'), findsOneWidget);

    await tester.tap(find.text('垫片'));
    await tester.pump();
    await tester.tap(_deleteFinder);
    await tester.pumpAndSettle();

    // 删子级行改的是「螺丝」自己的组装清单，用到螺丝的其它货品都会跟着变 ——
    // 这是真实踩过的坑，文案必须让人看懂，所以这里按人话原文钉住。
    expect(find.textContaining('不是直接装在本货品上的'), findsOneWidget);
    expect(find.textContaining('凡是用到该子件的货品'), findsOneWidget);
    // 光报「有 1 个不是直接装在本货品上」还不够：得点出挂在谁下面，否则用户
    // 看不出自己动的是哪个共用子件的清单，而那正是这条警告要拦的误删。
    expect(find.textContaining('挂在「螺丝」下'), findsOneWidget);
  });

  testWidgets('三个动作都没权限时不给勾选框', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(
      tester,
      repo,
      canCreate: false,
      canEdit: false,
      canDelete: false,
    );

    // 勾选框是给「批量删除 / 编辑 / 添加组件定位」用的，三个都没权限时它什么也
    // 接不上 —— 按准则「隐藏而非禁用」整列不渲染，而不是让人勾完无处可去。
    expect(find.byType(Checkbox), findsNothing);
    expect(_deleteFinder, findsNothing);
    // 2026-09-25 起工具条下的说明行（共 X 个顶层组件…）已整体退役。
    expect(find.textContaining('顶层组件'), findsNothing);
  });

  testWidgets('审计模式下仍可多选批量删除，退出审计清空勾选', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo, permissions: {Perm.goodsBomAudit});

    await tester.tap(find.text('外壳'));
    await tester.pump();
    expect(_deleteButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('审计模式'));
    await tester.pumpAndSettle();
    expect(find.text('退出审计'), findsOneWidget);
    // 2026-09-25 起：审计模式下勾选框照常在（多选批量删除可用），
    // 「标记已核对」改由右键菜单触发，单击行不再兼任审计开关。
    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('已审'), findsOneWidget);
    // 进审计不清勾选：已勾的行在审计模式下照样能删。
    expect(_deleteButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('退出审计'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsWidgets);
    // 退出审计清空勾选：避免带着勾选进普通编辑流。
    expect(_deleteButton(tester).onPressed, isNull);
  });

  testWidgets('折叠父级把子级行的勾选剪掉', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);
    await _expandScrew(tester);

    await tester.tap(find.text('垫片'));
    await tester.pump();
    expect(_deleteButton(tester).onPressed, isNotNull);

    // 折叠后子级行从表里消失，勾选跟着剪掉 —— 否则「已选 1 项」数得对、
    // 用户一条也看不见，点删除就会删掉屏幕上根本没有的行。
    await _tapScrewToggle(tester);
    expect(find.text('垫片'), findsNothing);
    expect(_deleteButton(tester).onPressed, isNull);
  });

  testWidgets('跨层级勾选一次请求提交(服务端按组装树核对)，删完勾选自动退出', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);
    await _expandScrew(tester);

    await tester.tap(find.text('外壳')); // 挂在 goods-a 下
    await tester.pump();
    await tester.tap(find.text('垫片')); // 挂在 goods-y(螺丝本体)下
    await tester.pump();

    await tester.tap(_deleteFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
    // 确认之后遮罩可能在屏，只能定量 pump(见文件头)。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // ADR-111：不再按父货品分组逐组提交(两组两个事务，删一半的可能)，
    // 一次请求、一个事务，挂在本货品组装树里的行一起删。
    expect(repo.batchCalls.length, 1, reason: '跨层级也只发一次请求');
    expect(repo.batchCalls.single.$1, 'goods-a');
    expect(repo.batchCalls.single.$2, unorderedEquals(['row-a1', 'row-y1']));
    // 删掉的行不在树里了，重载后勾选被剪空，删除按钮回灰。
    expect(find.text('外壳'), findsNothing);
    expect(_deleteButton(tester).onPressed, isNull);
  });
}
