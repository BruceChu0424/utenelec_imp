part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportLateAttachmentAckTests() {
  for (final outcome in [
    'committed',
    'deleted',
    'renamed',
    'wrong-hash',
    'missing-hash',
    'wrong-actor',
    'missing',
    'forbidden',
    'other-server',
    'wrong-key',
    'no-attachment-view',
    'cas-conflict',
    'view-revoked-during-query',
  ]) {
    testWidgets(
      'lateACK real CREATE upload commit restart readonly receipt: $outcome',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = MemoryFormDraftStorage(),
            fake = _IdentityApi()..successfulCreate = true;
        final pipeline = ControlledAttachmentPipeline(
          waitAt: 'confirm',
          uniqueKeys: true,
        );
        var env = await _openIdentityPage(
          tester,
          storage,
          fake,
          attachments: pipeline.service,
        );
        await _prepareRecoveryInput(tester);
        env.container.read(_identityPermissions.notifier).state = {
          Perm.productionDailyReportCreate,
          Perm.productionDailyReportView,
          Perm.productionDailyReportEdit,
          Perm.attachmentView,
          Perm.attachmentUpload,
        };
        await tester.pumpAndSettle();
        final pending = tester
            .widgetList<BusinessAttachmentSection>(
              find.byType(BusinessAttachmentSection),
            )
            .firstWhere((section) => section.isDraft)
            .draftController!;
        pending.restoreDraft({
          'items': [
            {
              'localUploadId': 'late-file-1',
              'uploadTrackingVersion': 1,
              'name': 'original.txt',
              'contentType': 'text/plain',
              'bytes': 'AQID',
            },
          ],
        });
        await _identityState(tester).saveFormDraftNow();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        for (var i = 0; i < 40 && !pipeline.entered.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(pipeline.entered.isCompleted, isTrue);
        expect(pipeline.committed, hasLength(1));
        final original = jsonDecode(storage.records.values.single) as Map;
        final draftId = original['id'] as String;
        final durableFile =
            (((original['data'] as Map)['attachments'] as Map)['items'] as List)
                    .single
                as Map;
        expect(
          (durableFile['uploadAttempts'] as Map).containsKey('created-report'),
          isTrue,
        );
        expect(durableFile['uploadedTo'], isEmpty);
        env.container.read(_identityScope.notifier).state =
            const AuthenticatedScope(userId: 'other');
        await tester.pump();
        await _closeIdentityPage(tester, env);
        pipeline.release.complete();
        await tester.pump();
        await tester.pump();
        final writes = pipeline.requests.where((r) => r.method != 'GET').length;
        final committed = Map<String, dynamic>.from(pipeline.committed.single);
        switch (outcome) {
          case 'deleted':
            pipeline.committed.single['deleted'] = true;
          case 'renamed':
            pipeline.committed.single['originalName'] = '合法后改名.txt';
            pipeline.committed.single['contentType'] =
                'application/octet-stream';
          case 'wrong-hash':
            pipeline.committed.single['sha256'] = 'b' * 64;
          case 'missing-hash':
            pipeline.committed.single['sha256'] = null;
          case 'wrong-key':
            pipeline.committed.single['storageKey'] =
                'another-upload-with-same-content';
          case 'wrong-actor':
            pipeline.committed.single['uploadedBy'] = 'other-user';
          case 'missing':
            pipeline.committed.clear();
          case 'forbidden':
            pipeline.historyErrorStatus = 403;
        }
        final beforeViewRevocation = outcome == 'view-revoked-during-query'
            ? Map<String, String>.from(storage.records)
            : null;
        final holdHistory =
            outcome == 'cas-conflict' || outcome == 'view-revoked-during-query';
        if (holdHistory) pipeline.historyGate = Completer<void>();
        env = await _openIdentityPage(
          tester,
          storage,
          fake,
          attachments: pipeline.service,
          location:
              '/production/daily-reports/create-recovery?draftId=$draftId',
          initialPermissions: {
            Perm.productionDailyReportView,
            if (outcome != 'no-attachment-view') Perm.attachmentView,
          },
          settle: !holdHistory,
          initialServer: outcome == 'other-server'
              ? 'https://other.invalid/api'
              : null,
        );
        if (holdHistory) {
          // Advance the route/async scheduling clock until the real native GET
          // reaches its held response; zero-duration frames never complete it.
          for (var i = 0; i < 50 && !pipeline.historyEntered.isCompleted; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(pipeline.historyEntered.isCompleted, isTrue);
          if (outcome == 'cas-conflict') {
            final key = storage.records.keys.single;
            final newer = Map<String, dynamic>.from(
              jsonDecode(storage.records[key]!) as Map,
            );
            newer['revision'] = 'newer-private-revision';
            storage.records[key] = jsonEncode(newer);
          } else {
            env.container.read(_identityPermissions.notifier).state = {
              Perm.productionDailyReportView,
            };
            // Production permissions.dart:723 derives permissions from session;
            // session_snapshot_provider.dart:143-149 then reloads Me. The
            // independent permission fixture must reproduce that same epoch.
            env.container.invalidate(sessionSnapshotProvider);
            await tester.pump();
          }
          pipeline.historyGate!.complete();
        }
        await tester.pumpAndSettle();
        expect(fake.creates, hasLength(1));
        expect(
          pipeline.requests.where((r) => r.method != 'GET').length,
          writes,
        );
        final saved = jsonDecode(storage.records.values.single) as Map;
        final file =
            (((saved['data'] as Map)['attachments'] as Map)['items'] as List)
                    .single
                as Map;
        expect(file['bytes'], 'AQID');
        expect(file['uploadAttempts'], durableFile['uploadAttempts']);
        if (outcome == 'view-revoked-during-query') {
          expect(
            storage.records,
            beforeViewRevocation,
            reason:
                'A revoked reader cannot write a child receipt or mutate any draft bytes.',
          );
        }
        final confirmed = ['committed', 'deleted', 'renamed'].contains(outcome);
        expect(file['uploadedTo'], confirmed ? ['created-report'] : <String>[]);
        if (confirmed) {
          expect(
            (file['confirmedAttachmentIds'] as Map)['created-report'],
            committed['id'],
          );
          if (outcome == 'deleted') {
            expect(file['confirmedDeletedOwners'], ['created-report']);
            expect(find.text('继续处理待上传附件'), findsNothing);
          }
        }
        expect(
          pipeline.historyCalls,
          ['other-server', 'no-attachment-view'].contains(outcome) ? 0 : 1,
        );
        expect(tester.takeException(), isNull);
        await _closeIdentityPage(tester, env);
      },
    );
  }
}
