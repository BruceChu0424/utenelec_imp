# dashboard：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-042 · lib/features/dashboard/pages/dashboard_page.dart

模块 `dashboard`；177 行；SHA256 `e7e7ca931dd621ea84afdc5fc323b43a2a52604d8753f77910140baf5e78c6fc`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | DashboardPage @38 (page-class) |
| 真实路由绑定 | /dashboard；router @553；builder ['DashboardPage']；redirect None |
| 重定向/别名候选 | {"routeId":"router:547","routerLine":547,"path":"/","targetConstants":["dashboard"],"redirectExpression":"(_, _) => RouteName.dashboard","status":"possible alias; 需人工核实"} |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @107 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.headlineMedium?.copyWith(<br>copyWith @115 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_user_avatar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/features/admin/widgets/impersonation_actions.dart` (featureWidgets)；`lib/features/notice/widgets/celebration_popup_gate.dart` (featureWidgets)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/features/dashboard/widgets/dashboard_overview_sections.dart` (featureWidgets)；`lib/features/dashboard/widgets/workbench_module_area.dart` (featureWidgets)。
