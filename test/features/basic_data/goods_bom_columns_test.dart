import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
// 组装信息表格列口径（2026-09-25 用户口径「表格显示啥导出啥」）：
//
//  1. 需求阶段 / 缺料处理 / 单价 / 金额 四列从展示退役——数据仍在行上
//     （编辑弹窗/复制粘贴/成本聚合不受影响），只是不再占表格列；
//  2. 「已审」列只在审计模式出现，关闭审计模式就是普通清单视图
//     (绿色行高亮同进退)；
//  3. ADR-129：「数量」改名「设计使用数量」，其后只读「真实使用数量」
//     (没有数据显示「—」，悬停说明原因)；系统学出的组件带「系统学习」标记，
//     标记按文字实测留位，韩文也不被截断；在「BOM 学习记录」里重学后本页签
//     跟着重读。
//
// 复用 goods_bom_multi_select_delete_test 的伪仓库树。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _FakeBomRepo implements GoodsBomRepository {
  _FakeBomRepo({this.withLearned = false});

  /// 额外挂一个系统学出的组件(真实使用数量用例用)。
  final bool withLearned;

  late final Map<String, List<GoodsBomItem>> _tree = {
    'goods-a': [
      const GoodsBomItem(
        id: 'row-a1',
        componentGoodsId: 'goods-x',
        componentCode: 'K01',
        componentName: '外壳',
        qty: 1,
        price: 12.5,
        total: 12.5,
        actual: BomActualUsage(status: BomActualStatus.noData),
      ),
      // 系统学出的组件：真实使用数量有 3 批数据，计算按真实值。
      if (withLearned)
        const GoodsBomItem(
          id: 'row-a2',
          componentGoodsId: 'goods-p',
          componentCode: 'P01',
          componentName: '塑料',
          componentUnitName: '千克',
          qty: 0.1,
          systemLearned: true,
          actual: BomActualUsage(
            qty: 0.105,
            perUnitQty: 0.105,
            status: BomActualStatus.actual,
            usesActual: true,
            netQty: 42,
            outputQty: 400,
            sampleCount: 3,
            // 日报另登记 20 个不良：实产 420，只作说明。
            defectQty: 20,
            perProducedQty: 0.1,
            defectRate: 0.047619,
          ),
        ),
      // 按包装(每 20 件一包，允许尾包)：格里是每包用量，累计是每件口径。
      if (withLearned)
        const GoodsBomItem(
          id: 'row-a3',
          componentGoodsId: 'goods-c',
          componentCode: 'C01',
          componentName: '纸箱',
          componentUnitName: '个',
          qty: 2.2,
          consumptionBasis: BomConsumptionBasis.perPackage,
          basisOutputQty: 20,
          actual: BomActualUsage(
            qty: 2,
            perUnitQty: 0.1,
            status: BomActualStatus.actual,
            usesActual: true,
            netQty: 100,
            outputQty: 1000,
            sampleCount: 2,
          ),
        ),
    ],
  };

  /// 在学习记录里重学过的组件：之后再读组装信息，它没有真实值了。
  final relearned = <String>{};
  var listCalls = 0;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls++;
    return [
      for (final row in _tree[goodsId] ?? const <GoodsBomItem>[])
        relearned.contains(row.componentGoodsId)
            ? GoodsBomItem(
                id: row.id,
                componentGoodsId: row.componentGoodsId,
                componentCode: row.componentCode,
                componentName: row.componentName,
                componentUnitName: row.componentUnitName,
                qty: row.qty,
                systemLearned: row.systemLearned,
                actual: const BomActualUsage(status: BomActualStatus.noData),
              )
            : row,
    ];
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

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      _learningSummary();

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async {
    relearned.add(componentGoodsId);
    return _learningSummary();
  }

  /// 按服务端 JSON 契约给出塑料的学习记录(重学后没有真实值)。
  GoodsBomLearningSummary _learningSummary() {
    final reset = relearned.contains('goods-p');
    return GoodsBomLearningSummary.fromJson({
      'canRelearn': true,
      'profile': {
        'totalOutputQty': 400,
        'sampleCount': 3,
        'outputUnitName': '个',
      },
      'components': [
        {
          'componentGoodsId': 'goods-p',
          'componentCode': 'P01',
          'componentName': '塑料',
          'unitName': '千克',
          'inBom': true,
          'bomItemId': 'row-a2',
          'systemLearned': true,
          'released': false,
          'designQty': 0.1,
          'actualQty': reset ? null : 0.105,
          'actualPerUnitQty': reset ? null : 0.105,
          'actualStatus': reset ? 'NO_DATA' : 'ACTUAL',
          'usageBasis': reset ? 'DESIGN' : 'ACTUAL',
          'actualNetQty': reset ? 0 : 42,
          'actualOutputQty': reset ? 0 : 400,
          'actualSampleCount': reset ? 0 : 3,
          'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
          'relearnedAt': reset ? '2026-09-27T09:00:00+08:00' : null,
        },
      ],
    });
  }
}

