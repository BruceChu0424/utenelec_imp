// 报销附件/发票区段：列出 + 上传 + 查看 + 删除。
// 可复用于任意 ownerType/ownerId；当前接入报销详情页（ownerType=EXPENSE_CLAIM）。

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
import 'attachment.dart';
import 'attachment_service.dart';

class ExpenseAttachmentSection extends ConsumerStatefulWidget {
  const ExpenseAttachmentSection({
    super.key,
    required this.ownerType,
    required this.ownerId,
    required this.attachments,
    required this.canManage,
    required this.onChanged,
  });

  final String ownerType;
  final String ownerId;
  final List<Attachment> attachments;
  final bool canManage;
  final VoidCallback onChanged;

  @override
  ConsumerState<ExpenseAttachmentSection> createState() =>
      _ExpenseAttachmentSectionState();
}

class _ExpenseAttachmentSectionState
    extends ConsumerState<ExpenseAttachmentSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const UtenSectionHeader(title: '附件 / 发票'),
            if (widget.canManage)
              TextButton.icon(
                onPressed: _busy ? null : _pickAndUpload,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file, size: 18),
                label: Text(_busy ? '上传中…' : '上传'),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (widget.attachments.isEmpty)
          UtenCard(
            child: Text(
              widget.canManage ? '暂无附件，可上传发票照片或 PDF' : '暂无附件',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          UtenCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (int i = 0; i < widget.attachments.length; i++) ...[
                  _row(theme, widget.attachments[i]),
                  if (i < widget.attachments.length - 1)
                    const Divider(height: 1),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(ThemeData theme, Attachment a) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Icon(
        a.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        a.originalName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        _fmtSize(a.sizeBytes),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '查看 / 下载',
            icon: const Icon(Icons.download_outlined, size: 20),
            onPressed: () => _view(a),
          ),
          if (widget.canManage)
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
      onTap: () => _view(a),
    );
  }

  Future<void> _pickAndUpload() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      final files = result?.files ?? const <PlatformFile>[];
      if (files.isEmpty) return;
      final f = files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        if (mounted) context.appError('无法读取文件内容');
        return;
      }
      final contentType = guessContentType(f.name);
      if (contentType == null) {
        if (mounted) context.appError('不支持的文件类型（仅图片/PDF/Office/zip/txt）');
        return;
      }
      await ref
          .read(attachmentServiceProvider)
          .upload(
            ownerType: widget.ownerType,
            ownerId: widget.ownerId,
            fileName: f.name,
            contentType: contentType,
            bytes: bytes,
          );
      widget.onChanged();
      if (mounted) context.appSuccess('已上传 ${f.name}');
    } catch (e) {
      if (mounted) context.appError('上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view(Attachment a) async {
    try {
      if (a.isImage) {
        final Uint8List bytes = await ref
            .read(attachmentServiceProvider)
            .downloadBytes(a);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) =>
              Dialog(child: InteractiveViewer(child: Image.memory(bytes))),
        );
      } else {
        final bytes = await ref
            .read(attachmentServiceProvider)
            .downloadBytes(a);
        final saved = await saveBytes(bytes, a.originalName);
        if (mounted) context.appSuccess('已保存到 $saved');
      }
    } catch (e) {
      if (mounted) context.appError('打开失败：$e');
    }
  }

  Future<void> _delete(Attachment a) async {
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
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'zip' => 'application/zip',
      'txt' => 'text/plain',
      _ => null,
    };
  }
}
