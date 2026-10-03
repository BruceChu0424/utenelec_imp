import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import '../support/controlled_attachment_pipeline.dart';

PendingAttachmentController _pending() =>
    PendingAttachmentController()..restoreDraft({
      'items': [
        for (final name in ['original-1.txt', 'original-2.txt'])
          {'name': name, 'contentType': 'text/plain', 'bytes': 'AQID'},
      ],
    });

void main() {
  for (final stage in ['before', 'presign', 'bytes', 'confirm']) {
    test(
      'identity fence at $stage stops subsequent upload phases and preserves original files',
      () async {
        final pipeline = ControlledAttachmentPipeline(waitAt: stage);
        final pending = _pending();
        addTearDown(pending.dispose);
        var allowed = stage != 'before';
        final result = pending.flushToOwners(
          pipeline.service,
          ownerType: 'PRODUCTION_DAILY_REPORT',
          ownerIds: ['report-1'],
          canContinue: () => allowed,
        );
        if (stage != 'before') {
          await pipeline.entered.future;
          allowed = false;
          pipeline.release.complete();
        }
        final report = await result;
        expect(report.allSucceeded, isFalse);
        expect(pending.items.map((file) => file.name), [
          'original-1.txt',
          'original-2.txt',
        ]);
        expect(
          pending.items.every(
            (file) => file.bytes.toList().join(',') == '1,2,3',
          ),
          isTrue,
        );
        expect(pipeline.requests.length, switch (stage) {
          'before' => 0,
          'presign' => 1,
          'bytes' => 2,
          _ => 3,
        });
        expect(report.uploadedCount, stage == 'confirm' ? 1 : 0);
        expect(
          pending.items.first.uploadedTo,
          stage == 'confirm' ? {'report-1'} : <String>{},
        );
        final restored = PendingAttachmentController()
          ..restoreDraft(pending.exportDraft());
        addTearDown(restored.dispose);
        expect(restored.items.map((file) => file.draftBytes), ['AQID', 'AQID']);
        expect(restored.items.first.uploadedTo, pending.items.first.uploadedTo);
      },
    );
  }
  test(
    'same current scope completes exact native upload pipeline for each pending file',
    () async {
      final pipeline = ControlledAttachmentPipeline(), pending = _pending();
      addTearDown(pending.dispose);
      final result = await pending.flushToOwners(
        pipeline.service,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: ['report-1'],
        canContinue: () => true,
      );
      expect(result.allSucceeded, isTrue);
      expect(result.uploadedCount, 2);
      expect(pending.isEmpty, isTrue);
      expect(pipeline.requests.map((r) => r.path), [
        for (var i = 0; i < 2; i++) ...[
          '/attachments/presign',
          '/attachments/raw/fixture-file',
          '/attachments/confirm',
        ],
      ]);
      final raw = pipeline.requests.where((r) => r.path.contains('/raw/'));
      expect(
        raw.every(
          (r) =>
              r.headers['X-Uten-Attachment-Upload-Token'] ==
              'fixture-upload-token',
        ),
        isTrue,
      );
    },
  );
}
