import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/performance/responsive_data_codec.dart';
import '../../../shared/attachments/attachment.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../repositories/company_file_repository.dart';
import 'company_file.dart';
import 'company_file_access_draft.dart';

enum CompanyFileUploadState {
  waiting,
  uploading,
  verifying,
  done,
  failed,
  unknown,
  stopped,
}

/// A service outage or uncertain receipt fences the rest of a batch. A known
/// per-file rejection can be corrected without blocking unrelated files.
Future<void> sendCompanyFileUploadQueue({
  required List<CompanyFileUpload> attempts,
  required CompanyFileRepository repository,
  required AttachmentService attachments,
  required AuthenticatedRequestScope scope,
  required String? Function(CompanyFileUpload attempt) parentIdOf,
  required bool Function() shouldStop,
  required void Function() onChanged,
}) async {
  try {
    for (final file in attempts) {
      if (shouldStop()) break;
      scope.checkCurrent();
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: parentIdOf(file),
        onChanged: onChanged,
      );
      final error = file.error;
      if (file.state == CompanyFileUploadState.unknown ||
          error is ApiException &&
              (isSessionBoundaryError(error) ||
                  {401, 403, 404, 429, 507}.contains(error.httpStatus) ||
                  (error.httpStatus ?? 0) >= 500)) {
        break;
      }
    }
  } finally {
    for (final file in attempts) {
      if (file.state == CompanyFileUploadState.waiting) {
        file.state = CompanyFileUploadState.stopped;
      }
    }
    onChanged();
  }
}

/// Kept for the lifetime of the queue, including interrupted confirmations.
/// A retry reconciles this exact owner and hash before sending another object.
class CompanyFileUpload {
  CompanyFileUpload({
    required this.name,
    required this.bytes,
    required this.contentType,
    this.entry,
    this.initialAccess,
  }) : requestId = const Uuid().v4();
  final String name;
  final Uint8List bytes;
  final String contentType;
  final String requestId;
  CompanyFile? entry;
  // Retained only until the reservation is acknowledged (including uncertain
  // retries), so the idempotency fingerprint always describes the same command.
  CompanyFileInitialAccessDraft? initialAccess;
  PresignResult? presign;
  Attachment? confirmed;
  CompanyFileUploadState state = CompanyFileUploadState.waiting;
  Object? error;
  bool reservationUnknown = false;
  String? _checksum;

  bool get complete => state == CompanyFileUploadState.done;

  Future<void> send({
    required CompanyFileRepository repository,
    required AttachmentService attachments,
    required AuthenticatedRequestScope scope,
    required String? parentId,
    required void Function() onChanged,
  }) async {
    error = null;
    state = CompanyFileUploadState.uploading;
    onChanged();
    try {
      scope.checkCurrent();
      final checksum = _checksum ??= await sha256HexResponsive(
        bytes,
        isCurrent: () => scope.isCurrent,
      );
      if (entry == null) {
        try {
          entry = await scope.run(
            () => repository.reserveFile(
              parentId: parentId,
              name: name,
              requestId: requestId,
              access: initialAccess,
            ),
          );
          reservationUnknown = false;
          initialAccess = null;
        } catch (e) {
          reservationUnknown = _uncertain(e);
          rethrow;
        }
      } else {
        // Refresh the same physical entry, including its optimistic revision.
        entry = await scope.run(() => repository.get(entry!.id));
        if (!entry!.pending && entry!.attachmentId != null) {
          state = CompanyFileUploadState.done;
          onChanged();
          return;
        }
      }
      scope.checkCurrent();
      final owner = entry!;
      final history = await scope.run(
        () => attachments.listHistory(
          ownerType: 'COMPANY_FILE',
          ownerId: owner.id,
        ),
      );
      scope.checkCurrent();
      confirmed =
          history
              .where(
                (a) =>
                    !a.deleted &&
                    a.sha256 == checksum &&
                    a.sizeBytes == bytes.length,
              )
              .firstOrNull ??
          confirmed;
      // A raw PUT/confirm may have succeeded even if its response was lost.
      // Reusing its confirm token asks the server for that exact receipt.
      if (confirmed == null && presign != null) {
        state = CompanyFileUploadState.verifying;
        onChanged();
        try {
          confirmed = await scope.run(
            () => attachments.confirm(
              storageKey: presign!.storageKey,
              confirmToken: presign!.confirmToken,
              ownerType: 'COMPANY_FILE',
              ownerId: owner.id,
              originalName: name,
              contentType: contentType,
              sizeBytes: bytes.length,
            ),
          );
        } catch (e) {
          // Only an explicit server rejection permits a new upload attempt.
          // A timeout cannot prove that the prior confirmation did not commit.
          if (_uncertain(e) || isSessionBoundaryError(e)) rethrow;
          presign = null;
        }
      }
      scope.checkCurrent();
      if (confirmed == null) {
        state = CompanyFileUploadState.uploading;
        onChanged();
        presign = await scope.run(
          () => attachments.presign(
            ownerType: 'COMPANY_FILE',
            ownerId: owner.id,
            fileName: name,
            contentType: contentType,
            sizeBytes: bytes.length,
          ),
        );
        scope.checkCurrent();
        await scope.run(() => attachments.uploadBytes(presign!, bytes));
        scope.checkCurrent();
        state = CompanyFileUploadState.verifying;
        onChanged();
        confirmed = await scope.run(
          () => attachments.confirm(
            storageKey: presign!.storageKey,
            confirmToken: presign!.confirmToken,
            ownerType: 'COMPANY_FILE',
            ownerId: owner.id,
            originalName: name,
            contentType: contentType,
            sizeBytes: bytes.length,
          ),
        );
      }
      scope.checkCurrent();
      state = CompanyFileUploadState.verifying;
      onChanged();
      entry = await scope.run(() => repository.complete(entry!, confirmed!.id));
      // An acknowledged write remains acknowledged if the session changes.
      state = CompanyFileUploadState.done;
    } catch (e) {
      error = e;
      state = _uncertain(e) || reservationUnknown
          ? CompanyFileUploadState.unknown
          : CompanyFileUploadState.failed;
      if (isSessionBoundaryError(e)) rethrow;
    } finally {
      onChanged();
    }
  }

  static bool _uncertain(Object e) =>
      e is! ApiException ||
      !e.hasResponseCode ||
      e.httpStatus == null ||
      e.httpStatus! >= 500;
}
