# website_management：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-214 · lib/features/website_management/pages/website_management_page.dart

模块 `website_management`；593 行；SHA256 `465a320dfffb6dcff7311c51ca4a533e255291c60c33e4de8142ffdc2ac9941e`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | WebsiteManagementPage @31 (page-class)<br>_WebsiteWorkspace @55 (supporting-class)<br>_WebsiteWorkspaceState @61 (state-class)<br>_Fact @454 (supporting-class)<br>_SectionRow @468 (supporting-class)<br>_ConnectionEditor @506 (supporting-class)<br>_ConnectionEditorState @520 (state-class) |
| 真实路由绑定 | /website-management；router @784；builder ['WebsiteManagementPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | website:view @39；定义 lib/shared/auth/permissions.dart:520<br>website:view @67；定义 lib/shared/auth/permissions.dart:520<br>authorization:manage @179；定义 lib/shared/auth/permissions.dart:22<br>website:content_edit @187；定义 lib/shared/auth/permissions.dart:521<br>website:product_edit @194；定义 lib/shared/auth/permissions.dart:522<br>website:media_manage @201；定义 lib/shared/auth/permissions.dart:523<br>website:content_edit @208；定义 lib/shared/auth/permissions.dart:521<br>website:content_edit @215；定义 lib/shared/auth/permissions.dart:521<br>website:publish @222；定义 lib/shared/auth/permissions.dart:524<br>website:publish @223；定义 lib/shared/auth/permissions.dart:524<br>website:rollback @224；定义 lib/shared/auth/permissions.dart:525<br>website:view @322；定义 lib/shared/auth/permissions.dart:520<br>website:view @326；定义 lib/shared/auth/permissions.dart:520<br>authorization:manage @393；定义 lib/shared/auth/permissions.dart:22<br>webinquiry:view @429；定义 lib/shared/auth/permissions.dart:519 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | create @115 [action-like-invocation] 提示 ['create']；final proof = WebsiteHandoffProof.create();<br>onSave @582 [action-like-invocation] 提示 ['save']；await widget.onSave(_name.text.trim(), _origin!, _enabled); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_field.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_client.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/authenticated_request_scope.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/providers/authenticated_scope_provider.dart` (sharedComponents)；`lib/features/website_management/models/website_management.dart` (models)；`lib/features/website_management/providers/website_management_providers.dart` (providers)。
