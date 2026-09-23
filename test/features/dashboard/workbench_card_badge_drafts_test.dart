// 工作台模块卡的角标必须包含本模块草稿(WorkbenchCardBadge → 徽章汇总的容器数, ADR-108)。
//
// 用户 2026-09-11：「工作台 销售管理 那里也要有显示，现在 工作台 销售管理没有显示」。
// 根因：WorkbenchBadgeKind.sales 被写死成**单个入口** salesAttention，而不是
// 整模块累计，销售草稿因此永远进不了工作台——hub 顶栏能看到、工作台看不到。
//
// 另一条同族约束：「生产管理」卡取的是「生产模块 − 车间任务」，因为车间任务在
// 工作台另有一张卡；把整模块算进来会双计。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/features/dashboard/widgets/module_badge_sum.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

late SharedPreferences _preferences;

void main() {
  // 卡片角标现在是「黄(进行中) + 红(待办)」两枚(ADR-100), 黄色那条链里有几支
  // 常驻 provider 按会话身份隔离 -> 间接依赖启动时注入的 sharedPreferencesProvider。
  // 不装配它, 整个 WorkbenchCardBadge 会在 build 期抛异常, 连红徽章都找不到。
  // (准则 14 §仓库生产退料与测试装配: 宿主测试新增徽章后必须同步装配该依赖,
  //  不许把徽章移出注册表、屏蔽会话隔离或吞掉 provider 异常来糊弄过去。)
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  Future<int> badgeCount(
    WidgetTester tester,
    WorkbenchBadgeKind kind, {
    required Map<BadgeEntry, (int, int)> entries,
    required Set<String> permissions,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_preferences),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          // 容器之和由服务端算好; 夹具按入口求和模拟。
          fixedBadgeSummaryOverride(badgeSummaryFixture(entries: entries)),
        ],
        child: MaterialApp(
          home: Scaffold(body: WorkbenchCardBadge(kind: kind)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .widget<UtenNotificationBadge>(find.byType(UtenNotificationBadge))
        .count;
  }

  testWidgets('销售管理卡把销售四类草稿算进角标', (tester) async {
    final count = await badgeCount(
      tester,
      WorkbenchBadgeKind.sales,
      // 销售草稿入口 = 订货 2 + 出货 1 + 退货 3 + 报价 4 = 10(服务端目录求和)；
      // salesAttention 无数据按 0。
      entries: const {BadgeEntry.salesDrafts: (10, 0)},
      permissions: const {
        Perm.salesOrderView,
        Perm.salesShipmentView,
        Perm.salesReturnView,
        Perm.salesQuoteView,
      },
    );
    expect(count, 10);
  });

  testWidgets('没有草稿时销售管理卡不凭空长出数字', (tester) async {
    final count = await badgeCount(
      tester,
      WorkbenchBadgeKind.sales,
      entries: const {},
      permissions: const {Perm.salesOrderView},
    );
    expect(count, 0);
  });

  testWidgets('生产管理卡含生产草稿，但不含车间任务（那张卡自己算）', (tester) async {
    final count = await badgeCount(
      tester,
      WorkbenchBadgeKind.production,
      // 生产草稿 7 在生产容器; 车间任务 3 在车间容器, 不进这张卡。
      entries: const {
        BadgeEntry.productionDrafts: (7, 0),
        BadgeEntry.productionWorkshop: (3, 0),
      },
      permissions: const {
        Perm.productionPlanView,
        Perm.productionDailyReportView,
      },
    );
    expect(count, 7);
  });
}
