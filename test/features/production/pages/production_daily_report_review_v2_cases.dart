part of 'production_daily_report_detail_approve_test.dart';

void registerDailyReportReviewV2Cases() {
  testWidgets(
    'approval session fence rejects a changed intent during confirmation',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval();
          server.includeReceipt = true;
          return null;
        },
      );
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      (api.container.read(sessionProvider.notifier) as _ApprovalSession)
          .intentEpoch++;
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.approveKeys, isEmpty);
      expect(api.approvalStorage.records, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'approval session fence preserves unknown original key when intent changes after dispatch',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (server) {
          (server.container.read(sessionProvider.notifier) as _ApprovalSession)
              .intentEpoch++;
          return NetworkTimeoutException();
        },
      );
      await _tapApprove(tester);
      expect(api.approveKeys, hasLength(1));
      expect(api.receiptReads, 0);
      final pending =
          jsonDecode(api.approvalStorage.records.values.single) as Map;
      expect(pending['idempotencyKey'], api.approveKeys.single);
      expect(pending['phase'], 'DISPATCHED');
      expect(tester.takeException(), isNull);
    },
  );
  if (Platform.environment['UTEN_CAPTURE_DAILY_REPORT_V2'] == 'true') {
    for (final mobile in [false, true]) {
      testWidgets('V2 visual unknown receipt ${mobile ? '375' : '1440'}', (
        tester,
      ) async {
        await loadAuditScreenshotFonts(tester);
        final capture = GlobalKey();
        final (api, _) = await _pump(
          tester,
          capability: 2,
          captureKey: capture,
          size: mobile ? const Size(375, 844) : const Size(1440, 1000),
          dark: !mobile,
          textScale: 1.5,
          onApprove: (server) {
            server.serverStatus = 1;
            return NetworkTimeoutException();
          },
        );
        await _tapApprove(tester);
        expect(
          find.byKey(const Key('daily-report-resolve-approval')),
          findsOneWidget,
        );
        expect(api.approvalStorage.records, hasLength(1));
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          capture,
          'daily-report-v2-unknown-${mobile ? '375-light' : '1440-dark'}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
  const saved = DailyReportApprovalIntent(
    reportId: 'dr-1',
    idempotencyKey: 'original-v2-key',
    commandVersion: 2,
    expectedVersion: 0,
    confirmation: '原来核对的 1000 只',
    billNo: 'SR20260922000005',
  );
  String storageKey() =>
      'daily_report_approval_${formDraftStoragePrefix('https://daily-report.example/api', const AuthenticatedScope(userId: 'daily-report-tester'))}dr-1';
  MemoryCasStorage seeded({bool prepared = false, bool legacy = false}) {
    final storage = MemoryCasStorage();
    storage.records[storageKey()] = jsonEncode({
      ...saved.toJson(),
      if (legacy) 'commandVersion': 1,
      if (legacy) 'expectedVersion': null,
      if (!legacy) 'phase': prepared ? 'PREPARED' : 'DISPATCHED',
    });
    return storage;
  }

  void noSuccess(_DailyReportApi api) => expect(
    api.notifications.where(
      (notice) => notice.kind == AppNotificationKind.success,
    ),
    isEmpty,
  );

  testWidgets('V2 real version zero is sent with an attributable receipt', (
    tester,
  ) async {
    final (api, notices) = await _pump(
      tester,
      capability: 2,
      onApprove: (server) {
        server.serverStatus = 1;
        server.rememberApproval();
        server.includeReceipt = true;
        return null;
      },
    );
    await _tapApprove(tester);
    expect(api.approveBodies.single['commandVersion'], 2);
    expect(api.approveBodies.single['expectedVersion'], 0);
    expect(notices, contains('已审核'));
    expect(api.approvalStorage.records, isEmpty);
    expect(api.receiptReads, 0);
  });

  for (final version in <Object?>[null, -1, '0', 0.5]) {
    testWidgets(
      'V2 missing or malformed seen version blocks approval: $version',
      (tester) async {
        final (api, _) = await _pump(
          tester,
          capability: 2,
          omitVersion: version == null,
          versionOverride: version,
          onApprove: (_) => null,
        );
        expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
        expect(
          find.byKey(const Key('daily-report-review-reload')),
          findsOneWidget,
        );
        expect(api.approveBodies, isEmpty);
      },
    );
  }

  testWidgets(
    'confirmation freezes one detail even when a refresh changes quantity and version',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (_) => ApiException(
          'DAILY_REPORT_REVIEW_VERSION_CONFLICT',
          '日报已变化',
          httpStatus: 409,
        ),
      );
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenReviewerResponsibilityNotice), findsOneWidget);
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .toList();
      api.rowVersion = 1;
      api.quantity = 700;
      api.container.read(pageRefreshRequestProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(api.detailReads, 2);
      expect(
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data)
            .toList(),
        texts,
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies.single['expectedVersion'], 0);
      expect(api.approvalStorage.records, isEmpty);
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      noSuccess(api);
    },
  );

  testWidgets(
    'V2 lost response is settled by its original receipt before returning',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        capability: 2,
        fromWorkshop: true,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval();
          return NetworkTimeoutException();
        },
      );
      await _tapApprove(tester);
      expect(api.receiptReads, 1);
      expect(api.approveBodies, hasLength(1));
      expect(notices, contains('原审核已登记'));
      expect(find.text('已回车间任务'), findsOneWidget);
      expect(api.approvalStorage.records, isEmpty);
    },
  );

  for (final lookupFails in [false, true]) {
    testWidgets(
      'approved GET without original receipt stays unknown: lookupFails=$lookupFails',
      (tester) async {
        final (api, _) = await _pump(
          tester,
          capability: 2,
          fromWorkshop: true,
          onApprove: (server) {
            server.serverStatus = 1;
            if (lookupFails) server.receiptFailure = NetworkTimeoutException();
            return NetworkTimeoutException();
          },
        );
        await _tapApprove(tester);
        expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
        expect(
          find.byKey(const Key('daily-report-resolve-approval')),
          findsOneWidget,
        );
        expect(api.approvalStorage.records, hasLength(1));
        expect(api.approveBodies, hasLength(1));
        expect(find.widgetWithText(UtenButton, '红冲'), findsNothing);
        noSuccess(api);
      },
    );
  }

  for (final verified in [false, true]) {
    testWidgets(
      'legacy 2xx draft requires actual receipt to settle: verified=$verified',
      (tester) async {
        final (api, _) = await _pump(
          tester,
          onApprove: (server) {
            if (verified) {
              server.rememberApproval();
              server.includeReceipt = true;
            }
            return null;
          },
        );
        await _tapApprove(tester);
        expect(api.approvalStorage.records.length, verified ? 0 : 1);
        expect(
          find.byKey(const Key('daily-report-resolve-approval')),
          verified ? findsNothing : findsOneWidget,
        );
        noSuccess(api);
        expect(api.approveBodies.single.containsKey('expectedVersion'), false);
      },
    );
  }

  testWidgets(
    'V2 meeting historical V1 receipt explicitly reports no reviewed-version protection',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        capability: 2,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval();
          server.receipt!['commandVersion'] = null;
          server.receipt!['reviewedVersion'] = null;
          return ApiException(
            'DAILY_REPORT_LEGACY_APPROVAL_RECEIPT',
            '旧版审核记录',
            httpStatus: 409,
          );
        },
      );
      await _tapApprove(tester);
      expect(notices, contains('原审核按旧版规则登记，未验证所见版本；请以当前记录为准。'));
      expect(api.approvalStorage.records, isEmpty);
      noSuccess(api);
    },
  );

  testWidgets(
    'old unknown V1 record remains lookup-only after server upgrades to V2',
    (tester) async {
      final storage = seeded(legacy: true);
      final raw = storage.records.values.single;
      final (api, _) = await _pump(
        tester,
        capability: 2,
        storage: storage,
        onApprove: (_) => null,
      );
      api.rowVersion = 7;
      await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
      await tester.pumpAndSettle();
      expect(api.approveBodies, isEmpty);
      expect(api.receiptReads, 1);
      expect(storage.records.values.single, raw);
      expect(
        find.byKey(const Key('daily-report-retry-original-approval')),
        findsNothing,
      );
    },
  );

  testWidgets('durable intent failure sends zero approvals', (tester) async {
    final (api, notices) = await _pump(
      tester,
      capability: 2,
      onApprove: (_) => null,
    );
    api.approvalStorage.failWrites = true;
    await _tapApprove(tester);
    expect(api.approveBodies, isEmpty);
    expect(notices.any((text) => text.contains('本次未发送审核')), true);
    noSuccess(api);
  });

  testWidgets(
    'confirmed response with local cleanup failure never exposes business retry',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval();
          server.includeReceipt = true;
          server.approvalStorage.failWrites = true;
          return null;
        },
      );
      await _tapApprove(tester);
      expect(find.widgetWithText(UtenButton, '清理已核对记录'), findsOneWidget);
      expect(
        find.byKey(const Key('daily-report-retry-original-approval')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
      await tester.pumpAndSettle();
      expect(api.approveBodies, hasLength(1));
      api.approvalStorage.failWrites = false;
      await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
      await tester.pumpAndSettle();
      expect(api.approvalStorage.records, isEmpty);
      expect(api.approveBodies, hasLength(1));
    },
  );

  testWidgets(
    'covering route after confirmation closes clears same-owner confirmation busy',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        fromWorkshop: true,
        onApprove: (_) => null,
      );
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      final dialogContext = tester.element(
        find.widgetWithText(FilledButton, '确认审核'),
      );
      final navigator = Navigator.of(dialogContext);
      final dialogRoute = ModalRoute.of(dialogContext)!;
      unawaited(api.router!.push<void>('/cover'));
      await tester.pumpAndSettle();
      navigator.removeRoute(dialogRoute, true);
      await tester.pumpAndSettle();
      expect(api.approveBodies, isEmpty);
      api.router!.pop();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '确认审核'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'cover during prepared persistence cancels only unsent intent and permits re-review',
    (tester) async {
      final gate = Completer<void>();
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        onApprove: (_) => null,
      );
      api.approvalStorage.writeGate = gate.future;
      await _tapApprove(tester, settle: false);
      unawaited(api.router!.push<void>('/cover'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.approveBodies, isEmpty);
      expect(api.approvalStorage.records, isEmpty);
      api.router!.pop();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
    },
  );

  testWidgets(
    'prepared record across reopening is cancelled before fresh review, never replayed as unknown',
    (tester) async {
      final storage = seeded(prepared: true);
      final (api, _) = await _pump(
        tester,
        capability: 2,
        storage: storage,
        onApprove: (_) => null,
      );
      api.rowVersion = 3;
      await tester.tap(find.widgetWithText(UtenButton, '重新核对审核'));
      await tester.pumpAndSettle();
      expect(storage.records, isEmpty);
      expect(api.approveBodies, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies.single['expectedVersion'], 3);
      expect(
        api.approveBodies.single['idempotencyKey'],
        isNot('original-v2-key'),
      );
    },
  );

  testWidgets(
    'reopened dispatched V2 retries original body after current version changes',
    (tester) async {
      final storage = seeded();
      final (api, _) = await _pump(
        tester,
        capability: 2,
        storage: storage,
        onApprove: (_) => ApiException(
          'VALIDATION_FAILED',
          '后续拒绝不能抹去此前未知结果',
          httpStatus: 422,
        ),
      );
      api.rowVersion = 7;
      api.container.read(pageRefreshRequestProvider.notifier).state++;
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('daily-report-retry-original-approval')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('原来核对的 1000 只'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies.single, {
        'idempotencyKey': 'original-v2-key',
        'commandVersion': 2,
        'expectedVersion': 0,
      });
      expect(storage.records, hasLength(1));
      noSuccess(api);
    },
  );

  for (final change in ['scope', 'server', 'route']) {
    testWidgets(
      'late V2 success cannot publish or navigate across $change fence',
      (tester) async {
        final gate = Completer<void>();
        final (api, _) = await _pump(
          tester,
          capability: 2,
          fromWorkshop: true,
          commandGate: gate,
          onApprove: (server) {
            server.serverStatus = 1;
            server.rememberApproval();
            server.includeReceipt = true;
            return null;
          },
        );
        await _tapApprove(tester, settle: false);
        final original = Map<String, String>.from(api.approvalStorage.records);
        if (change == 'scope') {
          api.container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'other-user',
          );
        }
        if (change == 'server') {
          api.container.read(_server.notifier).state =
              'https://other.example/api';
        }
        if (change == 'route') unawaited(api.router!.push<void>('/cover'));
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(api.approveBodies, hasLength(1));
        expect(api.approvalStorage.records, original);
        expect(find.text('已回车间任务'), findsNothing);
        noSuccess(api);
        if (change == 'route') expect(find.text('覆盖页面'), findsOneWidget);
      },
    );
  }

  for (final change in ['scope', 'server']) {
    testWidgets(
      'leaving and returning to the same $change does not revive an old response',
      (tester) async {
        final gate = Completer<void>();
        final (api, _) = await _pump(
          tester,
          capability: 2,
          commandGate: gate,
          onApprove: (server) {
            server.serverStatus = 1;
            server.rememberApproval();
            server.includeReceipt = true;
            return null;
          },
        );
        await _tapApprove(tester, settle: false);
        final original = Map<String, String>.from(api.approvalStorage.records);
        if (change == 'scope') {
          api.container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'other-user',
          );
          await tester.pump();
          api.container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'daily-report-tester',
          );
        } else {
          api.container.read(_server.notifier).state =
              'https://other.example/api';
          await tester.pump();
          api.container.read(_server.notifier).state =
              'https://daily-report.example/api';
        }
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        noSuccess(api);
        expect(api.approvalStorage.records, original);
        expect(find.text('登录身份或服务器已变化，请重新读取这张日报。'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'unknown command survives real disposal and reopen with original body',
    (tester) async {
      final (oldApi, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (_) => NetworkTimeoutException(),
      );
      await _tapApprove(tester);
      final oldBody = Map<String, dynamic>.from(oldApi.approveBodies.single);
      final storage = oldApi.approvalStorage;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final (newApi, _) = await _pump(
        tester,
        capability: 2,
        storage: storage,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval(replay: true);
          server.includeReceipt = true;
          return null;
        },
      );
      newApi.rowVersion = 8;
      newApi.container.read(pageRefreshRequestProvider.notifier).state++;
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('daily-report-retry-original-approval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
      await tester.pumpAndSettle();
      expect(newApi.approveBodies.single, oldBody);
      expect(storage.records, isEmpty);
      expect(newApi.notifications.map((n) => n.message), contains('原审核已登记'));
    },
  );

  testWidgets(
    'real route factory replaces state for another report while old approval is in flight',
    (tester) async {
      final gate = Completer<void>();
      final (api, _) = await _pump(
        tester,
        capability: 2,
        fromWorkshop: true,
        commandGate: gate,
        onApprove: (server) {
          server.serverStatus = 1;
          server.rememberApproval();
          server.includeReceipt = true;
          return null;
        },
      );
      final oldState = tester.state(
        find.byType(ProductionDailyReportDetailPage),
      );
      await _tapApprove(tester, settle: false);
      final original = Map<String, String>.from(api.approvalStorage.records);
      api.router!.go('/report/dr-2?from=workshop-tasks');
      await tester.pumpAndSettle();
      final newPage = tester.widget<ProductionDailyReportDetailPage>(
        find.byType(ProductionDailyReportDetailPage),
      );
      expect(newPage.id, 'dr-2');
      expect(
        identical(
          oldState,
          tester.state(find.byType(ProductionDailyReportDetailPage)),
        ),
        false,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.approvalStorage.records, original);
      expect(
        tester
            .widget<ProductionDailyReportDetailPage>(
              find.byType(ProductionDailyReportDetailPage),
            )
            .id,
        'dr-2',
      );
      expect(find.text('已回车间任务'), findsNothing);
      noSuccess(api);
    },
  );

  testWidgets(
    'current approval permission withdrawal keeps unknown and restoration reuses original',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 2,
        onApprove: (_) => NetworkTimeoutException(),
      );
      await _tapApprove(tester);
      final body = Map<String, dynamic>.from(api.approveBodies.single);
      final raw = api.approvalStorage.records.values.single;
      api.approvable = false;
      api.container.read(pageRefreshRequestProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('daily-report-retry-original-approval')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
      await tester.pumpAndSettle();
      expect(api.approvalStorage.records.values.single, raw);
      api.approvable = true;
      api.container.read(pageRefreshRequestProvider.notifier).state++;
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('daily-report-retry-original-approval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies, [body, body]);
    },
  );

  for (final status in [400, 422, 500]) {
    testWidgets(
      'unknown then $status with receipt and detail reads failing never loses original',
      (tester) async {
        final storage = seeded();
        final (api, _) = await _pump(
          tester,
          capability: 2,
          storage: storage,
          onApprove: (server) {
            server.receiptFailure = NetworkTimeoutException();
            server.readFailure = NetworkTimeoutException();
            return ApiException(
              status == 400
                  ? 'BUSINESS'
                  : status == 422
                  ? 'VALIDATION_FAILED'
                  : 'INTERNAL',
              '后续请求失败',
              httpStatus: status,
            );
          },
        );
        await tester.tap(
          find.byKey(const Key('daily-report-retry-original-approval')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
        await tester.pumpAndSettle();
        expect(api.approveBodies.single['idempotencyKey'], 'original-v2-key');
        expect(api.approveBodies.single['expectedVersion'], 0);
        expect(
          (jsonDecode(storage.records.values.single)
              as Map<String, dynamic>)['idempotencyKey'],
          'original-v2-key',
        );
        expect(
          find.byKey(const Key('daily-report-resolve-approval')),
          findsOneWidget,
        );
        noSuccess(api);
      },
    );
  }
}
