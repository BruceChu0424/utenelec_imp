import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment_upload_attempt.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import '../support/controlled_attachment_pipeline.dart';

const _identity = AttachmentUploadIdentity(
  server: 'https://original.invalid/api',
  userId: 'draft-user',
  actorId: null,
  parentProofHash:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);
PendingAttachmentController _pending() =>
    PendingAttachmentController()..restoreDraft({
      'items': [
        {
          'localUploadId': 'file-1',
          'uploadTrackingVersion': 1,
          'name': 'original.txt',
          'contentType': 'text/plain',
          'bytes': 'AQID',
        },
      ],
    });
void main() {
  test(
    'unique attempt is durably checkpointed before bytes and binds the original hash/scope',
    () async {
      final pipeline = ControlledAttachmentPipeline(uniqueKeys: true),
          pending = _pending();
      addTearDown(pending.dispose);
      final checkpointEntered = Completer<void>(),
          allowSave = Completer<void>();
      String? durable;
      final result = pending.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => true,
        uploadIdentity: _identity,
        persistCheckpoint: () async {
          durable = jsonEncode(pending.exportDraft());
          checkpointEntered.complete();
          await allowSave.future;
        },
      );
      await checkpointEntered.future;
      expect(pipeline.requests.map((r) => r.path), ['/attachments/presign']);
      final restored = PendingAttachmentController()
        ..restoreDraft(Map<String, dynamic>.from(jsonDecode(durable!) as Map));
      addTearDown(restored.dispose);
      final original = restored.items.single.uploadAttempts['report-1']!;
      expect(original.belongsTo(_identity), isTrue);
      expect(original.storageKey, 'fixture-file-1');
      expect(
        original.matchesFile(
          name: 'original.txt',
          contentType: 'text/plain',
          bytes: restored.items.single.bytes,
        ),
        isTrue,
      );
      allowSave.complete();
      expect((await result).allSucceeded, isTrue);
      expect(pipeline.committed, hasLength(1));
      expect(pipeline.committed.single['sha256'], original.data['fileSha256']);
    },
  );
  test(
    'failed local checkpoint sends no bytes and never creates a second attempt automatically',
    () async {
      final pipeline = ControlledAttachmentPipeline(uniqueKeys: true),
          pending = _pending();
      addTearDown(pending.dispose);
      Future<void> failed() async => throw StateError('storage CAS rejected');
      final first = await pending.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => true,
        uploadIdentity: _identity,
        persistCheckpoint: failed,
      );
      expect(first.allSucceeded, isFalse);
      expect(pending.items.single.draftBytes, 'AQID');
      await pending.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => true,
        uploadIdentity: _identity,
        persistCheckpoint: failed,
      );
      expect(pipeline.requests.map((r) => r.path), ['/attachments/presign']);
      expect(pipeline.committed, isEmpty);
    },
  );
  test(
    'confirm committed before lost response survives disposal as an immutable attempt, never a retry',
    () async {
      final pipeline = ControlledAttachmentPipeline(
            waitAt: 'confirm',
            uniqueKeys: true,
          ),
          pending = _pending();
      var current = true;
      late String durable;
      final result = pending.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => current,
        uploadIdentity: _identity,
        persistCheckpoint: () async {
          durable = jsonEncode(pending.exportDraft());
        },
      );
      await pipeline.entered.future;
      expect(pipeline.committed, hasLength(1));
      current = false;
      pending.dispose();
      pipeline.release.complete();
      expect((await result).allSucceeded, isFalse);
      final restored = PendingAttachmentController()
        ..restoreDraft(Map<String, dynamic>.from(jsonDecode(durable) as Map));
      addTearDown(restored.dispose);
      expect(restored.items.single.uploadedTo, isEmpty);
      expect(restored.needsReceiptFor('report-1'), isTrue);
      final calls = pipeline.requests.length;
      await restored.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => true,
        uploadIdentity: _identity,
        persistCheckpoint: () async {},
      );
      expect(pipeline.requests.length, calls);
      final native = await pipeline.service.listHistory(
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerId: 'report-1',
      );
      expect(
        restored.items.single.uploadAttempts['report-1']!.matchesNativeReceipt(
          native.single,
        ),
        isTrue,
      );
      expect(pipeline.committed, hasLength(1));
    },
  );
  test(
    'readonly acknowledgement cannot replace another revision of the local original files',
    () {
      final pending = _pending();
      addTearDown(pending.dispose);
      final checkpoint = pending.exportDraft();
      final file = (checkpoint['items'] as List).single as Map;
      file['uploadedTo'] = ['report-1'];
      file['confirmedAttachmentIds'] = {'report-1': 'attachment-1'};
      expect(pending.sameOriginalFiles(checkpoint), isTrue);
      file['bytes'] = 'BAUG';
      expect(pending.sameOriginalFiles(checkpoint), isFalse);
      expect(pending.items.single.draftBytes, 'AQID');
    },
  );
}
