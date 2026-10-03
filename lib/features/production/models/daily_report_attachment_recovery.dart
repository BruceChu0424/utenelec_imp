import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/server_config.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../../../shared/attachments/attachment_upload_attempt.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import 'production_daily_report_create_request.dart';

class DailyReportAttachmentRecovery {
  const DailyReportAttachmentRecovery(
    this.draft,
    this.confirmed,
    this.unknown,
    this.deleted,
  );
  final FormDraft draft;
  final int confirmed, unknown, deleted;
}

/// Resolve only exact immutable upload identities through the authorized native
/// history GET. Missing/legacy/mismatched receipts never trigger another upload.
Future<DailyReportAttachmentRecovery> recoverDailyReportAttachments(
  WidgetRef ref,
  FormDraft draft,
  bool Function() accepts,
) async {
  final permissions = ref.read(currentPermissionsProvider);
  if (!accepts() || !permissions.contains(Perm.productionDailyReportView)) {
    throw StateError('当前无附件查看权限，原附件继续保留');
  }
  final scope = ref.read(authenticatedScopeProvider);
  final command = FrozenDailyReportCreate.restore(
    Map<String, dynamic>.from(draft.data[dailyReportCreateCommandKey] as Map),
  );
  final parent = draft.data[dailyReportCreateReceiptKey];
  final id = draft.data['createdReportId'];
  if (scope == null ||
      scope.readOnly ||
      !command.belongsTo(
        server: ref.read(apiBaseUrlProvider),
        userId: scope.userId,
        actorId: scope.actorId,
      ) ||
      parent is! Map ||
      id is! String ||
      id.isEmpty ||
      parent['status'] != 'COMMITTED' ||
      parent['fullPayloadVersion'] is! int ||
      parent['fullPayloadVersion'] != 1 ||
      parent['reportId'] != id ||
      parent['idempotencyKey'] != command.idempotencyKey ||
      parent['requestHash'] != command.requestHash ||
      parent['fullPayloadHash'] != command.fullPayloadHash) {
    throw StateError('原父单证明或账号范围尚未核对');
  }
  final identity = AttachmentUploadIdentity(
    server: command.server,
    userId: command.userId,
    actorId: command.actorId,
    parentProofHash: command.fullPayloadHash,
  );
  final rawAttachments = draft.data['attachments'];
  final items = rawAttachments is Map && rawAttachments['items'] is List
      ? (rawAttachments['items'] as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList()
      : <Map<String, dynamic>>[];
  final unresolved = items
      .where((item) => !(item['uploadedTo'] as List? ?? const []).contains(id))
      .toList();
  if (unresolved.isEmpty) {
    return DailyReportAttachmentRecovery(draft, 0, 0, 0);
  }
  if (!unresolved.any(
    (item) =>
        item['uploadAttempts'] is Map &&
        (item['uploadAttempts'] as Map).containsKey(id),
  )) {
    return DailyReportAttachmentRecovery(draft, 0, unresolved.length, 0);
  }
  if (!permissions.contains(Perm.attachmentView)) {
    throw StateError('当前无附件查看权限，原附件保留');
  }
  final native = await ref
      .read(attachmentServiceProvider)
      .listHistory(ownerType: 'PRODUCTION_DAILY_REPORT', ownerId: id);
  if (!accepts() ||
      ref.read(authenticatedScopeProvider) != scope ||
      !ref.read(currentPermissionsProvider).contains(Perm.attachmentView)) {
    throw StateError('核对附件期间查看范围已变化');
  }
  final receipts = <Map<String, dynamic>>[];
  var deleted = 0;
  for (final item in unresolved) {
    final attempts = item['uploadAttempts'];
    if (attempts is! Map ||
        attempts[id] is! Map ||
        item['localUploadId'] is! String) {
      continue;
    }
    final attempt = AttachmentUploadAttempt.restore(
      Map<String, dynamic>.from(attempts[id] as Map),
    );
    if (!attempt.belongsTo(identity) ||
        attempt.ownerId != id ||
        attempt.data['ownerType'] != 'PRODUCTION_DAILY_REPORT' ||
        !attempt.matchesFile(
          name: item['name'] as String,
          contentType: item['contentType'] as String,
          bytes: base64Decode(item['bytes'] as String),
        )) {
      continue;
    }
    final matches = native
        .where((row) => row.storageKey == attempt.storageKey)
        .toList();
    if (matches.length != 1 || !attempt.matchesNativeReceipt(matches.single)) {
      continue;
    }
    final row = matches.single;
    if (row.deleted) {
      deleted++;
    }
    receipts.add({
      'localUploadId': item['localUploadId'],
      'id': row.id,
      'ownerType': row.ownerType,
      'ownerId': row.ownerId,
      'storageKey': row.storageKey,
      'originalName': row.originalName,
      'contentType': row.contentType,
      'sizeBytes': row.sizeBytes,
      'uploadedBy': row.uploadedBy,
      'sha256': row.sha256,
      'deleted': row.deleted,
    });
  }
  final saved = receipts.isEmpty
      ? draft
      : await ref
            .read(formDraftsProvider.notifier)
            .confirmDailyReportAttachmentRecovery(
              draft.id,
              expectedRevision: draft.revision,
              receipts: receipts,
            );
  if (!accepts()) {
    throw StateError('核对附件期间身份已变化');
  }
  return DailyReportAttachmentRecovery(
    saved,
    receipts.length,
    unresolved.length - receipts.length,
    deleted,
  );
}
