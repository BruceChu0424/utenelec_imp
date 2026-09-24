// 委外任务中心红黄两数(ADR-100)随工作台徽章汇总一次带回(ADR-108): 原来的独立 60s 轮询
// provider 已删除, 红 = 入口 todo(待处理含前置生产 + 财务驳回), 黄 = 入口 inProgress(进行中三档),
// 两数永远来自同一份汇总快照、同时变化。单飞 / 换身份迟到响应作废 / 失败保留旧值由
// test/shared/badges/badge_summary_provider_test.dart 在唯一数据源上锁定; 服务端口径由
// FulfillmentWorkbenchBadgeSources 直接调用委外任务中心计数端点, 与任务中心页同一查询。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  test('红黄两数取自同一份汇总的委外任务中心入口, 下一份汇总到来时一起变', () {
    final badges = FixedBadgeSummaryNotifier(
      badgeSummaryFixture(entries: {BadgeEntry.subcontractTaskCenter: (7, 3)}),
    );
    final container = ProviderContainer(
      overrides: [badgeSummaryProvider.overrideWith(() => badges)],
    );
    addTearDown(container.dispose);
    int red() => container.read(
      badgeEntryTodoProvider(BadgeEntry.subcontractTaskCenter),
    );
    int yellow() => container.read(
      badgeEntryInProgressProvider(BadgeEntry.subcontractTaskCenter),
    );

    expect((red(), yellow()), (7, 3));
    expect(container.read(badgeModuleTodoProvider(BadgeModule.subcontract)), 7);
    expect(
      container.read(badgeModuleInProgressProvider(BadgeModule.subcontract)),
      3,
    );

    badges.emit(
      badgeSummaryFixture(entries: {BadgeEntry.subcontractTaskCenter: (4, 8)}),
    );
    expect((red(), yellow()), (4, 8));
  });

  test('无权查看(汇总里没有该入口)时红黄都按 0, 不渲染徽章', () {
    final container = ProviderContainer(
      overrides: [fixedBadgeSummaryOverride(badgeSummaryFixture())],
    );
    addTearDown(container.dispose);
    expect(
      container.read(badgeEntryTodoProvider(BadgeEntry.subcontractTaskCenter)),
      0,
    );
    expect(
      container.read(
        badgeEntryInProgressProvider(BadgeEntry.subcontractTaskCenter),
      ),
      0,
    );
  });
}
