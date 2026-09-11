// 新建单据保存成功后的附件收尾：把暂存文件上传到刚拿到的单据 UUID，
// 全部成功才允许页面跳转详情；部分失败则留在当前页（保留失败项）让员工重试。
// 各单据编辑页只需在 create 成功后调用一次，不各自复制上传/提示逻辑。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import 'attachment_service.dart';
import 'pending_attachment_controller.dart';

/// 返回 true 表示可以继续跳转（没有待传文件，或全部上传成功）。
/// 返回 false 表示有文件上传失败，已提示员工，页面应停留并保留失败项。
Future<bool> flushPendingAttachments(
  BuildContext context,
  WidgetRef ref,
  PendingAttachmentController controller, {
  required String ownerType,
  required List<String> ownerIds,
}) async {
  if (controller.isEmpty || ownerIds.isEmpty) return true;
  final report = await controller.flushToOwners(
    ref.read(attachmentServiceProvider),
    ownerType: ownerType,
    ownerIds: ownerIds,
  );
  if (!context.mounted) return false;
  if (report.allSucceeded) {
    if (report.uploadedCount > 0) {
      context.appSuccess(
        ownerIds.length > 1
            ? '已把 ${report.uploadedCount ~/ ownerIds.length} 个附件分别挂到 ${ownerIds.length} 张单据'
            : '已上传 ${report.uploadedCount} 个附件',
      );
    }
    return true;
  }
  context.appError(
    '单据已保存，但 ${report.failedCount} 个附件上传失败，可重试；'
    '也可移除失败文件后再次保存进入详情',
    force: true,
  );
  return false;
}

/// 单据已创建但仍有附件上传失败时，放在暂存区上方的提示：再点「保存」只重试附件。
class PendingAttachmentRetryNotice extends StatelessWidget {
  const PendingAttachmentRetryNotice({super.key, required this.documentLabel});

  final String documentLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      key: const ValueKey('pending-attachment-retry-notice'),
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: dark
            ? UtenColors.warning.withValues(alpha: 0.12)
            : UtenColors.warningBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: UtenColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: dark ? UtenColors.warningOnDark : UtenColors.warningText,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '$documentLabel已创建，仍有附件上传失败：点「保存」重试上传，'
              '或移除失败文件后点「保存」进入详情；此时对单据字段的修改不会再保存。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: dark ? UtenColors.warningOnDark : UtenColors.warningText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
