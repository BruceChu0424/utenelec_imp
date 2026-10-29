# security：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-143 · lib/features/security/pages/security_blacklist_page.dart

模块 `security`；272 行；SHA256 `c11d5cbeb0a7cbde7345b42dbb51cfe7f23140fe1790987806d5834cbda57525`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SecurityBlacklistPage @67 (page-class)<br>_SecurityBlacklistPageState @75 (state-class) |
| 真实路由绑定 | /security/blacklist；router @2214；builder ['SecurityBlacklistPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_staff_repository.dart；接口：/security/blacklist、/security/blacklist/{id}、/security/check-in/{id}、/security/verify、/visitor-approval、/visitor-approval/as-host、/visitor-approval/facets、/visitor-approval/{id}、/visitor-approval/{id}/action、/visitor-approval/{id}/host-confirm |
| 动作处理 | 未静态确认；不能当作不存在 |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/SecurityVisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorApprovalController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/shared/models/retained_async_page.dart` (models)；`lib/components/feedback/uten_context_menu.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/visitor/repositories/visitor_staff_repository.dart` (repositories)；`lib/features/visitor/providers/visitor_column_queries.dart` (providers)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)；`lib/shared/models/paged_result.dart` (models)；`lib/shared/paging/scoped_paged_read_provider.dart` (sharedComponents)；`lib/shared/providers/export_context_epoch_provider.dart` (sharedComponents)。

## W7-BIZ-144 · lib/features/security/pages/security_scan_page.dart

模块 `security`；202 行；SHA256 `9ae75fc2ccb93887665c42f14c17d6b2139ae89b8d259d08323d9abde0e9b853`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SecurityScanPage @23 (page-class)<br>_SecurityScanPageState @30 (state-class) |
| 真实路由绑定 | /security/scan；router @2209；builder ['SecurityScanPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | visitor:blacklist @98；定义 lib/shared/auth/permissions.dart:70 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | stop @56 [action-like-invocation] 提示 ['stop']；_controller?.stop();<br>start @66 [action-like-invocation] 提示 ['start']；_controller?.start(); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/features/security/pages/visitor_check_result_page.dart` (other)。

## W7-BIZ-145 · lib/features/security/pages/visitor_check_result_page.dart

模块 `security`；333 行；SHA256 `a066ccc8e5815ef0a405c2f0ed42e7f10039a9e95891ef31dc9d30dff096d710`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorCheckResultPage @27 (page-class)<br>_VisitorCheckResultPageState @37 (state-class) |
| 真实路由绑定 | 未静态确认；不能当作不存在 |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | visitor:check_in @187；定义 lib/shared/auth/permissions.dart:69<br>visitor:blacklist @193；定义 lib/shared/auth/permissions.dart:70 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_staff_repository.dart；接口：/security/blacklist、/security/blacklist/{id}、/security/check-in/{id}、/security/verify、/visitor-approval、/visitor-approval/as-host、/visitor-approval/facets、/visitor-approval/{id}、/visitor-approval/{id}/action、/visitor-approval/{id}/host-confirm |
| 动作处理 | copyWith @248 [action-like-invocation] 提示 ['copy']；?.copyWith( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/SecurityVisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorApprovalController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 未找到直接路由builder构造；可能由动态factory、共享页面或内部导航进入，需核实。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/features/visitor/repositories/visitor_staff_repository.dart` (repositories)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)。
