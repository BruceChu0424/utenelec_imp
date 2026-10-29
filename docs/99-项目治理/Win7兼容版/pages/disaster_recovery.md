# disaster_recovery：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-045 · lib/features/disaster_recovery/disaster_recovery_page.dart

模块 `disaster_recovery`；265 行；SHA256 `6bcb88e907a0d5fe81a1e8ce358bc62bc05396ad5c6f5fa22354e4f7567d4208`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | DisasterRecoveryPage @62 (page-class)<br>_DisasterRecoveryPageState @70 (state-class) |
| 真实路由绑定 | /operations/recovery；router @475；builder ['DisasterRecoveryPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | post @103 [action-like-invocation] 提示 ['post']；.post( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/inputs/uten_field_hint_icon.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/network/api_client.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/shared/widgets/server_switch_dialog.dart` (sharedComponents)；`lib/core/l10n/disaster_recovery_text.dart` (core)。
