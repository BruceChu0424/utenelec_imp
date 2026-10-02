part of 'production_daily_report_exact_segment_test.dart';

Map<String, dynamic> _createProofBody(
  Map<String, dynamic> body,
  String id, {
  String status = 'COMMITTED',
}) => {
  'status': status,
  'idempotencyKey': body['idempotencyKey'],
  'requestHash': dailyReportCreateRequestHash(body),
  if (status == 'COMMITTED') ...{
    'fullPayloadVersion': 1,
    'fullPayloadHash': dailyReportCreateFullPayloadHash(body),
  },
  if (status != 'UNKNOWN') ...{
    'reportId': id,
    'detail': {
      'id': id,
      'billNo': 'SR-CREATED',
      'status': 0,
      'makerId': 'employee-1',
      'items': <dynamic>[],
    },
  },
};

DioException _createFixtureHttpError(RequestOptions request, int status) =>
    DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: request,
        statusCode: status,
        data: {'code': 'FIXTURE_REJECTED', 'message': 'fixture HTTP $status'},
      ),
    );

Future<void> _prepareRecoveryInput(WidgetTester tester) async {
  final grid = _identityGrid(tester);
  final row = grid.rows.singleWhere((row) => !row.isSubRow)..qty.text = '37';
  row.platformFields.setValue(_identityField, '001');
  for (final child in grid.rows.where(
    (row) => row.isMaterialRow && row.materialEditable,
  )) {
    child.materialUsed.text = '0';
  }
  await _identityState(tester).saveFormDraftNow();
  await tester.pumpAndSettle();
}

