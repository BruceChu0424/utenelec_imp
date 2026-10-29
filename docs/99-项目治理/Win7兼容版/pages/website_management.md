# website_management：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-214 · lib/features/website_management/pages/website_management_page.dart

模块 `website_management`；592 行；SHA256 `70b3fa92e48e8e6a3ab007fe027f133e81edcb5ebff4f349b24d617fbadfe021`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | WebsiteManagementPage @31 (page-class)<br>_WebsiteWorkspace @55 (supporting-class)<br>_WebsiteWorkspaceState @61 (state-class)<br>_Fact @453 (supporting-class)<br>_SectionRow @467 (supporting-class)<br>_ConnectionEditor @505 (supporting-class)<br>_ConnectionEditorState @519 (state-class) |
| 真实路由绑定 | /website-management；router @758；builder ['WebsiteManagementPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | website:view @39；定义 lib/shared/auth/permissions.dart:500<br>website:view @67；定义 lib/shared/auth/permissions.dart:500<br>authorization:manage @178；定义 lib/shared/auth/permissions.dart:22<br>website:content_edit @186；定义 lib/shared/auth/permissions.dart:501<br>website:product_edit @193；定义 lib/shared/auth/permissions.dart:502<br>website:media_manage @200；定义 lib/shared/auth/permissions.dart:503<br>website:content_edit @207；定义 lib/shared/auth/permissions.dart:501<br>website:content_edit @214；定义 lib/shared/auth/permissions.dart:501<br>website:publish @221；定义 lib/shared/auth/permissions.dart:504<br>website:publish @222；定义 lib/shared/auth/permissions.dart:504<br>website:rollback @223；定义 lib/shared/auth/permissions.dart:505<br>website:view @321；定义 lib/shared/auth/permissions.dart:500<br>website:view @325；定义 lib/shared/auth/permissions.dart:500<br>authorization:manage @392；定义 lib/shared/auth/permissions.dart:22<br>webinquiry:view @428；定义 lib/shared/auth/permissions.dart:499 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | create @115 [action-like-invocation] 提示 ['create']；final proof = WebsiteHandoffProof.create();<br>onSave @581 [action-like-invocation] 提示 ['save']；await widget.onSave(_name.text.trim(), _origin!, _enabled); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_field.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_client.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/authenticated_request_scope.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/providers/authenticated_scope_provider.dart` (sharedComponents)；`lib/features/website_management/models/website_management.dart` (models)；`lib/features/website_management/providers/website_management_providers.dart` (providers)。
