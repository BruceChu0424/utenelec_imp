// 车间内料仓页 (ADR-131 §5.8 / §8.1, 实现规格 §5.4):
// 顶部结算状态三种拦截文案与责任人; 撤销结算后的保留文案; 连续失败文案;
// 按钮只按服务端下发的 allowedActions 显示; 界面不出现任何代号。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_bin_page.dart';

import 'workshop_material_test_support.dart';

// ADR-147: 三态由服务端给出; 没开通的车间只有设置权限的人能开通 (allowedActions 带 OPEN)。
const _targetDisabled = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  status: WmBinStatus.notOpen,
);

const _targetOpenable = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  status: WmBinStatus.notOpen,
  allowedActions: ['SETUP', 'OPEN', 'ENABLE_PERIODIC'],
);

const _targetEnabled = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  status: WmBinStatus.periodic,
  periodicEnabled: true,
  binWarehouseId: 'target-bin',
  allowedActions: ['SETUP'],
);

/// 只开通、收车间直送 (没开整批领料) 的车间。
const _targetDirectOnly = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  status: WmBinStatus.open,
  binWarehouseId: 'target-bin',
  binWarehouseName: '目标车间内料仓',
  allowedActions: ['SETUP', 'ENABLE_PERIODIC', 'CHANGE_SOURCE', 'REVOKE'],
);

const _fourthDirectOnly = WmSetting(
  workshopDepartmentId: 'w4',
  workshopName: '第四车间',
  status: WmBinStatus.open,
  binWarehouseId: 'bin4',
);

const _thirdEnabled = WmSetting(
  workshopDepartmentId: 'w3',
  workshopName: '第三车间',
  status: WmBinStatus.periodic,
  periodicEnabled: true,
  binWarehouseId: 'bin3',
);

/// 双击表格行 (MasterDataTableView 契约: 双击才触发 onRowTap)。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

class _ContextRepository extends FakeWorkshopMaterialRepository {
  final positionReads = <String>[];
  final materialReads = <String>[];
  final pendingPositions = <String, Completer<WmPosition>>{};

  @override
  Future<WmPosition> position(String binId) async {
    positionReads.add(binId);
    return pendingPositions[binId]?.future ?? super.position(binId);
  }

  @override
  Future<List<WmMaterialOption>> materials(String workshopId) async {
    materialReads.add(workshopId);
    return super.materials(workshopId);
  }

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    materialReads.add(workshopId);
    return super.requestMaterials(
      workshopId,
      keyword: keyword,
      goodsIds: goodsIds,
      page: page,
      size: size,
    );
  }
}

