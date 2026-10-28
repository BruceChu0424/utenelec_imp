// 货品导入模式三选一弹窗（2026-10-28）：所有「导入货品」入口先在这里选模式，
// 再进入既有导入流程（选文件→检测→核对→提交）。模式贯穿 detect/commit，
// 服务端计划固化模式，提交不一致即拒绝。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/goods_import.dart';
import 'goods_import_dialog.dart';

/// 弹出三选一模式弹窗；确认后带着所选模式进入导入流程。
/// 取消返回时不打开导入弹窗。
Future<void> showGoodsImportWithModePicker(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onImported,
}) async {
  final mode = await showDialog<GoodsImportMode>(
    context: context,
    builder: (_) => const _GoodsImportModePickerDialog(),
  );
  if (mode == null || !context.mounted) return;
  await showGoodsImportDialog(context, ref, mode: mode, onImported: onImported);
}

class _GoodsImportModePickerDialog extends StatefulWidget {
  const _GoodsImportModePickerDialog();

  @override
  State<_GoodsImportModePickerDialog> createState() =>
      _GoodsImportModePickerDialogState();
}

class _GoodsImportModePickerDialogState
    extends State<_GoodsImportModePickerDialog> {
  GoodsImportMode _selected = GoodsImportMode.mixed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenAlertDialog(
      maxWidth: 520,
      title: const UtenDialogHeading(
        icon: Icons.file_upload_outlined,
        title: Text('选择导入方式'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final mode in GoodsImportMode.values) ...[
            if (mode != GoodsImportMode.values.first)
              const SizedBox(height: UtenSpacing.s12),
            Semantics(
              key: ValueKey('goods-import-mode-${mode.wireName}'),
              selected: mode == _selected,
              inMutuallyExclusiveGroup: true,
              child: UtenButton(
                type: mode == _selected
                    ? UtenButtonType.tonal
                    : UtenButtonType.ghost,
                size: UtenButtonSize.large,
                isExpanded: true,
                onPressed: () => setState(() => _selected = mode),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: UtenSpacing.s2),
                      child: Icon(
                        mode == _selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            mode.label,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            _descriptionOf(mode),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('下一步'),
        ),
      ],
    );
  }

  static String _descriptionOf(GoodsImportMode mode) {
    return switch (mode) {
      // 组装信息ID 列在三种模式下都生效：有值即复制整棵组装信息。
      GoodsImportMode.createOnly => '全部新建，保留文件中的分类',
      GoodsImportMode.updateOnly => '只修改系统标识能匹配的已有货品',
      GoodsImportMode.mixed => '同时处理新增和修改',
    };
  }
}
