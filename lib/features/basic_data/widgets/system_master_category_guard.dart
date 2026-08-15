import 'package:flutter/material.dart';

/// 由服务端 UUID 注册表派生 [systemManaged]；编号、名称与 legacyId
/// 都只是展示/迁移快照，不得决定系统根保护。

const String systemUncategorizedCategoryProtectionMessage =
    '“未分类”是系统保留分类，不能编辑或删除；仍可在其下新增子分类。';

bool isSystemUncategorizedCategory({required bool systemManaged}) =>
    systemManaged;

/// 编辑权限与系统根保护的统一决策；新增子分类仍只由页面原有编辑权限控制。
bool canMutateMasterCategory({
  required bool hasEditPermission,
  required bool systemManaged,
}) =>
    hasEditPermission &&
    !isSystemUncategorizedCategory(systemManaged: systemManaged);

/// 系统根保护提示。树行使用 [compact] 锁图标，详情卡显示完整说明；两者都
/// 带 Tooltip/Semantics，鼠标、触屏长按和读屏均能理解为何没有编辑/删除动作。
class SystemMasterCategoryProtectionNotice extends StatelessWidget {
  const SystemMasterCategoryProtectionNotice({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final content = compact
        ? Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.lock_outline_rounded,
              key: const ValueKey('system-master-category-lock-icon'),
              size: 16,
              color: color,
            ),
          )
        : Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    systemUncategorizedCategoryProtectionMessage,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          );
    return Tooltip(
      message: systemUncategorizedCategoryProtectionMessage,
      child: Semantics(
        label: systemUncategorizedCategoryProtectionMessage,
        readOnly: true,
        child: content,
      ),
    );
  }
}
