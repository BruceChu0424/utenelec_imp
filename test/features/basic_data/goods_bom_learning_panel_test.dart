// 「BOM 学习记录」(ADR-129)：父件累计 + 逐组件设计/真实使用数量，
// BOM 外实际用过的料与已删除不再自动加入的料单独标记；没有自动建立学习组件
// 的原因用人话说明；服务端下发 canRelearn 才能「从现在起重新学习」，重学
// 接口直接返回新的学习记录，面板就地换上并通知调用方。日报登记的不良只作
// 说明：头部给累计不良，表格给不良数、实产单耗与不良率，悬停补一句。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_learning_panel.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 伪仓库：按服务端 JSON 契约返回学习记录，并记录重新学习调用。
class _LearningRepo extends Fake implements GoodsBomRepository {
  _LearningRepo(this.summary, {this.afterRelearn});

  /// 打开面板时读到的学习记录。
  final Map<String, dynamic> summary;

  /// 重新学习接口返回的学习记录。
  final Map<String, dynamic>? afterRelearn;
  final relearnCalls = <(String, String)>[];
  var reads = 0;

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async {
    reads++;
    return GoodsBomLearningSummary.fromJson(summary);
  }

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async {
    relearnCalls.add((goodsId, componentGoodsId));
    return GoodsBomLearningSummary.fromJson(afterRelearn ?? summary);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _LearningRepo repo, {
  VoidCallback? onRelearned,
}) async {
  // 与抽屉同宽(showGoodsBomLearning 的 drawerWidth)：整张表不用横向滚动。
  tester.view.physicalSize = const Size(1700, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        goodsBomRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: GoodsBomLearningPanel(
            goodsId: 'shell',
            onRelearned: onRelearned,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 同一批生产里登记的不良(父件单位)：400 良品 + 16 不良 = 实产 416。
const _defect = 16;

/// 服务端按「净耗 ÷ 实产」与「不良 ÷ 实产」给出的两个说明数(6 位)。
Map<String, Object?> _defects(double? perProduced) => {
  'actualDefectQty': _defect,
  'actualPerProducedQty': perProduced,
  'actualDefectRate': 0.038462,
};

/// 学习记录(与服务端 Summary 同形：组件行与组装信息行共用 actual* 字段)。
Map<String, dynamic> _learned({
  bool canRelearn = false,
  int sampleCount = 2,
  double? actualQty = 0.105,
  double? actualPerUnitQty = 0.105,
  String actualStatus = 'ACTUAL',
  String usageBasis = 'ACTUAL',
  String? relearnedAt,
  String glueStatus = 'ACTUAL',
}) => {
  'canRelearn': canRelearn,
  'profile': {
    'totalOutputQty': 400,
    'sampleCount': 2,
    'totalDefectQty': _defect,
    'blockedReason': null,
    'outputUnitName': '个',
  },
  'components': [
    // 顺序故意打乱：页面把组装信息里的组件排在前面。
    {
      'componentGoodsId': 'glue',
      'componentCode': 'G01',
      'componentName': '胶水',
      'unitName': '克',
      'inBom': false,
      'released': false,
      // BOM 外的料：服务端只在累计可用时给每件平均(父件单位变了为空)。
      'actualQty': glueStatus == 'ACTUAL' ? 0.02 : null,
      'actualPerUnitQty': glueStatus == 'ACTUAL' ? 0.02 : null,
      'actualStatus': glueStatus,
      'actualNetQty': 8,
      'actualOutputQty': 400,
      'actualSampleCount': 2,
      ..._defects(glueStatus == 'ACTUAL' ? 0.019231 : null),
      'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
    },
    {
      'componentGoodsId': 'plastic',
      'componentCode': 'P01',
      'componentName': '塑料',
      'unitName': '千克',
      'inBom': true,
      'bomItemId': 'row-1',
      'systemLearned': true,
      'released': false,
      'designQty': 0.1,
      'actualQty': actualQty,
      'actualPerUnitQty': actualPerUnitQty,
      'actualStatus': actualStatus,
      'usageBasis': usageBasis,
      'actualNetQty': sampleCount == 0 ? 0 : 42,
      'actualOutputQty': sampleCount == 0 ? 0 : 400,
      'actualSampleCount': sampleCount,
      if (sampleCount == 0) ...{
        'actualDefectQty': 0,
        'actualPerProducedQty': null,
        'actualDefectRate': null,
      } else
        ..._defects(actualStatus == 'ACTUAL' ? 0.100962 : null),
      'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
      'relearnedAt': relearnedAt,
    },
    {
      'componentGoodsId': 'screw',
      'componentCode': 'S01',
      'componentName': '螺丝',
      'unitName': '个',
      'inBom': false,
      'released': true,
      'actualQty': 2,
      'actualPerUnitQty': 2,
      'actualStatus': 'ACTUAL',
      'actualNetQty': 800,
      'actualOutputQty': 400,
      'actualSampleCount': 2,
      ..._defects(1.923077),
      'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
    },
    {
      'componentGoodsId': 'box',
      'componentCode': 'B01',
      'componentName': '纸箱',
      'unitName': '个',
      'inBom': true,
      'bomItemId': 'row-2',
      'released': false,
      'designQty': 1,
      'actualStatus': 'NO_DATA',
      'usageBasis': 'DESIGN',
      'actualNetQty': 0,
      'actualOutputQty': 0,
      'actualSampleCount': 0,
      'actualDefectQty': 0,
      'actualPerProducedQty': null,
      'actualDefectRate': null,
    },
  ],
};

void main() {
  testWidgets('no profile yet explains when accumulation begins', (
    tester,
  ) async {
    await _pump(
      tester,
      _LearningRepo({'profile': null, 'components': <Map<String, dynamic>>[]}),
    );
    expect(find.textContaining('还没有学习记录'), findsOneWidget);
    expect(find.text('还没有组件，也没有实际用过的料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('components show design, actual, totals and the basis used', (
    tester,
  ) async {
    await _pump(tester, _LearningRepo(_learned()));

    expect(find.textContaining('累计实际产量: 400 个'), findsOneWidget);
    expect(find.textContaining('有效生产批次: 2'), findsOneWidget);
    expect(find.textContaining('累计不良: 16 个'), findsOneWidget);
    // 表头：物料(不再误用「选择材料」)与十个口径列。
    for (final label in [
      '物料',
      '设计使用数量',
      '真实使用数量',
      '实产单耗',
      '累计净耗料',
      '累计产量',
      '不良数',
      '不良率',
      '有效批次',
      '计算采用',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('选择材料'), findsNothing);
    // 塑料：设计 0.1，真实 0.105，按真实使用数量计算，系统学习标记。
    expect(find.text('0.1'), findsOneWidget);
    expect(find.text('0.105'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('系统学习'), findsOneWidget);
    // 纸箱：没有数据 → 按设计使用数量；BOM 外/已删除的料单独标记。
    expect(find.text('BOM 外实际用过的料'), findsOneWidget);
    expect(find.text('已删除，不再自动加入'), findsOneWidget);
    // 组装信息里的组件排在前面：塑料在胶水之上。
    expect(
      tester.getTopLeft(find.text('塑料')).dy,
      lessThan(tester.getTopLeft(find.text('胶水')).dy),
    );
    expect(
      tester.getTopLeft(find.text('胶水')).dy,
      lessThan(tester.getTopLeft(find.text('螺丝')).dy),
    );
    // BOM 外的料按每个父件平均用量给出真实使用数量，悬停说明累计依据
    // (不说「物料分析按它计算」，BOM 外的料不参与计算)。
    expect(find.text('0.02'), findsOneWidget);
    expect(
      find.byTooltip(
        '按 2 批已完工生产累计：净耗 8 克 / 产量 400 个\n'
        '另有不良 16 个：按实产(良品+不良)算用量为 0.019231 克，不良率 3.85%',
      ),
      findsOneWidget,
    );
    // 不良只作说明：塑料按良品的真实使用数量 0.105 计算，另给实产单耗与不良率
    // (胶水、塑料、螺丝同批，各 16 个不良)；纸箱没有数据，不给不良率。
    expect(find.text('0.100962'), findsOneWidget);
    expect(find.text('3.85%'), findsNWidgets(3));
    expect(find.text('16'), findsNWidgets(3));
    expect(
      find.byTooltip(
        '按 2 批已完工生产累计：净耗 42 千克 / 产量 400 个\n'
        '另有不良 16 个：按实产(良品+不良)算用量为 0.100962 千克，不良率 3.85%\n'
        '物料分析和车间领料按真实使用数量计算',
      ),
      findsNWidgets(2),
    );
    // 服务端没下发 canRelearn 就看不到重新学习。
    expect(find.text('从现在起重新学习'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-linear edges explain the design basis with the average', (
    tester,
  ) async {
    await _pump(
      tester,
      _LearningRepo(
        _learned(
          actualQty: null,
          actualStatus: 'NOT_LINEAR',
          usageBasis: 'DESIGN',
        ),
      ),
    );
    expect(
      find.byTooltip('整包或固定批次不能按平均用量算，计算按设计使用数量\n实际平均每件用 0.105 千克'),
      findsWidgets,
    );
    expect(find.text('NOT_LINEAR'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'outside-BOM rows whose parent unit changed show no stale average',
    (tester) async {
      await _pump(
        tester,
        _LearningRepo(_learned(glueStatus: 'OUTPUT_UNIT_CHANGED')),
      );
      // 胶水的旧平均是按旧父件单位算的，不能再摆在「真实使用数量」下。
      expect(find.text('0.02'), findsNothing);
      expect(find.byTooltip('父件单位变了，需重新学习'), findsOneWidget);
      expect(find.text('OUTPUT_UNIT_CHANGED'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blocked reason is explained without technical codes', (
    tester,
  ) async {
    final summary = _learned();
    (summary['profile'] as Map)['blockedReason'] =
        'MATERIAL_COLOR_OR_UNIT_CONFLICT';
    await _pump(tester, _LearningRepo(summary));

    expect(
      find.textContaining('没有自动建立学习组件：同一物料领过多种颜色，请人工在组装信息里确定'),
      findsOneWidget,
    );
    expect(
      find.textContaining('MATERIAL_COLOR_OR_UNIT_CONFLICT'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('relearn asks first, shows the returned record and notifies', (
    tester,
  ) async {
    final repo = _LearningRepo(
      _learned(canRelearn: true),
      afterRelearn: _learned(
        canRelearn: true,
        sampleCount: 0,
        actualQty: null,
        actualPerUnitQty: null,
        actualStatus: 'NO_DATA',
        usageBasis: 'DESIGN',
        relearnedAt: '2026-09-27T09:00:00+08:00',
      ),
    );
    var notified = 0;
    await _pump(tester, repo, onRelearned: () => notified++);

    // 只有已有累计记录的料才能重学(纸箱没有记录)。
    expect(find.byKey(const ValueKey('goods-bom-relearn-box')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('goods-bom-relearn-plastic')));
    await tester.pumpAndSettle();
    expect(find.textContaining('「塑料」从现在起重新学习'), findsOneWidget);

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(repo.relearnCalls, [('shell', 'plastic')]);
    expect(repo.reads, 1, reason: '重学接口已返回新记录，不再多读一次');
    expect(notified, 1, reason: '通知组装信息页签重读');
    expect(find.text('0.105'), findsNothing, reason: '重学后新数据出来前没有真实值');
    // 重学(或系统升级统一从头累计，没有操作人)后说明从哪天起重新累计。
    expect(
      find.byTooltip('还没有已完工且核清余料的生产数据，计算按设计使用数量\n从 2026-09-27 起重新累计'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });
}
