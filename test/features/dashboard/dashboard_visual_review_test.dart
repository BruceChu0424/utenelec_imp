import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';
import 'package:uten_imp/features/dashboard/widgets/dashboard_console_sections.dart';
import 'package:uten_imp/features/dashboard/widgets/uten_console_panel.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  for (final width in [1440.0, 375.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'department overview $width ${dark ? 'dark' : 'light'}',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          await loadAuditScreenshotFonts(tester);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
              child: MaterialApp(
                theme: auditScreenshotTheme(
                  dark ? buildDarkTheme() : buildLightTheme(),
                ),
                home: RepaintBoundary(
                  key: boundary,
                  child: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const UtenConsoleHeader(
                            title: '今日概览',
                            subtitle: '综合营销部 · 本部门有权查看的业务',
                          ),
                          const SizedBox(height: 16),
                          const DashboardMetricStrip(
                            departmentName: '综合营销部',
                            metrics: [
                              DashboardMetric(
                                id: 'sales-active',
                                title: '执行中订单',
                                value: '24',
                                subtitle: '已审核且尚未结案',
                                tone: 'info',
                                route: '/sales/orders',
                                sensitive: false,
                              ),
                              DashboardMetric(
                                id: 'notice-unread',
                                title: '未读通知',
                                value: '3',
                                subtitle: '发给本人的业务消息',
                                tone: 'neutral',
                                route: '/notice',
                                sensitive: false,
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          const UtenConsoleHeader(
                            title: '待办任务',
                            subtitle: '综合营销部 · 按紧急度排布',
                          ),
                          const SizedBox(height: 16),
                          DashboardTodoLane(
                            departmentName: '综合营销部',
                            todos: [
                              for (final entry in [
                                ('a', '订货单待修订', '财务已退回，请核对后重新提交', 2),
                                ('b', '生产已完成', '订单已完成生产，可安排销售发货', 1),
                                ('c', '客户确认', '交期与交货资料需要确认', 3),
                              ])
                                DashboardTodo(
                                  id: entry.$1,
                                  title: entry.$2,
                                  summary: entry.$3,
                                  count: entry.$4,
                                  urgentCount: entry.$1 == 'a' ? 2 : 0,
                                  tone: entry.$1 == 'a' ? 'danger' : 'info',
                                  route: '/sales',
                                  sourceType: 'SALES',
                                  sourceId: null,
                                  dueAt: null,
                                  completable: false,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await saveAuditScreenshot(
            tester,
            boundary,
            'dashboard-department-${width.toInt()}-${dark ? 'dark' : 'light'}',
          );
        },
        skip: !const bool.fromEnvironment('UTEN_CAPTURE_UI'),
      );
    }
  }
}
