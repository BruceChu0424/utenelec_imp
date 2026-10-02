// 车间内料仓页 (ADR-131 §5.8 / §8.1, 实现规格 §5.4):
// 顶部结算状态三种拦截文案与责任人; 撤销结算后的保留文案; 连续失败文案;
// 按钮只按服务端下发的 allowedActions 显示; 界面不出现任何代号。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

const _targetDisabled = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  periodicEnabled: false,
  allowedActions: ['SETUP'],
);

const _targetEnabled = WmSetting(
  workshopDepartmentId: 'target',
  workshopName: '目标车间',
  periodicEnabled: true,
  binWarehouseId: 'target-bin',
  allowedActions: ['SETUP'],
);

const _thirdEnabled = WmSetting(
  workshopDepartmentId: 'w3',
  workshopName: '第三车间',
  periodicEnabled: true,
  binWarehouseId: 'bin3',
);

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
    expect(find.text('「目标车间」尚未开启整批领料'), findsOneWidget);
    expect(find.textContaining('请找仓库'), findsOneWidget);
    expect(find.text('去开启整批领料'), findsNothing);
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
      expect(find.text('去开启整批领料'), findsNothing);
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
    expect(find.text('「目标车间」尚未开启整批领料'), findsOneWidget);
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
    expect(find.text('「目标车间」尚未开启整批领料'), findsOneWidget);
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

  testWidgets('setup navigation carries the target and return uses its newly '
      'enabled bin even when another workshop sorts first', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const WorkshopMaterialBinPage(workshopId: 'target'),
        ),
        GoRoute(
          path: RouteName.workshopMaterialSetup,
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                Text('配置车间 ${state.uri.queryParameters['workshopId']}'),
                TextButton(
                  onPressed: () {
                    repo.settingsResult = const [
                      wmTestWorkshop,
                      _targetEnabled,
                    ];
                    context.pop();
                  },
                  child: const Text('完成开启并返回'),
                ),
              ],
            ),
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
    await tester.tap(find.text('去开启整批领料'));
    await tester.pumpAndSettle();
    expect(find.text('配置车间 target'), findsOneWidget);
    await tester.tap(find.text('完成开启并返回'));
    await tester.pumpAndSettle();
    expect(find.text('目标车间内料仓'), findsOneWidget);
    expect(repo.positionReads, isNotEmpty);
    expect(repo.positionReads, everyElement('target-bin'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('未开启内料仓时仅有设置权限的人可进入开启流程', (tester) async {
    final repo = FakeWorkshopMaterialRepository();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
    );
    expect(find.text('去开启整批领料'), findsNothing);
    expect(find.byKey(const Key('wm-overview-table')), findsOneWidget);
    expect(find.byKey(const Key('wm-overview-manage')), findsNothing);

    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
      permissions: const {Perm.workshopMaterialSetup},
    );
    expect(find.byKey(const Key('wm-overview-manage')), findsOneWidget);
    expect(find.text('开通与设置'), findsOneWidget);
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

  testWidgets('通用入口总览含未启用车间，不自动读取第一个仓的库存', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
    );
    final table = tester.widget<MasterDataTableView<WmSetting>>(
      find.byKey(const Key('wm-overview-table')),
    );
    expect(table.items.map((s) => s.workshopDepartmentId), ['w1', 'target']);
    expect(repo.positionReads, isEmpty);
    expect(find.byKey(const Key('wm-overview-setup-target')), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('wm-overview-status')),
        matching: find.textContaining('未启用'),
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
          .workshopDepartmentId,
      'target',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览选择后才进入指定仓，返回仍能管理未启用车间', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled];
    final router = GoRouter(
      initialLocation: RouteName.workshopMaterialBin,
      routes: [
        GoRoute(
          path: RouteName.workshopMaterialBin,
          builder: (_, state) => WorkshopMaterialBinPage(
            workshopId: state.uri.queryParameters['workshopId'],
          ),
        ),
        GoRoute(
          path: RouteName.workshopMaterialSetup,
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                Text('配置 ${state.uri.queryParameters['workshopId']}'),
                TextButton(
                  onPressed: () {
                    repo.settingsResult = const [
                      wmTestWorkshop,
                      _targetEnabled,
                    ];
                    context.pop();
                  },
                  child: const Text('开通并返回'),
                ),
              ],
            ),
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
    await tester.tap(find.byKey(const ValueKey('wm-overview-open-w1')));
    await tester.pumpAndSettle();
    expect(repo.positionReads, everyElement('bin1'));
    expect(repo.positionReads, isNotEmpty);
    await tester.tap(find.byKey(const Key('wm-bin-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-bin-settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wm-bin-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-overview-table')), findsOneWidget);
    final stockReads = repo.positionReads.length;
    await tester.tap(find.byKey(const ValueKey('wm-overview-setup-target')));
    await tester.pumpAndSettle();
    expect(find.text('配置 target'), findsOneWidget);
    await tester.tap(find.text('开通并返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-overview-open-target')), findsOneWidget);
    expect(repo.positionReads.length, stockReads, reason: '开启返回总览不自动读任意仓');
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有设置权限可看总览和配置，明确仓深链也不读库存', (tester) async {
    final repo = _ContextRepository()
      ..settingsResult = const [wmTestWorkshop, _targetDisabled];
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialBinPage(),
      repo: repo,
      permissions: const {Perm.workshopMaterialSetup},
      size: const Size(375, 760),
      textScale: 1.3,
    );
    expect(find.byKey(const Key('wm-overview-manage')), findsOneWidget);
    expect(find.byKey(const ValueKey('wm-overview-open-w1')), findsNothing);
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
