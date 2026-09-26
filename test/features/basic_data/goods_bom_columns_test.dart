import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
// 组装信息表格列口径（2026-09-25 用户口径「表格显示啥导出啥」）：
//
//  1. 需求阶段 / 缺料处理 / 单价 / 金额 四列从展示退役——数据仍在行上
//     （编辑弹窗/复制粘贴/成本聚合不受影响），只是不再占表格列；
//  2. 「已审」列只在审计模式出现，关闭审计模式就是普通清单视图
//     （绿色行高亮同进退）。
//
// 复用 goods_bom_multi_select_delete_test 的伪仓库树。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _FakeBomRepo implements GoodsBomRepository {
  final Map<String, List<GoodsBomItem>> _tree = {
    'goods-a': [
      const GoodsBomItem(
        id: 'row-a1',
        componentGoodsId: 'goods-x',
        componentCode: 'K01',
        componentName: '外壳',
        qty: 1,
        price: 12.5,
        total: 12.5,
      ),
    ],
  };

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async =>
      List<GoodsBomItem>.of(_tree[goodsId] ?? const <GoodsBomItem>[]);

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
  ) async {
    batchCalls.add((itemId, audited));
    // 真翻状态（模型不可变，就位替换一份带 auditedAt 的拷贝），重载后图标才变。
    final rows = _tree[goodsId]!;
    final index = rows.indexWhere((r) => r.id == itemId);
    final old = rows[index];
    final marked = GoodsBomItem(
      id: old.id,
      componentGoodsId: old.componentGoodsId,
      componentCode: old.componentCode,
      componentName: old.componentName,
      qty: old.qty,
      auditedAt: audited ? DateTime(2026, 9, 25) : null,
    );
    rows[index] = marked;
    return marked;
  }

  /// 审计标记调用记录：(关系行 id, 目标状态)。
  final batchCalls = <(String, bool)>[];
}

Future<void> _pumpTab(
  WidgetTester tester,
  _FakeBomRepo repo, {
  Set<String> permissions = const <String>{},
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
}

void main() {
  testWidgets('需求阶段/缺料处理/单价/金额四列不再展示', (tester) async {
    await _pumpTab(tester, _FakeBomRepo());

    expect(find.text('外壳'), findsOneWidget);
    for (final label in ['需求阶段', '缺料处理', '单价', '金额']) {
      expect(find.text(label), findsNothing, reason: '「$label」列应已退役');
    }
    // 保留列还在（表头按 label 找）。
    for (final label in ['编号', '规格', '单位', '颜色', '来源', '计量方式', '数量']) {
      expect(find.text(label), findsOneWidget, reason: '「$label」列应保留');
    }
  });

  testWidgets('审计模式下点已审格翻状态（空心圆→实心对勾）', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo, permissions: {Perm.goodsBomAudit});

    await tester.tap(find.text('审计模式'));
    await tester.pumpAndSettle();

    // 未核对行显示空心圆；点它 = 标记已核对。
    final unmarked = find.byIcon(Icons.radio_button_unchecked);
    expect(unmarked, findsOneWidget);
    await tester.tap(unmarked);
    await tester.pumpAndSettle();

    expect(repo.batchCalls, hasLength(1));
    expect(repo.batchCalls.single.$2, isTrue, reason: '第一次点击应标记为已核对');
    // 翻面后同一格变实心圆对勾。
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('已审列只在审计模式出现，退出即恢复普通清单', (tester) async {
    await _pumpTab(tester, _FakeBomRepo(), permissions: {Perm.goodsBomAudit});

    // 普通模式：没有已审列。
    expect(find.text('已审'), findsNothing);

    await tester.tap(find.text('审计模式'));
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsOneWidget, reason: '审计模式应显示已审列');
    expect(find.text('退出审计'), findsOneWidget);

    await tester.tap(find.text('退出审计'));
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsNothing, reason: '退出审计模式后已审列应消失');
  });
}
