// 车间内料仓用量报表与结算页 (ADR-131 §5.10)：
//  1. 没有看成本权限的人 (服务端金额下发为空) 看不到金额列，有金额时出现；
//  2. 产品用料：独占期平均耗用与分摊区分，估盘来源沿期初/期末展示；
//  3. 结算被拦：三种拦截文案与负责人都显示；按钮只按服务端 allowedActions 出现；
//  4. 撤销结算：先填原因，服务端要求再认证时弹统一密码框，输完后撤销生效；
//     版本取结算状态里的最新期间版本 (每次结算尝试都会让它 +1)，不用期间列表里的旧值；
//  5. 服务端报表行形状：收发明细「来源单据」= 库存单据号 / 领料单号，盘点过账显示「盘点」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/workshop_material_report_models.dart';
import 'package:uten_imp/features/production/pages/workshop_material_reports_page.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_report_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

class _FakeRepo implements WorkshopMaterialReportRepository {
  _FakeRepo({
    this.usage = const [],
    this.product = const [],
    Map<String, WmReportCloseStatus>? statuses,
  }) : statuses = statuses ?? {};

  final List<WmBinUsageRow> usage;
  final List<WmProductUsageRow> product;
  final Map<String, WmReportCloseStatus> statuses;
  final reopenCalls = <({String periodId, int? version, String reason})>[];
  final stepUpTokens = <String?>[];

  @override
  Future<List<WmReportBin>> bins() async => const [
    WmReportBin(
      binWarehouseId: 'bin-1',
      workshopDepartmentId: 'ws-1',
      workshopName: '注塑车间',
      binWarehouseName: '注塑车间内料仓',
      periodicEnabled: true,
    ),
  ];

  @override
  Future<List<WmReportPeriod>> periods(String binId) async => const [
    WmReportPeriod(
      id: 'p1',
      periodNo: 1,
      startDate: '2026-09-01',
      endDate: '2026-09-15',
      status: 'CLOSED',
      closeState: 'NONE',
      rowVersion: 7,
    ),
    WmReportPeriod(
      id: 'p2',
      periodNo: 2,
      startDate: '2026-09-16',
      endDate: '2026-09-27',
      status: 'COUNTED',
      closeState: 'BLOCKED',
      rowVersion: 3,
    ),
    WmReportPeriod(
      id: 'p3',
      periodNo: 3,
      startDate: '2026-09-28',
      status: 'OPEN',
      closeState: 'NONE',
      rowVersion: 0,
    ),
  ];

  @override
  Future<WmReportCloseStatus> closeStatus(String periodId) async =>
      statuses[periodId] ??
      WmReportCloseStatus(periodId: periodId, status: 'OPEN');

  @override
  Future<WmReportCloseStatus> retryClose(WmReportCloseStatus current) async =>
      throw UnimplementedError();

  @override
  Future<WmReportCloseStatus> reopen(
    String periodId, {
    required int? expectedVersion,
    required String reason,
  }) async {
    // 模拟服务端 @RequiresStepUp：网络层向协调器要一张再认证凭证。
    stepUpTokens.add(await StepUpCoordinator.instance.obtain());
    reopenCalls.add((
      periodId: periodId,
      version: expectedVersion,
      reason: reason,
    ));
    final held = WmReportCloseStatus(
      periodId: periodId,
      status: 'COUNTED',
      closeState: 'HELD',
      heldUntil: '2026-09-29T10:00:00+08:00',
      allowedActions: const {'CLOSE_RETRY'},
    );
    statuses[periodId] = held;
    return held;
  }

  @override
  Future<List<WmBinUsageRow>> binUsage(
    String binId, {
    String? from,
    String? to,
  }) async => usage;

  @override
  Future<List<WmProductUsageRow>> productUsage(
    String binId, {
    String? from,
    String? to,
  }) async => product;

  @override
  Future<List<WmWasteTrendPoint>> wasteTrend(
    String binId, {
    String? goodsId,
  }) async => const [];

  @override
  Future<List<WmMissingWeightRow>> missingWeights(String binId) async =>
      const [];

  @override
  Future<PagedResult<WmLedgerRow>> ledger(
    String binId, {
    String? from,
    String? to,
    int page = 1,
    int size = 50,
  }) async =>
      const PagedResult(items: [], page: 1, size: 50, total: 0, totalPages: 1);
}

