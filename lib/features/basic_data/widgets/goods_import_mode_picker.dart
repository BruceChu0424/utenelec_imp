// 货品导入模式三选一弹窗（2026-10-28）：所有「导入货品」入口先在这里选模式，
// 再进入既有导入流程（选文件→检测→核对→提交）。模式贯穿 detect/commit，
// 服务端计划固化模式，提交不一致即拒绝。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
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
    return UtenAlertDialog(
      maxWidth: 520,
      showCloseButton: true,
      title: const UtenDialogHeading(
        icon: Icons.file_upload_outlined,
        title: Text('选择导入方式'),
        subtitle: Text('请选择本次导入的处理方式'),
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
              child: UtenDialogOptionCard(
                icon: switch (mode) {
                  GoodsImportMode.createOnly => Icons.note_add_outlined,
                  GoodsImportMode.updateOnly => Icons.edit_note_outlined,
                  GoodsImportMode.mixed => Icons.merge_type_rounded,
                },
                title: Text(mode.label),
                subtitle: Text(_descriptionOf(mode)),
                selected: mode == _selected,
                onTap: () => setState(() => _selected = mode),
              ),
            ),
          ],
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('下一步'),
              const SizedBox(width: UtenSpacing.s8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ],
          ),
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