class _RejectingDraftStorage extends MemoryFormDraftStorage {
  bool reject = false;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (reject) return false;
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

void registerDailyReportCreateRecoveryTests() {
  for (final outcome in [
    'confirmed',
    'legacy',
    'receipt-422',
    'wrong-id',
    'timeout',
    'create-403',
  ]) {
    testWidgets('R1 actual CREATE frozen body proof boundary: $outcome', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryFormDraftStorage();
      final fake = _IdentityApi()..successfulCreate = outcome != 'timeout';
      if (outcome == 'legacy') fake.receiptStatus = 'LEGACY_UNCONFIRMED';
      if (outcome == 'receipt-422') fake.receiptHttpError = 422;
      if (outcome == 'wrong-id') fake.receiptReportId = 'unrelated';
      if (outcome == 'create-403') fake.createHttpError = 403;
      final env = await _openIdentityPage(tester, storage, fake);
      await _prepareRecoveryInput(tester);
      final before = jsonDecode(storage.records.values.single) as Map;
      expect(
        (before['data'] as Map).containsKey(dailyReportCreateCommandKey),
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(fake.creates, hasLength(1));
      final sent = fake.creates.single;
      final item = (sent['items'] as List).single as Map;
      expect(item['qty'], 37);
      expect(
        (((item['platformFields'] as Map)['cells'] as List).single
            as Map)['value'],
        '001',
      );
      if (outcome == 'confirmed') {
        expect(fake.receiptBodies, [sent]);
        expect(find.text('正式详情 created-report'), findsOneWidget);
        expect(
          find.byKey(const Key('daily-report-open-create-recovery')),
          findsNothing,
        );
      } else {
        final envelope = jsonDecode(storage.records.values.single) as Map;
        final data = envelope['data'] as Map;
        final command = FrozenDailyReportCreate.restore(
          Map<String, dynamic>.from(data[dailyReportCreateCommandKey] as Map),
        );
        expect(command.requestBody, sent);
        expect(command.server, 'https://identity-test.invalid/api');
        expect(command.userId, 'draft-user');
        expect(data['createdReportId'], isNull);
        expect(data[dailyReportCreateStateKey], 'UNKNOWN');
        expect(
          find.byKey(const Key('daily-report-open-create-recovery')),
          findsOneWidget,
        );
        expect(
          _identityGrid(
            tester,
          ).rows.singleWhere((row) => !row.isSubRow).qty.text,
          '37',
        );
        fake.receiptHttpError = null;
        fake.receiptReportId = 'created-report';
        fake.receiptStatus = 'COMMITTED';
        final oldReceiptCount = fake.receiptBodies.length;
        await tester.tap(
          find.byKey(const Key('daily-report-open-create-recovery')),
        );
        await tester.pumpAndSettle();
        expect(fake.creates, hasLength(1));
        expect(fake.receiptBodies.length, oldReceiptCount + 1);
        expect(fake.receiptBodies.last, sent);
        expect(find.text('已确认原提交创建了生产日报'), findsOneWidget);
        final confirmed = jsonDecode(storage.records.values.single) as Map;
        expect((confirmed['data'] as Map)['createdReportId'], 'created-report');
        expect(
          (confirmed['data'] as Map)[dailyReportCreateCommandKey],
          command.toJson(),
        );
        await tester.tap(find.text('返回原页面，保留已确认检查点'));
        await tester.pumpAndSettle();
        expect(find.byType(ProductionDailyReportEditPage), findsOneWidget);
        expect(_identityState(tester).formDraftHasUnknownSubmission, isFalse);
      }
      expect(tester.takeException(), isNull);
      await _closeIdentityPage(tester, env);
    });
  }
  testWidgets(
    'R1 definite CREATE validation remains editable and preserves inputs',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryFormDraftStorage(),
          fake = _IdentityApi()..createHttpError = 422;
      final env = await _openIdentityPage(tester, storage, fake);
      await _prepareRecoveryInput(tester);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(fake.creates, hasLength(1));
      expect(fake.receiptBodies, isEmpty);
      expect(_identityState(tester).formDraftHasUnknownSubmission, isFalse);
      expect(
        find.byKey(const Key('daily-report-open-create-recovery')),
        findsNothing,
      );
      expect(
        _identityGrid(tester).rows.singleWhere((row) => !row.isSubRow).qty.text,
        '37',
      );
      final data =
          (jsonDecode(storage.records.values.single) as Map)['data'] as Map;
      expect(data[dailyReportCreateCommandKey], isNull);
      fake.createHttpError = null;
      fake.successfulCreate = true;
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(fake.creates, hasLength(2));
      expect(fake.receiptBodies, [fake.creates.last]);
      expect(find.text('正式详情 created-report'), findsOneWidget);
      await _closeIdentityPage(tester, env);
    },
  );
  testWidgets(
    'R1 local pre-dispatch persistence failure preserves input and sends nothing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _RejectingDraftStorage(),
          fake = _IdentityApi()..successfulCreate = true;
      final env = await _openIdentityPage(tester, storage, fake);
      await _prepareRecoveryInput(tester);
      final original = Map<String, String>.from(storage.records);
      storage.reject = true;
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(fake.creates, isEmpty);
      expect(fake.receiptBodies, isEmpty);
      expect(
        _identityGrid(tester).rows.singleWhere((r) => !r.isSubRow).qty.text,
        '37',
      );
      expect(storage.records, original);
      expect(tester.takeException(), isNull);
      storage.reject = false;
      await _closeIdentityPage(tester, env);
    },
  );
  for (final changed in ['permission-aba', 'user-aba', 'server-aba']) {
    testWidgets(
      'R1 actual attachment $changed blocks bytes/confirm and keeps both originals',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = MemoryFormDraftStorage(),
            fake = _IdentityApi()..successfulCreate = true;
        final pipeline = ControlledAttachmentPipeline(waitAt: 'presign');
        final env = await _openIdentityPage(
          tester,
          storage,
          fake,
          attachments: pipeline.service,
        );
        await _prepareRecoveryInput(tester);
        final allowed = {
          ...env.container.read(_identityPermissions),
          Perm.attachmentUpload,
          Perm.productionDailyReportEdit,
        };
        env.container.read(_identityPermissions.notifier).state = allowed;
        await tester.pumpAndSettle();
        final pending = tester
            .widgetList<BusinessAttachmentSection>(
              find.byType(BusinessAttachmentSection),
            )
            .firstWhere((section) => section.isDraft)
            .draftController!;
        pending.restoreDraft({
          'items': [
            for (final name in ['one.txt', 'two.txt'])
              {
                'localUploadId': 'fresh-$name',
                'uploadTrackingVersion': 1,
                'name': name,
                'contentType': 'text/plain',
                'bytes': 'AQID',
              },
          ],
        });
        await _identityState(tester).saveFormDraftNow();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        for (var i = 0; i < 30 && !pipeline.entered.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(pipeline.entered.isCompleted, isTrue);
        switch (changed) {
          case 'permission-aba':
            env.container.read(_identityPermissions.notifier).state = {
              Perm.productionDailyReportView,
            };
            await tester.pump();
            env.container.read(_identityPermissions.notifier).state = allowed;
          case 'user-aba':
            env.container.read(_identityScope.notifier).state =
                const AuthenticatedScope(userId: 'other');
            await tester.pump();
            env.container.read(_identityScope.notifier).state =
                const AuthenticatedScope(userId: 'draft-user');
          case 'server-aba':
            env.container.read(_identityServer.notifier).state =
                'https://other.invalid/api';
            await tester.pump();
            env.container.read(_identityServer.notifier).state =
                'https://identity-test.invalid/api';
        }
        await tester.pump();
        pipeline.release.complete();
        await tester.pumpAndSettle();
        expect(fake.creates, hasLength(1));
        expect(fake.receiptBodies, hasLength(1));
        expect(pipeline.requests.map((r) => r.path), ['/attachments/presign']);
        expect(pending.items.map((file) => file.draftBytes), ['AQID', 'AQID']);
        expect(pending.items.every((file) => file.uploadedTo.isEmpty), isTrue);
        final saved = jsonDecode(storage.records.values.single) as Map;
        final data = saved['data'] as Map;
        expect(((data['attachments'] as Map)['items'] as List), hasLength(2));
        expect(data['createdReportId'], 'created-report');
        expect(tester.takeException(), isNull);
        await _closeIdentityPage(tester, env);
      },
    );
  }
  testWidgets(
    'R1 no current view permission cannot dispatch an unverifiable CREATE',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryFormDraftStorage(),
          fake = _IdentityApi()..successfulCreate = true;
      final env = await _openIdentityPage(tester, storage, fake);
      await _prepareRecoveryInput(tester);
      env.container.read(_identityPermissions.notifier).state = {
        Perm.productionDailyReportCreate,
      };
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(fake.creates, isEmpty);
      expect(fake.receiptBodies, isEmpty);
      expect(
        _identityGrid(tester).rows.singleWhere((r) => !r.isSubRow).qty.text,
        '37',
      );
      expect(tester.takeException(), isNull);
      await _closeIdentityPage(tester, env);
    },
  );
}