const _usageRow = WmBinUsageRow(
  periodId: 'p1',
  periodNo: 1,
  startDate: '2026-09-01',
  endDate: '2026-09-15',
  goodsId: 'pc',
  goodsName: 'PC E-15',
  costBasis: 'OWN',
  openingQty: 0,
  transferInQty: 100,
  returnQty: 0,
  otherIssueQty: 2,
  closingQty: 18,
  actualQty: 80,
  theoryQty: 75,
  diffQty: 5,
  wasteRate: 0.0667,
  outcome: 'ALLOCATED',
  consumedQty: 80,
);

WmBinUsageRow _withCost(WmBinUsageRow r) => WmBinUsageRow(
  periodId: r.periodId,
  periodNo: r.periodNo,
  startDate: r.startDate,
  endDate: r.endDate,
  goodsId: r.goodsId,
  goodsName: r.goodsName,
  costBasis: r.costBasis,
  actualQty: r.actualQty,
  theoryQty: r.theoryQty,
  wasteRate: r.wasteRate,
  outcome: r.outcome,
  unitCost: 12.5,
  currentValue: 1000,
  valueAtClose: 1000,
);

Future<void> _pump(
  WidgetTester tester,
  _FakeRepo repo, {
  String? initialPeriodId,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      // 每个伪仓库一棵新树：同一个测试里换数据重新进页面。
      key: ValueKey(repo),
      overrides: [
        workshopMaterialReportRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: WorkshopMaterialReportsPage(initialPeriodId: initialPeriodId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  _serverShapeTests();
  testWidgets('服务端没给金额 (无看成本权限) 时金额列整列隐藏，有金额时出现', (tester) async {
    await _pump(tester, _FakeRepo(usage: const [_usageRow]));

    expect(find.text('PC E-15'), findsOneWidget);
    expect(find.text('盘点推算耗用'), findsOneWidget);
    expect(find.text('金额'), findsNothing);
    expect(find.text('结算时金额'), findsNothing);
    expect(find.text('单价'), findsNothing);

    await _pump(tester, _FakeRepo(usage: [_withCost(_usageRow)]));
    expect(find.text('金额'), findsOneWidget);
    expect(find.text('结算时金额'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('产品用料：独占期平均不冒充实测，并展示期初估盘来源', (tester) async {
    await _pump(
      tester,
      _FakeRepo(
        product: const [
          WmProductUsageRow(
            periodId: 'p1',
            periodNo: 1,
            productCode: 'A01',
            productName: '外壳',
            materialName: 'PC E-15',
            outputQty: 1000,
            unitWeightGrams: 12.5,
            theoryQty: 12.5,
            allocatedQty: 13,
            exclusivePeriod: true,
            actualPerUnitGrams: 13,
            openingCountBasis: 'ESTIMATED',
            closingCountBasis: 'WEIGHED',
            materialUnitName: 'kg',
          ),
          WmProductUsageRow(
            periodId: 'p1',
            periodNo: 1,
            productCode: 'B02',
            productName: '底座',
            materialName: 'ABS 757',
            outputQty: 500,
            unitWeightGrams: 20,
            theoryQty: 10,
            allocatedQty: 11,
          ),
        ],
      ),
    );

    await tester.tap(find.text('产品用料'));
    await tester.pumpAndSettle();

    expect(find.text('独占期平均耗用'), findsOneWidget);
    expect(find.text('真实单耗'), findsNothing);
    expect(find.text('按理论比例分摊'), findsOneWidget);
    expect(find.text('12.5'), findsWidgets);
    expect(find.text('材料金额'), findsNothing, reason: '没有金额时不出金额列');
    final table = tester.widget<MasterDataTableView<WmProductUsageRow>>(
      find.byType(MasterDataTableView<WmProductUsageRow>),
    );
    final evidence = table.columns.singleWhere(
      (column) => column.key == 'countEvidence',
    );
    expect(evidence.value(table.items.first), '期初：含容器估盘；期末：称重/公斤录入');
    expect(table.columns.map((column) => column.label), contains('分摊耗用'));
    final unit = table.columns.singleWhere(
      (column) => column.key == 'materialUnit',
    );
    expect(unit.label, '材料单位');
    expect(unit.value(table.items.first), 'kg');
    expect(find.textContaining('不等于报废率'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结算被拦：三种拦截文案与负责人都显示，按钮只按 allowedActions 出现', (tester) async {
    await _pump(
      tester,
      _FakeRepo(
        statuses: {
          'p2': const WmReportCloseStatus(
            periodId: 'p2',
            status: 'COUNTED',
            closeState: 'BLOCKED',
            blockers: [
              WmReportCloseBlocker(
                kind: 'DRAFT_REPORT',
                count: 2,
                responsible: '报工审核人或制单人',
                samples: ['RB20260920001', 'RB20260921002'],
              ),
              WmReportCloseBlocker(
                kind: 'MISSING_WEIGHT',
                count: 1,
                samples: ['外壳'],
              ),
              WmReportCloseBlocker(
                kind: 'THEORY_WITHOUT_STOCK',
                count: 1,
                samples: ['PC E-15'],
              ),
            ],
          ),
        },
      ),
    );

    // 没选期间：结算状态卡看最近一次盘点的那一期 (第 2 期)。
    expect(find.byKey(const Key('wm-close-status-card')), findsOneWidget);
    expect(find.textContaining('第 2 期'), findsWidgets);
    expect(find.textContaining('还有 2 张报工没审核'), findsOneWidget);
    expect(find.textContaining('RB20260920001'), findsOneWidget);
    expect(find.textContaining('负责：报工审核人或制单人'), findsOneWidget);
    expect(find.textContaining('有 1 个产品没填单个重量'), findsOneWidget);
    expect(find.textContaining('「PC E-15」这一期没有发料记录'), findsOneWidget);
    // 服务端没给动作：不出现重试 / 撤销按钮。
    expect(find.byKey(const Key('wm-close-retry')), findsNothing);
    expect(find.byKey(const Key('wm-close-reopen')), findsNothing);
    // 面向员工的文案不出现内部代号。
    for (final code in [
      'DRAFT_REPORT',
      'MISSING_WEIGHT',
      'BLOCKED',
      'COUNTED',
    ]) {
      expect(find.textContaining(code), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销结算：填原因后触发再认证弹窗，输完密码撤销生效', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final verified = <String>[];
    final unregister = StepUpCoordinator.instance.register(
      () => showReauthDialog(
        navigatorKey.currentContext!,
        verify: (password) async {
          verified.add(password);
          return 'one-time-token';
        },
      ),
    );
    addTearDown(unregister);
    final repo = _FakeRepo(
      statuses: {
        'p1': const WmReportCloseStatus(
          periodId: 'p1',
          status: 'CLOSED',
          lastCloseNo: 1,
          lastClosedByName: '张三',
          rowVersion: 9,
          allowedActions: {'REOPEN'},
        ),
      },
    );
    await _pump(
      tester,
      repo,
      initialPeriodId: 'p1',
      navigatorKey: navigatorKey,
    );

    expect(find.text('已结算'), findsWidgets);
    expect(find.byKey(const Key('wm-close-retry')), findsNothing);
    await tester.tap(find.byKey(const Key('wm-close-reopen')));
    await tester.pumpAndSettle();

    // 原因必填：空着点确认不关框。
    await tester.tap(find.byKey(const Key('wm-reopen-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-reopen-reason')), findsOneWidget);
    expect(repo.reopenCalls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('wm-reopen-reason')),
      '单个重量填错了，改完重结',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-reopen-confirm')));
    await _frames(tester);

    // 服务端要求再认证：统一密码框压在忙碌遮罩之上。
    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-password'))),
    );
    await tester.pump();
    tester.testTextInput.enterText('CorrectPassword1');
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-confirm'))),
    );
    await _frames(tester);
    await tester.pumpAndSettle();

    expect(verified, ['CorrectPassword1']);
    expect(repo.stepUpTokens, ['one-time-token']);
    expect(repo.reopenCalls, hasLength(1));
    expect(repo.reopenCalls.single.periodId, 'p1');
    // 期间列表里是 7，结算状态里最新是 9：以 9 提交。
    expect(repo.reopenCalls.single.version, 9);
    expect(repo.reopenCalls.single.reason, '单个重量填错了，改完重结');
    // 撤销后：保留 24 小时的说明 + 「重新结算」按钮 (服务端给了 CLOSE_RETRY)。
    expect(find.byKey(const Key('wm-close-held')), findsOneWidget);
    expect(find.text('重新结算'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 服务端报表行形状 (WorkshopMaterialReportDtos / CloseStatusView)。
void _serverShapeTests() {
  test('盘点来源兼容旧响应，期初或期末估盘都影响本期而独占不改变可信度', () {
    final inherited = WmBinUsageRow.fromJson({
      'openingCountBasis': 'ESTIMATED',
      'closingCountBasis': 'WEIGHED',
      'actualQty': 90,
    });
    expect(inherited.hasEstimatedCount, isTrue);
    expect(inherited.hasUnknownCount, isFalse);
    expect(inherited.actualQty, 90);
    final product = WmProductUsageRow.fromJson({
      'exclusivePeriod': true,
      'openingCountBasis': 'BAG_COUNT',
      'closingCountBasis': 'ESTIMATED',
      'actualPerUnit': 0.013,
      'materialUnitKgFactor': 1,
    });
    expect(product.hasEstimatedCount, isTrue);
    expect(product.actualPerUnitGrams, 13);
    final old = WmBinUsageRow.fromJson({'actualQty': 90});
    expect(old.hasUnknownCount, isTrue);
    expect(old.countEvidenceLabel, '期初：来源未提供；期末：来源未提供');
    final trend = WmWasteTrendPoint.fromJson({
      'openingCountBasis': 'EMPTY_START',
      'closingCountBasis': 'WEIGHED_AND_BAGS',
    });
    expect(trend.hasEstimatedCount, isFalse);
    expect(trend.hasUnknownCount, isFalse);
  });

  test('产品用量按服务端质量单位因子换克，别名和未知单位不靠名字猜', () {
    WmProductUsageRow read(double? factor, {String name = '别名单位'}) =>
        WmProductUsageRow.fromJson({
          'unitWeight': 12.5,
          'actualPerUnit': 13,
          'materialUnitName': name,
          'materialUnitKgFactor': factor,
        });
    expect(read(0.001).unitWeightGrams, closeTo(12.5, 0.000000001));
    expect(read(0.001).actualPerUnitGrams, closeTo(13, 0.000000001));
    expect(read(1).unitWeightGrams, closeTo(12500, 0.000000001));
    expect(read(0.45359237).unitWeightGrams, closeTo(5669.904625, 0.000001));
    final unknown = read(null, name: 'kg');
    expect(unknown.unitWeightGrams, isNull);
    expect(unknown.actualPerUnitGrams, isNull);
    expect(unknown.unitWeightBase, 12.5);
    expect(unknown.materialUnitName, 'kg');
    expect(read(0).unitWeightGrams, isNull);
  });

  test('已审核期初和账面修正与领入分开保留', () {
    final row = WmBinUsageRow.fromJson({
      'openingCountBasis': 'APPROVED_OPENING',
      'closingCountBasis': 'WEIGHED',
      'transferInQty': 100,
      'adjustmentQty': -5,
    });
    expect(row.hasUnknownCount, isFalse);
    expect(row.countEvidenceLabel, '期初：已审核期初盘点；期末：称重/公斤录入');
    expect(row.transferInQty, 100);
    expect(row.adjustmentQty, -5);
    expect(WmLedgerRow.fromJson({'sourceKind': 'OPENING'}).sourceLabel, '盘点审核');
    expect(
      WmLedgerRow.fromJson({'sourceKind': 'ADJUSTMENT'}).sourceLabel,
      '盘点审核',
    );
  });

  test('收发明细：来源单据取库存单据号与领料单号，盘点过账显示盘点', () {
    final issue = WmLedgerRow.fromJson({
      'sourceRowId': 'r1',
      'sourceKind': 'ISSUE',
      'docNo': 'DB20260901001',
      'requestNo': 'LL20260901001',
      'supplement': true,
      'signedQty': 50,
    });
    expect(issue.id, 'r1');
    expect(issue.isSupplement, isTrue);
    expect(issue.sourceLabel, 'DB20260901001 / LL20260901001');
    final consume = WmLedgerRow.fromJson({
      'sourceRowId': 'r2',
      'sourceKind': 'CONSUME',
      'signedQty': -12.5,
    });
    expect(consume.sourceLabel, '盘点');
  });

  test('结算状态带期间最新版本；浪费率按货品 + 颜色 id 分组', () {
    final status = WmReportCloseStatus.fromJson({
      'periodId': 'p1',
      'status': 'CLOSED',
      'closeState': 'NONE',
      'rowVersion': 12,
      'lastClose': {'closeNo': 2, 'closedByName': '张三'},
      'allowedActions': ['REOPEN'],
    }, periodId: 'p1');
    expect(status.rowVersion, 12);
    expect(status.lastCloseNo, 2);
    final a = WmWasteTrendPoint.fromJson({
      'goodsId': 'g',
      'colorId': 'c1',
      'colorName': '黑',
    });
    final b = WmWasteTrendPoint.fromJson({
      'goodsId': 'g',
      'colorId': 'c2',
      'colorName': '黑',
    });
    expect(a.materialKey == b.materialKey, isFalse);
  });
}

/// 忙碌遮罩里的进度圈一直在转，不能 pumpAndSettle；固定推进若干帧。
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