Future<void> _switchWorkshop(WidgetTester tester, String name) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('wm-bin-workshops')),
      matching: find.text(name),
    ),
  );
  await tester.pump();
}

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
  testWidgets('explicit disabled workshop does not borrow another enabled '
      'workshop stock or actions', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'target'),
      repo: repo,
    );
    expect(find.text('「目标车间」还没开通内料仓'), findsOneWidget);
    expect(find.textContaining('请找仓库'), findsOneWidget);
    expect(find.text('开通内料仓'), findsNothing);
    expect(find.byKey(const Key('wm-bin-request')), findsNothing);
    expect(repo.positionReads, isEmpty);
  });

  testWidgets(
    'unavailable explicit workshop never falls back or offers setup',
    (tester) async {
      final repo = _ContextRepository()
        ..settingsResult = const [wmTestWorkshop];
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialBinPage(workshopId: 'not-visible'),
        repo: repo,
        permissions: const {
          Perm.workshopMaterialView,
          Perm.workshopMaterialSetup,
        },
      );
      expect(find.text('指定车间当前不可用或无权查看'), findsOneWidget);
      expect(find.text('开通内料仓'), findsNothing);
      expect(find.text('注塑车间'), findsOneWidget);
      expect(repo.positionReads, isEmpty);
      await _switchWorkshop(tester, '注塑车间');
      await tester.pumpAndSettle();
      expect(repo.positionReads, ['bin1']);
      expect(find.text('指定车间当前不可用或无权查看'), findsNothing);
    },
  );

  testWidgets('no other workshop in the server scope means no switcher', (
    tester,
  ) async {
    final repo = _ContextRepository()..settingsResult = const [_targetDisabled];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'target'),
      repo: repo,
    );
    expect(find.text('「目标车间」还没开通内料仓'), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-workshops')), findsNothing);
    expect(repo.positionReads, isEmpty);
  });

  testWidgets('disabled target can explicitly switch to B and C; requests, '
      'returns and counts use the selected workshop only', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled, _thirdEnabled]
      ..positionByBin = const {
        'bin1': WmPosition(rows: [_row], allowedActions: ['REQUEST']),
      }
      ..periodsByBin = const {
        'bin3': [
          WmPeriod(
            id: 'period-3',
            periodNo: 1,
            startDate: '2026-09-01',
            status: 'OPEN',
          ),
        ],
      };
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const WorkshopMaterialBinPage(workshopId: 'target'),
        ),
        GoRoute(
          path: RouteName.workshopMaterialCount,
          builder: (_, state) => Scaffold(
            body: Text('盘点目标 ${state.uri.queryParameters['periodId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await pumpWorkshopMaterialPage(
      tester,
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
      repo: repo,
    );
    expect(find.text('「目标车间」还没开通内料仓'), findsOneWidget);
    expect(repo.positionReads, isEmpty);
    await _switchWorkshop(tester, '注塑车间');
    await tester.pumpAndSettle();
    expect(find.text('注塑车间内料仓'), findsOneWidget);
    expect(repo.positionReads, ['bin1']);
    await tester.tap(find.byKey(const Key('wm-bin-request')));
    await tester.pumpAndSettle();
    expect(find.text('申请领料 · 注塑车间'), findsOneWidget);
    expect(repo.materialReads.last, 'w1');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    final loadingThird = Completer<WmPosition>();
    repo.pendingPositions['bin3'] = loadingThird;
    await _switchWorkshop(tester, '第三车间');
    expect(find.text('第三车间内料仓'), findsOneWidget);
    expect(find.text('PP 颗粒'), findsNothing);
    expect(find.byKey(const Key('wm-bin-request')), findsNothing);
    expect(find.byKey(const Key('wm-bin-return')), findsNothing);
    expect(find.byKey(const Key('wm-bin-count')), findsNothing);
    loadingThird.complete(
      const WmPosition(rows: [_row], allowedActions: ['RETURN', 'START_COUNT']),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-bin-request')), findsNothing);
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-bin-return')));
    await tester.pumpAndSettle();
    expect(find.text('退回 · 第三车间'), findsOneWidget);
    expect(repo.materialReads.last, 'w3');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-bin-count')));
    await tester.pumpAndSettle();
    expect(find.text('盘点目标 period-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not-open target opens its bin in place through the opening '
      'panel and then reads the newly opened bin even when another workshop '
      'sorts first', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'target'),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialSetup,
      },
    );
    expect(find.text('「目标车间」还没开通内料仓'), findsOneWidget);
    await tester.tap(find.text('开通内料仓'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-bin-panel-workshops')), findsOneWidget);
    // 服务端办完后清单里目标车间变成已开通 (整批领料中)。
    repo.settingsResult = const [wmTestWorkshop, _targetEnabled];
    await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
    await tester.pumpAndSettle();
    expect(repo.batchEnables.single.items.single.workshopId, 'target');
    expect(repo.batchEnables.single.items.single.expectedStatus, 'NOT_OPEN');
    expect(repo.batchEnables.single.periodic, isFalse);
    expect(repo.positionReads, isNotEmpty);
    expect(repo.positionReads, everyElement('target-bin'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('只开通、收车间直送的内料仓: 只列现有的料, 没有发料/盘点动作, '
      '有设置权限可接着开启整批领料', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [_targetDirectOnly]
      ..positionByBin = const {
        'target-bin': WmPosition(rows: [_row]),
      };
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'target'),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialSetup,
        Perm.workshopMaterialRequest,
      },
    );
    expect(repo.positionReads, ['target-bin']);
    expect(find.byKey(const Key('wm-bin-direct-only')), findsOneWidget);
    expect(find.text('PP 颗粒'), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-request')), findsNothing);
    expect(find.byKey(const Key('stock-count-mode')), findsNothing);
    expect(find.byKey(const Key('wm-bin-enable-periodic')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览: 有设置权限才有勾选列和右下批量开通/开启整批领料/撤销, '
      '没勾选时按钮灰显', (tester) async {
    final repo = FakeWorkshopMaterialRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
    );
    expect(find.byKey(const Key('wm-overview-table')), findsOneWidget);
    expect(
      tester
          .widget<MasterDataTableView<WmSetting>>(
            find.byKey(const Key('wm-overview-table')),
          )
          .selectable,
      isFalse,
    );
    expect(find.byKey(const Key('wm-overview-batch-open')), findsNothing);

    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
      permissions: const {Perm.workshopMaterialSetup},
    );
    expect(
      tester
          .widget<MasterDataTableView<WmSetting>>(
            find.byKey(const Key('wm-overview-table')),
          )
          .selectable,
      isTrue,
    );
    expect(find.byKey(const Key('wm-overview-batch-open')), findsOneWidget);
    expect(find.text('开通(0)'), findsOneWidget);
    expect(find.text('开启整批领料(0)'), findsOneWidget);
    expect(find.text('撤销(0)'), findsOneWidget);
    expect(find.byKey(const Key('wm-overview-machines')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    expect(
      find.ancestor(
        of: find.byKey(const Key('wm-bin-request')),
        matching: find.byType(UtenFloatingActionGroup),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-bin-return')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-other-issue')), findsOneWidget);
    expect(find.byKey(const Key('wm-bin-count')), findsOneWidget);
    _expectNoCodes();
  });

  testWidgets('窄屏顶部仅导航与账期，主动作悬浮、低频操作收纳', (tester) async {
    final repo = _repo(
      status: const WmCloseStatus(status: 'OPEN', closeState: 'NONE'),
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: repo,
      size: const Size(375, 760),
      textScale: 1.3,
      permissions: {Perm.workshopMaterialView, stockCountSubmitPermission},
    );
    expect(tester.takeException(), isNull);
    expect(find.text('库存盘点'), findsOneWidget);
    expect(find.text('周期盘点'), findsNothing);
    final request = find.byKey(const Key('wm-bin-request'));
    expect(tester.getTopLeft(request).dy, greaterThan(550));
    expect(
      tester.getTopLeft(find.byKey(const Key('wm-bin-view'))).dy,
      lessThan(150),
    );
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    expect(find.text('周期盘点'), findsOneWidget);
    expect(find.text('我的盘点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览行里不放按钮: 行高与平台普通文字行一致 (可勾选时只多出勾选框的点击区)', (tester) async {
    final repo = FakeWorkshopMaterialRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable];
    Future<double> rowHeight(Set<String> permissions) async {
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialBinPage(),
        repo: repo,
        permissions: permissions,
      );
      for (final id in ['w1', 'target']) {
        final row = find.byKey(ValueKey('wm-overview-row-$id'));
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.byType(TextButton)),
          findsNothing,
        );
        expect(
          find.descendant(of: row, matching: find.byType(UtenButton)),
          findsNothing,
        );
      }
      return tester
          .getSize(find.byKey(const ValueKey('wm-overview-row-w1')))
          .height;
    }

    // 只读 (不能开通): 纯文字行约 35px (13 号字 x 1.45 行高 + 上下各 8)。
    expect(await rowHeight(const {Perm.workshopMaterialView}), lessThan(44));
    // 可勾选: 行高只由勾选框的最小点击区决定, 与平台其它多选列表相同; 旧版行内按钮是 60px。
    expect(
      await rowHeight(const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialSetup,
      }),
      lessThanOrEqualTo(kMinInteractiveDimension),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用入口总览三态分段, 不自动读取第一个仓的库存', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [
        wmTestWorkshop,
        _targetDisabled,
        _fourthDirectOnly,
      ];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
    );
    final table = tester.widget<MasterDataTableView<WmSetting>>(
      find.byKey(const Key('wm-overview-table')),
    );
    expect(table.items.length, 3);
    expect(repo.positionReads, isEmpty);
    for (final label in ['未开通', '已开通', '整批领料中']) {
      expect(
        find.descendant(
          of: find.byKey(const Key('wm-overview-status')),
          matching: find.textContaining(label),
        ),
        findsOneWidget,
      );
    }
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('wm-overview-status')),
        matching: find.textContaining('未开通'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MasterDataTableView<WmSetting>>(
            find.byKey(const Key('wm-overview-table')),
          )
          .items
          .single
          .status,
      WmBinStatus.notOpen,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览双击: 已开通进内料仓, 未开通打开开通面板; 返回总览不自动读仓', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable];
    final router = GoRouter(
      initialLocation: RouteName.workshopMaterialBin,
      routes: [
        GoRoute(
          path: RouteName.workshopMaterialBin,
          builder: (_, state) => WorkshopMaterialBinPage(
            workshopId: state.uri.queryParameters['workshopId'],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await pumpWorkshopMaterialPage(
      tester,
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialSetup,
      },
    );
    expect(repo.positionReads, isEmpty);
    await _doubleTapRow(tester, find.text('注塑车间').first);
    await tester.pumpAndSettle();
    expect(repo.positionReads, isNotEmpty);
    expect(repo.positionReads, everyElement('bin1'));
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-bin-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-overview-table')), findsOneWidget);
    final stockReads = repo.positionReads.length;
    await _doubleTapRow(tester, find.text('目标车间').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-bin-panel-workshops')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wm-bin-panel-close')));
    await tester.pumpAndSettle();
    expect(repo.positionReads.length, stockReads, reason: '打开面板不读任何仓的库存');
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾选两个未开通的车间: 右下「开通(2)」一次开通, 已开通的不算; 撤销只数已开通的', (tester) async {
    const second = WmSetting(
      workshopDepartmentId: 'w2',
      workshopName: '装配车间',
      status: WmBinStatus.notOpen,
      allowedActions: ['SETUP', 'OPEN', 'ENABLE_PERIODIC'],
    );
    final repo = FakeWorkshopMaterialRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable, second];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialSetup,
      },
    );
    final table = find.byKey(const Key('wm-overview-table'));
    tester.widget<MasterDataTableView<WmSetting>>(table).onSelectedIdsChanged!({
      'w1',
      'target',
      'w2',
    });
    await tester.pumpAndSettle();
    expect(find.text('开通(2)'), findsOneWidget);
    expect(find.text('开启整批领料(2)'), findsOneWidget);
    expect(find.text('撤销(1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wm-overview-batch-open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('所选车间 (2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
    await tester.pumpAndSettle();
    final call = repo.batchEnables.single;
    expect(call.items.map((i) => i.workshopId), ['target', 'w2']);
    expect(call.items.map((i) => i.expectedStatus), ['NOT_OPEN', 'NOT_OPEN']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有设置权限可看总览和开通，明确仓深链也不读库存', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetOpenable];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
      permissions: const {Perm.workshopMaterialSetup},
      size: const Size(375, 760),
      textScale: 1.3,
    );
    expect(find.byKey(const Key('wm-overview-table')), findsOneWidget);
    expect(repo.positionReads, isEmpty);
    expect(tester.takeException(), isNull);
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(workshopId: 'w1'),
      repo: repo,
      permissions: const {Perm.workshopMaterialSetup},
    );
    expect(find.text('当前只有设置权限'), findsOneWidget);
    expect(repo.positionReads, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
