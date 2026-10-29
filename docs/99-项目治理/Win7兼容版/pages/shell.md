# shell：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-148 · lib/features/shell/pages/main_shell_page.dart

模块 `shell`；461 行；SHA256 `99f18c4f851940ad5a89c86a620a5a34d9eaebffc6c063b6472e74bc3def6472`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | MainShellPage @60 (page-class)<br>_MainShellPageState @75 (state-class)<br>_KeepAlivePage @442 (page-class)<br>_KeepAlivePageState @451 (state-class) |
| 真实路由绑定 | None；router @539；builder ['MainShellPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | removeObserver @115 [action-like-invocation] 提示 ['remove']；WidgetsBinding.instance.removeObserver(this); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_page_scrollbar_host.dart` (sharedComponents)；`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/responsive/display_zoom.dart` (core)；`lib/core/router/page_resume_provider.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/features/dashboard/pages/dashboard_page.dart` (other)；`lib/features/dashboard/providers/dashboard_overview_provider.dart` (providers)；`lib/features/notice/pages/notice_list_page.dart` (other)；`lib/features/notice/providers/notice_providers.dart` (providers)；`lib/features/profile/pages/profile_page.dart` (other)；`lib/features/settings/pages/settings_page.dart` (other)；`lib/features/shell/widgets/floating_capsule_nav_bar.dart` (featureWidgets)；`lib/features/shell/widgets/idle_timeout_guard.dart` (featureWidgets)；`lib/features/shell/widgets/uten_side_nav_rail.dart` (featureWidgets)；`lib/features/shell/widgets/uten_sliding_tab_view.dart` (featureWidgets)；`lib/shared/badges/badge_registry.dart` (sharedComponents)；`lib/shared/ai/chat/ai_chat_overlay.dart` (sharedComponents)。