Future<void> _pumpTab(
  WidgetTester tester,
  _FakeBomRepo repo, {
  Set<String> permissions = const <String>{},
  Locale locale = const Locale('zh'),
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
        locale: locale,
        home: const Scaffold(
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
    // 保留列还在（表头按 label 找）——「单位」列 2026-10-10 起并入数量列内联。
    for (final label in [
      '编号',
      '规格',
      '颜色',
      '来源',
      '计量方式',
      '设计使用数量',
      '真实使用数量',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '「$label」列应保留');
    }
    expect(find.text('数量'), findsNothing, reason: '「数量」已改名「设计使用数量」');
  });

  testWidgets('真实使用数量只读展示：没有数据显示「—」并悬停说明，学习组件带标记', (tester) async {
    await _pumpTab(tester, _FakeBomRepo(withLearned: true));

    // 外壳：没有学习数据 → 「—」，悬停说明计算按设计使用数量。
    expect(find.text('—'), findsWidgets);
    expect(find.byTooltip('还没有已完工且核清余料的生产数据，计算按设计使用数量'), findsOneWidget);
    // 塑料：设计 0.1，真实 0.105(固定 6 位去尾零，无浮点噪声)，单位内联
    // (2026-10-10「数量+单位」口径)；悬停给出依据；
    // 登记过不良时补一句按实产(良品+不良)算的用量和不良率。
    expect(find.text('0.1 千克'), findsOneWidget);
    expect(find.text('0.105 千克'), findsOneWidget);
    expect(
      find.byTooltip(
        '按 3 批已完工生产累计：净耗 42 千克 / 产量 400\n'
        '另有不良 20：按实产(良品+不良)算用量为 0.1 千克，不良率 4.76%\n'
        '物料分析和车间领料按真实使用数量计算',
      ),
      findsOneWidget,
    );
    // 纸箱按包装：格里是每包 2，悬停补每件平均，和累计净耗/产量对得上。
    expect(
      find.byTooltip(
        '按 2 批已完工生产累计：净耗 100 个 / 产量 1000\n'
        '物料分析和车间领料按真实使用数量计算\n'
        '实际平均每件用 0.1 个',
      ),
      findsOneWidget,
    );
    // 学习组件只在自己那一行带「系统学习」标记。
    expect(
      find.byKey(const ValueKey('goods-bom-learned-row-a2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('goods-bom-learned-row-a1')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('「系统学习」标记按文字实测留位，韩文不被截成省略号', (tester) async {
    await _pumpTab(
      tester,
      _FakeBomRepo(withLearned: true),
      locale: const Locale('ko'),
    );

    final label = find.descendant(
      of: find.byKey(const ValueKey('goods-bom-learned-row-a2')),
      matching: find.text('시스템 학습'),
    );
    expect(label, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: label, matching: find.byType(RichText)),
    );
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '槽宽写死 72 时韩文标记会显示成「시스템 학…」',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('在学习记录里重学后，组装信息页签跟着重读真实使用数量', (tester) async {
    final repo = _FakeBomRepo(withLearned: true);
    await _pumpTab(tester, repo);
    expect(find.text('0.105 千克'), findsOneWidget);
    expect(repo.listCalls, 1);

    await tester.tap(find.byKey(const Key('goods-bom-learning')));
    await tester.pumpAndSettle();
    // 学习记录面板与背后的页签各显示一次。
    expect(find.text('0.105 千克'), findsNWidgets(2));

    // 操作列在学习记录表格最右侧，先横向滚到可见。
    final relearn = find.byKey(const ValueKey('goods-bom-relearn-goods-p'));
    await tester.ensureVisible(relearn);
    await tester.pumpAndSettle();
    await tester.tap(relearn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(repo.relearned, {'goods-p'});
    expect(repo.listCalls, 2, reason: '重学后组装信息页签重读一次');
    expect(find.text('0.105 千克'), findsNothing, reason: '面板与页签都换成重学后的数据');
    expect(tester.takeException(), isNull);
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
