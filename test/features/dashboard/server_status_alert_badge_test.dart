// 工作台「服务器状态」卡的告警徽章。
//
// 用户 2026-09-11：「有任何报警 都推给我」「我就怕业务附件 196G 不够用」。
// 此前磁盘越过 80%/90% 的告警**只活在服务器状态页内部**——不主动点开就无人知晓。
// 后端补了站内通知推送（ServerStatusAlertScheduler），这里锁住工作台那一眼。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/features/admin/providers/server_status_alert_count_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/module_badge_sum.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  Future<int> badgeCount(
    WidgetTester tester, {
    required int alerts,
    required Set<String> permissions,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          serverStatusAlertCountProvider.overrideWith((ref) async => alerts),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: WorkbenchCardBadge(kind: WorkbenchBadgeKind.serverStatus),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .widget<UtenNotificationBadge>(find.byType(UtenNotificationBadge))
        .count;
  }

  testWidgets('有告警时工作台「服务器状态」卡显示条数', (tester) async {
    final count = await badgeCount(
      tester,
      alerts: 2,
      permissions: const {Perm.serverStatusView},
    );
    expect(count, 2);
  });

  testWidgets('一切正常时不显示徽章', (tester) async {
    final count = await badgeCount(
      tester,
      alerts: 0,
      permissions: const {Perm.serverStatusView},
    );
    expect(count, 0);
    expect(find.text('0'), findsNothing);
  });

  test('告警接收权与查看权是两个独立权限码', () {
    // 「能看这个页面」和「该被半夜吵醒」不是一回事，所以分开授（V552）。
    expect(Perm.serverStatusAlertReceive, 'server_status:alert:receive');
    expect(Perm.serverStatusView, 'server_status:view');
    expect(Perm.serverStatusAlertReceive, isNot(Perm.serverStatusView));
  });
}
