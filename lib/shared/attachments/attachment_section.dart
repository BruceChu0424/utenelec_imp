// 通用附件区段：列出 + 上传 + 预览/下载 + 删除。
// 可复用于任意 ownerType/ownerId；接入方：员工详情「档案文件」（EMPLOYEE）、
// 合同附件弹窗（EMPLOYEE_CONTRACT）、报销详情（EXPENSE_CLAIM）、我的文件（EMPLOYEE 只读）。
// 调用方只表达 owner/state 是否允许上传或删除；组件统一叠加 attachment:upload/delete。
// 预览和下载统一使用 attachment:download；对象范围由后端 AttachmentOwnerAccessPolicy 终审。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/io/file_saver.dart';
import '../../components/cards/uten_card.dart';
import '../../components/layout/uten_section_header.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../core/utils/china_datetime.dart';
import '../auth/permissions.dart';
import 'attachment.dart';
import 'attachment_image_compressor.dart';
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

  /// 文档分类（员工档案：合同/身份证件/学历证书/照片/其他）。为 null 时不显示分类筛选。
  /// 筛选芯片同时决定上传默认归入的分类（选「全部」时归第一个分类）。
  final List<String>? categories;

  /// 把图片附件设为头像（仅员工档案用；为 null 时不显示该按钮）。
  final void Function(Attachment)? onSetAvatar;

  @override
  ConsumerState<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends ConsumerState<AttachmentSection> {
  bool _busy = false;
  String? _progressLabel; // 上传进度文案（多文件时显示「正在上传 2/3」）
  String? _filterCategory; // 分类筛选（仅 categories 非 null 时使用；null = 全部）

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canDownload = permissions.contains(Perm.attachmentDownload);
    final canUpload =
        widget.ownerCanUpload && permissions.contains(Perm.attachmentUpload);
    final canDelete =
        widget.ownerCanDelete && permissions.contains(Perm.attachmentDelete);
    final visible = _filtered;
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
        if (widget.categories != null && widget.attachments.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            children: [
              _filterChip(theme, null, '全部', widget.attachments.length),
              for (final c in widget.categories!)
                _filterChip(
                  theme,
                  c,
                  c,
                  widget.attachments.where((a) => a.category == c).length,
                ),
            ],
          ),
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

  Widget _filterChip(ThemeData theme, String? value, String label, int count) {
    final selected = _filterCategory == value;
    return ChoiceChip(
      label: Text(count > 0 ? '$label $count' : label),
      selected: selected,
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
                      '支持图片 / PDF / Office / zip，单个不超过 25MB；图片自动压缩存储',
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
            Text(
              hint ?? widget.emptyHint ?? '暂无附件',
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
    Attachment a, {
    required bool canDownload,
    required bool canDelete,
  }) {
    final type = _FileType.of(a);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: _typeIcon(theme, type),
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
          if (a.category != null) ...[
            const SizedBox(width: UtenSpacing.s8),
            _categoryTag(theme, a.category!),
          ],
          if (a.avatar) ...[
            const SizedBox(width: UtenSpacing.s4),
            _categoryTag(theme, '头像', highlighted: true),
          ],
        ],
      ),
      subtitle: Text(
        [
          _fmtSize(a.sizeBytes),
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
              tooltip: a.isImage ? '预览' : '下载',
              icon: Icon(
                a.isImage ? Icons.visibility_outlined : Icons.download_outlined,
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

  /// 分类/头像小标签：胶囊形，浅底深字，不打断文件名阅读。
  Widget _categoryTag(
    ThemeData theme,
    String label, {
    bool highlighted = false,
  }) {
    final color = highlighted ? theme.colorScheme.primary : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (color ?? theme.colorScheme.onSurfaceVariant).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color ?? theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 文件类型图标：彩色圆角方块 + 白色图标，一眼区分图片/文档/表格/压缩包。
  Widget _typeIcon(ThemeData theme, _FileType type) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: type.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(type.icon, size: 19, color: type.color),
    );
  }

  List<Attachment> get _filtered {
    final c = _filterCategory;
    if (c == null || widget.categories == null) return widget.attachments;
    return widget.attachments.where((a) => a.category == c).toList();
  }

  Future<void> _pickAndUpload() async {
    if (_busy || !_canUse(Perm.attachmentUpload, widget.ownerCanUpload)) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      final files = result?.files ?? const <PlatformFile>[];
      if (files.isEmpty) return;
      final category = widget.categories == null
          ? null
          : (_filterCategory ?? widget.categories!.first);
      var attempted = 0;
      var succeeded = 0;
      String? lastCompressNote;
      for (final f in files) {
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
        var contentType = guessContentType(f.name);
        if (contentType == null) {
          if (mounted) {
            context.appError('「${f.name}」类型不支持(仅图片/PDF/Office/zip/txt)');
          }
          continue;
        }
        // 图片先压缩再上传（长边≤1920 / JPEG q85；小图与 GIF 原样保留）
        var uploadBytes = bytes;
        var uploadName = f.name;
        final compressed = await AttachmentImageCompressor.process(
          bytes: bytes,
          fileName: f.name,
          contentType: contentType,
        );
        if (compressed.compressed) {
          uploadBytes = compressed.bytes;
          uploadName = compressed.fileName;
          contentType = compressed.contentType;
          lastCompressNote =
              '图片已压缩 ${_fmtSize(compressed.originalSize ?? 0)}'
              ' → ${_fmtSize(uploadBytes.length)}';
        }
        try {
          await ref
              .read(attachmentServiceProvider)
              .upload(
                ownerType: widget.ownerType,
                ownerId: widget.ownerId,
                fileName: uploadName,
                contentType: contentType,
                bytes: uploadBytes,
                category: category,
              );
          succeeded++;
        } catch (e) {
          if (mounted) context.appError('「${f.name}」上传失败：$e');
        }
      }
      if (succeeded > 0) widget.onChanged();
      if (mounted && succeeded > 0) {
        final note = lastCompressNote == null ? '' : '($lastCompressNote)';
        context.appSuccess(
          succeeded == 1
              ? '已上传 ${files.first.name}$note'
              : '已上传 $succeeded 个文件$note',
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
    try {
      final bytes = await ref.read(attachmentServiceProvider).downloadBytes(a);
      if (!mounted) return;
      if (a.isImage) {
        await showDialog<void>(
          context: context,
          builder: (_) =>
              _ImagePreviewDialog(bytes: bytes, name: a.originalName),
        );
      } else {
        final saved = await saveBytes(bytes, a.originalName);
        if (mounted) context.appSuccess('已保存到 $saved');
      }
    } catch (e) {
      if (mounted) context.appError('打开失败：$e');
    }
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

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  /// 按扩展名猜测后端允许的 Content-Type；不在白名单返回 null。
  static String? guessContentType(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'zip' => 'application/zip',
      'txt' => 'text/plain',
      _ => null,
    };
  }
}

/// 图片预览弹窗：可缩放拖动，附文件名与「保存到本机」。
class _ImagePreviewDialog extends StatelessWidget {
  const _ImagePreviewDialog({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                maxScale: 5,
                // cacheWidth 限制解码目标宽度：防高分辨率证件扫描图在预览时整图解码吃满内存
                //（服务端已限 40MP，这里再压一档；放大到 5x 时略微变软属可接受权衡）。
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 2048,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('保存到本机'),
                    onPressed: () async {
                      final saved = await saveBytes(bytes, name);
                      if (context.mounted) {
                        context.appSuccess('已保存到 $saved');
                        Navigator.pop(context);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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

/// 文件类型 → 图标与主色。颜色固定取品牌外的功能色，深浅色模式均以 14% 透明度做底。
enum _FileType {
  image(Icons.image_rounded, Color(0xFF8B5CF6)),
  pdf(Icons.picture_as_pdf_rounded, Color(0xFFEF4444)),
  word(Icons.description_rounded, Color(0xFF3B82F6)),
  excel(Icons.table_view_rounded, Color(0xFF22C55E)),
  zip(Icons.folder_zip_rounded, Color(0xFFF59E0B)),
  text(Icons.article_rounded, Color(0xFF64748B)),
  other(Icons.insert_drive_file_outlined, Color(0xFF64748B));

  const _FileType(this.icon, this.color);

  final IconData icon;
  final Color color;

  static _FileType of(Attachment a) {
    final ct = a.contentType?.toLowerCase() ?? '';
    final name = a.originalName.toLowerCase();
    if (ct.startsWith('image/')) return image;
    if (ct.contains('pdf') || name.endsWith('.pdf')) return pdf;
    if (ct.contains('word') ||
        ct.contains('msword') ||
        name.endsWith('.doc') ||
        name.endsWith('.docx')) {
      return word;
    }
    if (ct.contains('excel') ||
        ct.contains('spreadsheet') ||
        name.endsWith('.xls') ||
        name.endsWith('.xlsx')) {
      return excel;
    }
    if (ct.contains('zip') || name.endsWith('.zip')) return zip;
    if (ct.startsWith('text/')) return text;
    return other;
  }
}
