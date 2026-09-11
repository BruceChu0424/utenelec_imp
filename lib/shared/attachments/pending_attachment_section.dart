// 新建单据的「保存前附件」区段：只做选文件 / 列出 / 分类 / 移除，不预览、不下载。
// 真正的上传在单据保存成功后由 PendingAttachmentController.flush 完成；
// 每行的「待保存后上传」已经说清了状态，不再另挂一句静态提示语。
// 分类与已保存单据同一套做法：加入时不问，加入之后在文件旁边可选设置。
// 权限：调用方表达页面级可写（如新建权限），本组件再叠加 attachment:upload。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/cards/uten_card.dart';
import '../../components/layout/uten_section_header.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../auth/permissions.dart';
import 'attachment_category_control.dart';
import 'attachment_file_rules.dart';
import 'attachment_section.dart' show DashedContainer;
import 'pending_attachment_controller.dart';

class PendingAttachmentSection extends ConsumerStatefulWidget {
  const PendingAttachmentSection({
    super.key,
    required this.controller,
    required this.canManage,
    this.title = '相关文件',
    this.categories,
  });

  final PendingAttachmentController controller;
  final bool canManage;
  final String title;

  /// 分类词表（与已保存单据一致）；为 null 时不提供分类。
  /// 分类是可选标注：选文件时不问，加入列表后在文件旁边随时可设可清。
  final List<String>? categories;

  @override
  ConsumerState<PendingAttachmentSection> createState() =>
      _PendingAttachmentSectionState();
}

class _PendingAttachmentSectionState
    extends ConsumerState<PendingAttachmentSection> {
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd =
        widget.canManage &&
        ref.watch(currentPermissionsProvider).contains(Perm.attachmentUpload);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final items = widget.controller.items;
        final busy = _picking || widget.controller.isFlushing;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: UtenSectionHeader(
                    title: widget.title,
                    icon: Icons.folder_outlined,
                    trailing: items.isEmpty
                        ? null
                        : _countBadge(theme, items.length),
                  ),
                ),
                if (canAdd) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  FilledButton.tonalIcon(
                    key: const ValueKey('pending-attachment-add'),
                    onPressed: busy ? null : _pick,
                    icon: widget.controller.isFlushing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file_rounded, size: 18),
                    label: Text(widget.controller.isFlushing ? '上传中…' : '添加文件'),
                  ),
                ],
              ],
            ),
            // 只在真的在传的那几秒出现一行进度；平时不挂静态提示语。
            if (widget.controller.isFlushing)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: Text(
                  '正在上传到刚保存的单据…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: UtenSpacing.s8),
            if (items.isEmpty)
              canAdd ? _dropzone(theme) : _readonlyEmpty(theme)
            else
              UtenCard(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  children: [
                    for (int i = 0; i < items.length; i++) ...[
                      _row(
                        theme,
                        i,
                        items[i],
                        canRemove: canAdd && !busy,
                        canCategorize: canAdd,
                      ),
                      if (i < items.length - 1)
                        const Divider(height: 1, indent: 56),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _countBadge(ThemeData theme, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 空态举例用本页自己的词表（采购单不该写「客户确认」）；这只是举例，不是先分类。
  String get _dropzoneHint {
    final categories = widget.categories;
    if (categories == null || categories.isEmpty) {
      return '开单时就可以先把相关文件放进来';
    }
    return '开单时就可以先放入${categories.take(3).join('、')}';
  }

  Widget _dropzone(ThemeData theme) {
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: _picking ? null : _pick,
      child: DashedContainer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.attach_file_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _dropzoneHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppLocalizations.of(context).attachmentUploadFormatsHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readonlyEmpty(ThemeData theme) {
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Text(
              '保存后可在单据详情添加文件',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    int index,
    PendingAttachment item, {
    required bool canRemove,
    required bool canCategorize,
  }) {
    final error = item.lastError;
    final categories = widget.categories;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: AttachmentKindIcon(
        kind: AttachmentFileKind.of(item.name, item.contentType),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (categories != null) ...[
            const SizedBox(width: UtenSpacing.s8),
            AttachmentCategoryControl(
              categories: categories,
              value: item.category,
              // 上传那几秒只是暂时不接受点击（enabled=false），入口不消失，行不跳动。
              enabled: canRemove,
              onChanged: canCategorize
                  ? (value) => widget.controller.setCategoryAt(index, value)
                  : null,
            ),
          ],
        ],
      ),
      subtitle: Text(
        error == null
            ? '${formatAttachmentSize(item.sizeBytes)} · 待保存后上传'
            : '${formatAttachmentSize(item.sizeBytes)} · 上传失败：$error',
        style: theme.textTheme.bodySmall?.copyWith(
          color: error == null
              ? theme.colorScheme.onSurfaceVariant
              : UtenColors.error,
        ),
      ),
      trailing: canRemove
          ? IconButton(
              tooltip: '移除',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => widget.controller.removeAt(index),
            )
          : null,
    );
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: true,
        allowCompression: false,
      );
      if (!mounted) return;
      final files = result?.files ?? const <PlatformFile>[];
      var accepted = 0;
      for (final f in files) {
        // 加入时不问分类：需要的话在文件旁边点一下再设。
        final rejection = widget.controller.add(f);
        if (rejection == null) {
          accepted++;
        } else if (mounted) {
          context.appError(rejection);
        }
      }
      if (mounted && accepted > 0) {
        context.appInfo('已加入 $accepted 个文件');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }
}
