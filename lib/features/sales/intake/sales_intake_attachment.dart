// 把识别用的客户原文件存进单据附件(分类「客户确认」, ADR-074 / ADR-134):
//  - 新建单(尚无 UUID): 放进页面的暂存附件, 保存拿到 UUID 后随单上传;
//  - 已有草稿: 直接上传到该单据并刷新附件区。
// 与共享附件组件同口径叠加 attachment:upload(没有上传权限时不暂存, 免得保存后卡在补传)。
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/attachments/attachment_file_rules.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/attachments/pending_attachment_controller.dart';
import '../../../shared/auth/permissions.dart';

/// 附件分类(与编辑页附件区的分类词表一致)。
const String kSalesIntakeAttachmentCategory = '客户确认';

enum SalesIntakeAttachOutcome {
  /// 已上传到已有单据。
  uploaded,

  /// 已放进新建单的暂存附件。
  pending,

  /// 不需要或不允许(无上传权限 / 同名同大小已在暂存区)。
  skipped,

  /// 失败(类型不支持、超限或网络错误), 页面提示可手动上传。
  failed,
}

Future<SalesIntakeAttachOutcome> salesIntakeKeepOriginalFile(
  WidgetRef ref, {
  required PlatformFile file,
  required String ownerType,
  required String? documentId,
  required PendingAttachmentController pending,
  required bool canManage,
}) async {
  if (!canManage ||
      !ref.read(currentPermissionsProvider).contains(Perm.attachmentUpload)) {
    return SalesIntakeAttachOutcome.skipped;
  }
  if (documentId == null) {
    final exists = pending.items.any(
      (f) => f.name == file.name && f.sizeBytes == file.size,
    );
    if (exists) return SalesIntakeAttachOutcome.skipped;
    return pending.add(file, category: kSalesIntakeAttachmentCategory) == null
        ? SalesIntakeAttachOutcome.pending
        : SalesIntakeAttachOutcome.failed;
  }
  final bytes = file.bytes;
  final contentType = guessAttachmentContentType(file.name);
  if (bytes == null || contentType == null) {
    return SalesIntakeAttachOutcome.failed;
  }
  try {
    await ref
        .read(attachmentServiceProvider)
        .upload(
          ownerType: ownerType,
          ownerId: documentId,
          fileName: file.name,
          contentType: contentType,
          bytes: bytes,
          category: kSalesIntakeAttachmentCategory,
        );
    ref.invalidate(
      businessAttachmentsProvider((type: ownerType, id: documentId)),
    );
    return SalesIntakeAttachOutcome.uploaded;
  } on Object {
    return SalesIntakeAttachOutcome.failed;
  }
}
