// 通用附件区段：列出 + 上传 + 预览/下载 + 删除 + 逐个文件的可选分类。
// 可复用于任意 ownerType/ownerId；接入方：员工详情「档案文件」（EMPLOYEE）、
// 合同附件弹窗（EMPLOYEE_CONTRACT）、报销详情（EXPENSE_CLAIM）、我的文件（EMPLOYEE 只读）。
// 调用方只表达 owner/state 是否允许上传或删除；组件统一叠加 attachment:upload/delete。
// 预览和下载统一使用 attachment:download；对象范围由后端 AttachmentOwnerAccessPolicy 终审。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/io/file_saver.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../components/cards/uten_card.dart';
import '../../components/layout/uten_section_header.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../core/utils/china_datetime.dart';
import '../auth/permissions.dart';
import 'attachment.dart';
import 'attachment_category_control.dart';
import 'attachment_file_rules.dart';
import 'attachment_preview_dialog.dart';
import 'attachment_service.dart';

class AttachmentSection extends ConsumerStatefulWidget {
  const AttachmentSection({
    super.key,
    required this.ownerType,
    required this.ownerId,
    required this.attachments,
    required this.ownerCanUpload,
    required this.ownerCanDelete,
    required this.onChanged,
    this.title,
    this.emptyHint,
    this.categories,
    this.onSetAvatar,
  });

  final String ownerType;
  final String ownerId;
  final List<Attachment> attachments;
  final bool ownerCanUpload;
  final bool ownerCanDelete;
  final VoidCallback onChanged;

  /// 区段标题（默认「附件 / 发票」；员工档案传「档案文件」）。
  final String? title;

  /// 空态提示文案（默认「暂无附件」）。
  final String? emptyHint;

  /// 文档分类词表（员工档案：合同/身份证件/学历证书/照片/其他）。为 null 时整块分类功能关闭。
  /// 分类是「传完之后在文件旁边可选设置」的标注，上传前不询问、也不是必填；
  /// 只有文件多到看不过来（≥4 个且用了 ≥2 种分类）才另外出一行筛选。
  final List<String>? categories;

  /// 把图片附件设为头像（仅员工档案用；为 null 时不显示该按钮）。
  final void Function(Attachment)? onSetAvatar;

