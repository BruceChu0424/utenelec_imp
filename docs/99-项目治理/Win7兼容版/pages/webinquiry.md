# webinquiry：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-212 · lib/features/webinquiry/pages/website_inquiry_detail_page.dart

模块 `webinquiry`；426 行；SHA256 `15e30ff2a24afb1c3acb7526aafa6b02ec7611e5a6298fbf66799c50553798c1`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | WebsiteInquiryDetailPage @31 (page-class)<br>_HeaderCard @128 (supporting-class)<br>_MessageCard @192 (supporting-class)<br>_RequirementCard @228 (supporting-class)<br>_ActionPanel @287 (supporting-class)<br>_ConvertedCard @397 (supporting-class) |
| 真实路由绑定 | /webinquiry/:id；router @768；builder ['WebsiteInquiryDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | webinquiry:claim @48；定义 lib/shared/auth/permissions.dart:742<br>webinquiry:close @49；定义 lib/shared/auth/permissions.dart:743<br>webinquiry:convert_client @51；定义 lib/shared/auth/permissions.dart:744 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @151 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleLarge?.copyWith(<br>copyWith @166 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @182 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @209 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),<br>copyWith @217 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @266 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>updateWebsiteInquiryStatus @321 [action-like-invocation] 提示 ['update']；() => updateWebsiteInquiryStatus(<br>updateWebsiteInquiryStatus @352 [action-like-invocation] 提示 ['update']；() => updateWebsiteInquiryStatus(<br>copyWith @365 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/authenticated_request_scope.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/features/webinquiry/models/website_inquiry.dart` (models)；`lib/features/webinquiry/providers/website_inquiry_providers.dart` (providers)；`lib/features/webinquiry/widgets/website_inquiry_source_timeline.dart` (featureWidgets)；`lib/shared/providers/authenticated_scope_provider.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)。

## W7-BIZ-213 · lib/features/webinquiry/pages/website_inquiry_list_page.dart

模块 `webinquiry`；270 行；SHA256 `9e919aea7a6b29138d5f52e6066a8794b462b39003f90f26eb54628f6e3213d3`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | WebsiteInquiryListPage @29 (page-class)<br>_InquiryCard @150 (supporting-class) |
| 真实路由绑定 | /webinquiry；router @763；builder ['WebsiteInquiryListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @177 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @194 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleMedium?.copyWith(<br>copyWith @204 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @215 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @233 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @250 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @258 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_paged_grid.dart` (sharedComponents)；`lib/components/layout/uten_responsive_grid.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/features/webinquiry/models/website_inquiry.dart` (models)；`lib/features/webinquiry/providers/website_inquiry_providers.dart` (providers)。
