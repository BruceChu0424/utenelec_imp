// 车间内料仓页 (ADR-131 §5.8 / §8.1, 实现规格 §5.4):
// 顶部结算状态三种拦截文案与责任人; 撤销结算后的保留文案; 连续失败文案;
// 按钮只按服务端下发的 allowedActions 显示; 界面不出现任何代号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_bin_page.dart';

import 'workshop_material_test_support.dart';

const _periods = [
  WmPeriod(
    id: 'p1',
    periodNo: 1,
    startDate: '2026-09-01',
    endDate: '2026-09-27',
    status: 'COUNTED',
    closeState: 'BLOCKED',
  ),
  WmPeriod(id: 'p2', periodNo: 2, startDate: '2026-09-28', status: 'OPEN'),
];

const _row = WmPositionRow(
  goodsId: 'pp',
  goodsCode: 'PP-01',
  goodsName: 'PP 颗粒',
  bookQty: 120,
  periodInQty: 500,
  estimatedUsedQty: 380,
  estimatedRemainingQty: 120,
  warehouseAvailableQty: 800,
);

FakeWorkshopMaterialRepository _repo({
  required WmCloseStatus status,
  List<String> actions = const [
    'REQUEST',
    'RETURN',
    'OTHER_ISSUE',
    'START_COUNT',
  ],
}) => FakeWorkshopMaterialRepository()
  ..settingsResult = const [wmTestWorkshop]
  ..periodsByBin = const {'bin1': _periods}
  ..positionByBin = {
    'bin1': WmPosition(rows: const [_row], allowedActions: actions),
  }
  ..closeStatusByPeriod = {'p1': status};

/// 界面上不许出现的服务端代号。
const _codes = [
  'BLOCKED',
  'HELD',
  'FAILED',
  'QUEUED',
  'COUNTED',
  'DRAFT_REPORT',
  'MISSING_WEIGHT',
  'THEORY_WITHOUT_STOCK',
  'PREVIOUS_PERIOD_OPEN',
  'CLOSE_RETRY',
];

void _expectNoCodes() {
  for (final code in _codes) {
    expect(find.textContaining(code), findsNothing, reason: code);
  }
}

void main() {
  testWidgets('三种拦截: 差什么、谁来补, 不出现代号', (tester) async {
    final repo = _repo(
      status: const WmCloseStatus(
        status: 'COUNTED',
        closeState: 'BLOCKED',
        blockers: [
          WmBlocker(
            kind: 'DRAFT_REPORT',
            count: 2,
            responsible: 'REPORT_APPROVER',
            samples: ['RB20260927001', 'RB20260927002'],
          ),
          WmBlocker(
            kind: 'MISSING_WEIGHT',
            count: 1,
            responsible: 'BOM_OWNER',
            samples: ['外壳'],
          ),
          WmBlocker(
            kind: 'THEORY_WITHOUT_STOCK',
            count: 1,
            responsible: 'WAREHOUSE',
            samples: ['ABS 颗粒'],
          ),
        ],
        allowedActions: ['CLOSE_RETRY'],
      ),
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: repo,
    );

    expect(find.byKey(const Key('wm-close-status-banner')), findsOneWidget);
    expect(
      find.textContaining('还有 2 张报工没审核 (请审核人审核, 或制单人删掉不要的草稿)'),
      findsOneWidget,
    );
    expect(find.textContaining('RB20260927001、RB20260927002'), findsOneWidget);
    expect(find.textContaining('有 1 个产品没填单个重量 (请 BOM 维护人处理)'), findsOneWidget);
    expect(
      find.textContaining('「ABS 颗粒」这一期没有发料记录却有产品在用 (请仓库补录漏录的发料, 或车间改认料)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('第 1 期 (2026-09-01 至 2026-09-27)'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('wm-close-retry')), findsOneWidget);
    _expectNoCodes();
  });

  testWidgets('撤销结算后: 说明 24 小时后自动重新结算, 按钮是"重新结算"', (tester) async {
    final repo = _repo(
      status: const WmCloseStatus(
        status: 'COUNTED',
        closeState: 'HELD',
        heldUntil: '2026-09-29T10:00:00+08:00',
        allowedActions: ['CLOSE_RETRY'],
      ),
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: repo,
    );

    expect(find.textContaining('已撤销结算, 改完请点「重新结算」'), findsOneWidget);
    expect(find.textContaining('2026-09-29 10:00 系统会自动重新结算'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('wm-close-retry')),
        matching: find.text('重新结算'),
      ),
      findsOneWidget,
    );
    _expectNoCodes();
  });

  testWidgets('连续失败 3 次: 改为每天重试并请联系管理员, 显示业务原因', (tester) async {
    final repo = _repo(
      status: const WmCloseStatus(
        status: 'COUNTED',
        closeState: 'FAILED',
        failures: 3,
        attempts: 5,
        lastErrorMessage: '在制价值核对不平, 请联系系统管理员',
      ),
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: repo,
    );

    expect(find.textContaining('结算连续失败, 系统改为每天重试一次, 请联系系统管理员'), findsOneWidget);
    expect(find.textContaining('原因: 在制价值核对不平'), findsOneWidget);
    // 没有 CLOSE_RETRY 就不画"立即重试"。
    expect(find.byKey(const Key('wm-close-retry')), findsNothing);
    _expectNoCodes();
  });

  testWidgets('按钮只按 allowedActions 显示', (tester) async {
    // 用不需要轮询的状态 (排队结算中会每 2 秒问一次进度)。
    const status = WmCloseStatus(status: 'COUNTED', closeState: 'BLOCKED');
    final limited = _repo(status: status, actions: const ['REQUEST']);
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: limited,
    );
    expect(find.byKey(const Key('wm-bin-request')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-return')), findsNothing);
    expect(find.byKey(const Key('wm-bin-other-issue')), findsNothing);
    expect(find.byKey(const Key('wm-bin-count')), findsNothing);
    // 现存表: 估计还剩与仓库还有。
    expect(find.text('PP 颗粒'), findsOneWidget);
    expect(find.text('800'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    final full = _repo(status: status);
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: full,
    );
    expect(find.byKey(const Key('wm-bin-request')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-return')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-other-issue')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-count')), findsOneWidget);
    _expectNoCodes();
  });
}