  @override
  ConsumerState<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends ConsumerState<AttachmentSection> {
  bool _busy = false;
  String? _progressLabel; // 上传进度文案（多文件时显示「正在上传 2/3」）
  String? _filterCategory; // 纯查看筛选（null = 全部），与上传无关

  /// 刚改过分类的本地值：服务端已落库，先就地生效，避免为一个标注整块重新加载。
  final Map<String, String?> _categoryOverride = {};

  /// 正在保存分类的附件 id（该行控件暂时不接受新点击）。
  final Set<String> _savingCategory = {};

  @override
  void didUpdateWidget(covariant AttachmentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.attachments, widget.attachments)) return;
    // 服务端已回读到同一分类（或文件已不在列表）时丢弃本地值，
    // 以免长期遮住别人改过的分类。
    _categoryOverride.removeWhere(
      (id, value) =>
          !widget.attachments.any((a) => a.id == id && a.category != value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canDownload = permissions.contains(Perm.attachmentDownload);
    final canUpload =
        widget.ownerCanUpload && permissions.contains(Perm.attachmentUpload);
    final canDelete =
        widget.ownerCanDelete && permissions.contains(Perm.attachmentDelete);
    final usedCategories = _usedCategories;
    // 只有真正找不过来时才出筛选行；两三个文件时它只是噪音。
    final showFilter =
        widget.attachments.length >= 4 && usedCategories.length >= 2;
    final filter = showFilter ? _filterCategory : null;
    final visible = _filteredBy(filter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: UtenSectionHeader(
                title: widget.title ?? '附件 / 发票',
                icon: Icons.folder_outlined,
                trailing: widget.attachments.isEmpty
                    ? null
                    : _countBadge(theme, widget.attachments.length),
              ),
            ),
            if (canUpload) ...[
              const SizedBox(width: UtenSpacing.s8),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _pickAndUpload,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_outlined, size: 18),
                label: Text(_busy ? '上传中…' : '上传'),
              ),
            ],
          ],
        ),
        if (_busy && _progressLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  _progressLabel!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (showFilter) ...[
          const SizedBox(height: UtenSpacing.s8),
          _filterRow(theme, usedCategories, filter),
        ],
        const SizedBox(height: UtenSpacing.s8),
        if (widget.attachments.isEmpty)
          canUpload ? _uploadDropzone(theme) : _readonlyEmpty(theme)
        else if (visible.isEmpty)
          _readonlyEmpty(theme, hint: '该分类下暂无文件')
        else
          UtenCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              children: [
                for (int i = 0; i < visible.length; i++) ...[
                  _row(
                    theme,
                    visible[i],
                    canDownload: canDownload,
                    canDelete: canDelete,
                    canCategorize: canUpload,
                  ),
                  if (i < visible.length - 1)
                    const Divider(height: 1, indent: 56),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// 标题旁的计数徽章：浅青底 + 深青字，与品牌色一致。
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

  /// 只筛选、不改任何东西：前置漏斗图标 + 「只看」二字把它和「设置分类」分清楚。
  Widget _filterRow(
    ThemeData theme,
    List<String> usedCategories,
    String? active,
  ) {
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              '只看',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        _filterChip(null, '全部', widget.attachments.length, active),
        for (final c in usedCategories)
          _filterChip(
            c,
            c,
            widget.attachments.where((a) => _categoryOf(a) == c).length,
            active,
          ),
      ],
    );
  }

  Widget _filterChip(String? value, String label, int count, String? active) {
    return ChoiceChip(
      label: Text(count > 0 ? '$label $count' : label),
      selected: active == value,
      onSelected: (_) => setState(() => _filterCategory = value),
      visualDensity: VisualDensity.compact,
    );
  }

  /// 可管理时的空态：虚线上传区，整块可点击直接选文件。
  Widget _uploadDropzone(ThemeData theme) {
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: _busy ? null : _pickAndUpload,
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
                  Icons.cloud_upload_outlined,
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
                      widget.emptyHint ?? '点击上传文件',
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

  /// 只读空态：安静、克制。
  Widget _readonlyEmpty(ThemeData theme, {String? hint}) {
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
            // 空态文案可能较长（「无权限查看」等），窄屏叠大字号会横向溢出：
            // 2026-09-11 钱流详情 390 宽 + 字号 1.5 复现 → Flexible 换行兜底。
            Flexible(
              child: Text(
                hint ?? widget.emptyHint ?? '暂无附件',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    Attachment a, {
    required bool canDownload,
    required bool canDelete,
    required bool canCategorize,
  }) {
    final kind = AttachmentFileKind.of(a.originalName, a.contentType);
    final categories = widget.categories;
    final previewable = AttachmentPreviewDialog.canPreview(
      a.originalName,
      a.contentType,
    );
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: AttachmentKindIcon(kind: kind),
      title: Row(
        children: [
          Flexible(
            child: Text(
              a.originalName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (categories != null) ...[
            const SizedBox(width: UtenSpacing.s8),
            AttachmentCategoryControl(
              categories: categories,
              value: _categoryOf(a),
              enabled: !_savingCategory.contains(a.id),
              onChanged: canCategorize
                  ? (value) => _setCategory(a, value)
                  : null,
            ),
          ],
          if (a.avatar) ...[
            const SizedBox(width: UtenSpacing.s4),
            const AttachmentCategoryTag(label: '头像', highlighted: true),
          ],
        ],
      ),
      subtitle: Text(
        [
          formatAttachmentSize(a.sizeBytes),
          if (a.uploadedAt != null) ChinaDateTime.formatDate(a.uploadedAt!),
        ].join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canDownload)
            IconButton(
              tooltip: previewable ? '预览' : '下载',
              icon: Icon(
                previewable
                    ? Icons.visibility_outlined
                    : Icons.download_outlined,
                size: 20,
              ),
              onPressed: () => _view(a),
            ),
          if (widget.onSetAvatar != null && a.isImage && !a.avatar)
            IconButton(
              tooltip: '设为头像',
              icon: const Icon(Icons.account_circle_outlined, size: 20),
              onPressed: () => widget.onSetAvatar!(a),
            ),
          if (canDelete)
            IconButton(
              tooltip: '删除',
              icon: const Icon(
                Icons.delete_outline,
                size: 20,
                color: UtenColors.error,
              ),
              onPressed: () => _delete(a),
            ),
        ],
      ),
      onTap: canDownload ? () => _view(a) : null,
    );
  }

  /// 当前生效的分类：本地刚改过的值优先于列表里的服务端值。
  String? _categoryOf(Attachment a) => _categoryOverride.containsKey(a.id)
      ? _categoryOverride[a.id]
      : a.category;

  /// 已经被用上的分类，按本页词表顺序排列（没用到的不进筛选行）。
  List<String> get _usedCategories {
    final categories = widget.categories;
    if (categories == null) return const [];
    final used = widget.attachments
        .map(_categoryOf)
        .whereType<String>()
        .toSet();
    return categories.where(used.contains).toList();
  }

  List<Attachment> _filteredBy(String? category) {
    if (category == null) return widget.attachments;
    return widget.attachments.where((a) => _categoryOf(a) == category).toList();
  }

  /// 设置/清除单个文件的分类。分类只是标注：先就地生效再落库，失败原样退回并提示。
  Future<void> _setCategory(Attachment a, String? value) async {
    if (_savingCategory.contains(a.id)) return;
    final previous = _categoryOf(a);
    if (previous == value) return;
    setState(() {
      _savingCategory.add(a.id);
      _categoryOverride[a.id] = value;
    });
    try {
      await ref.read(attachmentServiceProvider).setCategory(a.id, value);
    } catch (e) {
      if (mounted) {
        setState(() => _categoryOverride[a.id] = previous);
        context.appError('分类未能保存：$e');
      }
    } finally {
      if (mounted) setState(() => _savingCategory.remove(a.id));
    }
  }

  Future<void> _pickAndUpload() async {
    if (_busy || !_canUse(Perm.attachmentUpload, widget.ownerCanUpload)) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: true,
        allowCompression: false,
      );
      if (!mounted) return;
      final files = result?.files ?? const <PlatformFile>[];
      if (files.isEmpty) return;
      var attempted = 0;
      var succeeded = 0;
      String? uploadedFileName;
      for (final f in files) {
        if (!mounted) break;
        setState(
          () => _progressLabel = files.length > 1
              ? '正在上传 ${++attempted}/${files.length}'
              : null,
        );
        final bytes = f.bytes;
        if (bytes == null) {
          if (mounted) context.appError('无法读取「${f.name}」的内容');
          continue;
        }
        final contentType = guessContentType(f.name);
        if (contentType == null) {
          if (mounted) {
            context.appError('「${f.name}」类型不支持（$kAttachmentUploadTypesHint）');
          }
          continue;
        }
        // File identity and original bytes are authoritative. Storage may use
        // lossless compression without changing the uploaded/downloaded file.
        // 上传不带分类：分类改成传完之后在文件旁边可选设置（2026-09-11）。
        try {
          await ref
              .read(attachmentServiceProvider)
              .upload(
                ownerType: widget.ownerType,
                ownerId: widget.ownerId,
                fileName: f.name,
                contentType: contentType,
                bytes: bytes,
              );
          succeeded++;
          uploadedFileName = f.name;
        } catch (e) {
          if (mounted) context.appError('「${f.name}」上传失败：$e');
        }
      }
      if (mounted && succeeded > 0) {
        widget.onChanged();
        final l10n = AppLocalizations.of(context);
        context.appSuccess(
          succeeded == 1
              ? l10n.attachmentUploadedFile(uploadedFileName!)
              : l10n.attachmentUploadedFiles(succeeded),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _view(Attachment a) async {
    if (!_canUse(Perm.attachmentDownload, true)) return;
    final service = ref.read(attachmentServiceProvider);
    try {
      // 2026-09-10 Office 文档：服务端 LibreOffice 转 PDF 后内嵌查看；
      // 服务器未装转换组件/转换失败 → 提示并回落为下载原件。
      if (AttachmentPreviewDialog.isOffice(a.originalName, a.contentType)) {
        Uint8List? pdf;
        try {
          pdf = await service.previewBytes(a);
        } catch (_) {
          pdf = null;
        }
        if (!mounted) return;
        if (pdf != null && pdf.isNotEmpty) {
          await _showPreview(pdf, a.originalName, 'application/pdf');
          return;
        }
        context.appWarning('该文件暂不支持在线预览，已改为下载原件');
      }
      final bytes = await service.downloadBytes(a);
      if (!mounted) return;
      // 图片/PDF/文本点开即看；其余（zip 等）保存落盘。
      final inline =
          !AttachmentPreviewDialog.isOffice(a.originalName, a.contentType) &&
          AttachmentPreviewDialog.canPreview(a.originalName, a.contentType);
      if (inline) {
        await _showPreview(bytes, a.originalName, a.contentType);
      } else {
        final saved = await saveBytes(bytes, a.originalName);
        if (mounted) context.appSuccess('已保存到 $saved');
      }
    } catch (e) {
      if (mounted) context.appError('打开失败：$e');
    }
  }

  Future<void> _showPreview(Uint8List bytes, String name, String? contentType) {
    return showDialog<void>(
      context: context,
      builder: (_) => AttachmentPreviewDialog(
        bytes: bytes,
        name: name,
        contentType: contentType,
      ),
    );
  }

  Future<void> _delete(Attachment a) async {
    if (!_canUse(Perm.attachmentDelete, widget.ownerCanDelete)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除附件？'),
        content: Text('将永久删除「${a.originalName}」。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(attachmentServiceProvider).delete(a.id);
      widget.onChanged();
      if (mounted) context.appSuccess('已删除');
    } catch (e) {
      if (mounted) context.appError('删除失败：$e');
    }
  }

  bool _canUse(String permission, bool ownerAllows) {
    return ownerAllows &&
        ref.read(currentPermissionsProvider).contains(permission);
  }

  /// 按扩展名猜测后端允许的 Content-Type；不在白名单返回 null
  /// （规则集中在 attachment_file_rules.dart，与保存前暂存共用）。
  static String? guessContentType(String name) =>
      guessAttachmentContentType(name);
}

/// 虚线边框容器（上传空态）：轻量 CustomPainter 画圆角虚线框。
class DashedContainer extends StatelessWidget {
  const DashedContainer({
    super.key,
    required this.child,
    this.borderRadius = 12,
  });

  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark
        ? UtenColors.darkBorderStrong
        : UtenColors.borderStrong;
    return CustomPaint(
      foregroundPainter: _DashedBorderPainter(
        color: color,
        radius: borderRadius,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double start = 0;
      while (start < metric.length) {
        canvas.drawPath(
          metric.extractPath(start, start + 5),
          Paint()
            ..color = color
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
        start += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
