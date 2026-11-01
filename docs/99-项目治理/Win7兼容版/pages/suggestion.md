# suggestion：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-162 · lib/features/suggestion/pages/suggestion_detail_page.dart

模块 `suggestion`；435 行；SHA256 `2551312d6fccb276b709ab74c42304ac9b0618c3231bc7e41620be1a7f24512c`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SuggestionDetailPage @29 (page-class)<br>_Content @55 (supporting-class)<br>_ReplyComposer @249 (supporting-class)<br>_ReplyComposerState @258 (state-class)<br>_ReplyCard @368 (supporting-class) |
| 真实路由绑定 | /suggestion/:id；router @772；builder ['SuggestionDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | suggestion:reply @139；定义 lib/shared/auth/permissions.dart:516<br>suggestion:submit @169；定义 lib/shared/auth/permissions.dart:515 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @101 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.labelMedium?.copyWith(<br>copyWith @120 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.headlineSmall?.copyWith(<br>copyWith @133 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),<br>copyWith @314 [action-like-invocation] 提示 ['copy']；style: Theme.of(context).textTheme.bodySmall?.copyWith(<br>_submit @345 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>copyWith @409 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @415 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @427 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),<br>_submit @326 [callback-reference] 提示 ['submit']；onAction |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_field.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/features/suggestion/models/suggestion.dart` (models)；`lib/features/suggestion/providers/suggestion_providers.dart` (providers)。

## W7-BIZ-163 · lib/features/suggestion/pages/suggestion_list_page.dart

模块 `suggestion`；322 行；SHA256 `bcb9c61a8307244e492cebb9f66eaa74c6bf733b3170ee79fce9c5a8a4c95c00`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SuggestionListPage @43 (page-class)<br>_SuggestionListPageState @50 (state-class) |
| 真实路由绑定 | /suggestion；router @762；builder ['SuggestionListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | suggestion:submit @87；定义 lib/shared/auth/permissions.dart:515<br>suggestion:submit @149；定义 lib/shared/auth/permissions.dart:515<br>suggestion:submit @201；定义 lib/shared/auth/permissions.dart:515<br>suggestion:submit @238；定义 lib/shared/auth/permissions.dart:515 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | UtenListCreateAction @83 [action-like-invocation] 提示 ['create']；final createAction = UtenListCreateAction( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/drafts/form_drafts_page.dart` (sharedComponents)；`lib/components/feedback/uten_context_menu.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/feedback/uten_list_create_action.dart` (sharedComponents)；`lib/shared/models/paged_result.dart` (models)；`lib/shared/models/retained_async_page.dart` (models)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/suggestion/models/suggestion.dart` (models)；`lib/features/suggestion/providers/suggestion_providers.dart` (providers)。

## W7-BIZ-164 · lib/features/suggestion/pages/suggestion_new_page.dart

模块 `suggestion`；238 行；SHA256 `1b4c5685b298e6d56bfcfff1e2296bd27db40b5dc0deacd89e6065bc635a5390`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SuggestionNewPage @24 (page-class)<br>_SuggestionNewPageState @31 (state-class) |
| 真实路由绑定 | /suggestion/new；router @767；builder ['SuggestionNewPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | restoreFormDraft @51 [method-declaration-candidate] 提示 ['restore']；Future<void> restoreFormDraft(Map<String, dynamic> data) async {<br>addPostFrameCallback @61 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());<br>copyWith @108 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>_submit @201 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>saveFormDraftNow @213 [action-like-invocation] 提示 ['save']；await saveFormDraftNow();<br>submitSuggestion @215 [action-like-invocation] 提示 ['submit']；() => submitSuggestion(<br>completeFormDraft @223 [action-like-invocation] 提示 ['complete']；await completeFormDraft(); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/feedback/uten_toast.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/drafts/form_draft_mixin.dart` (sharedComponents)；`lib/shared/drafts/form_draft_catalog.dart` (sharedComponents)；`lib/features/suggestion/models/suggestion.dart` (models)；`lib/features/suggestion/providers/suggestion_providers.dart` (providers)。
