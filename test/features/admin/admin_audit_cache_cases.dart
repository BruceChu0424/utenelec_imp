part of 'admin_audit_log_detail_test.dart';

Future<Finder> _mountCacheAudit(
  WidgetTester tester,
  _AuditRepository repository, {
  required bool sessions,
  double zoom = 1,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeePickerDepartmentTreeProvider.overrideWith(
          (ref) async => _auditDepartmentTree,
        ),
        auditLogRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        builder: (_, child) =>
            UtenDisplayZoomBox(fontFactor: zoom, child: child!),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const AdminAuditLogPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _selectDefaultAuditScope(tester, eventView: !sessions);
  final table = find.byKey(
    Key(sessions ? 'audit-session-table' : 'audit-event-table'),
  );
  await _scrollAuditPageUntilBuilt(tester, table);
  return table;
}

Future<void> _resumeCacheAudit(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(AdminAuditLogPage)),
  );
  final resume = container.read(pageResumeProvider.notifier);
  bumpPageResumeState(resume, RouteName.adminAuditLogs);
  await tester.pump();
  bumpPageResumeState(resume, '/audit-test-detail');
  await tester.pump();
  bumpPageResumeState(resume, RouteName.adminAuditLogs);
}

Future<void> _waitForAuditCalls(
  WidgetTester tester,
  List<Object?> calls,
  int count,
) async {
  for (var frame = 0; frame < 100 && calls.length < count; frame++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(calls, hasLength(count));
}

void auditCacheCases() {
  for (final sessions in [false, true]) {
    testWidgets(
      '${sessions ? 'session' : 'event'} successful same-query empty replacement releases the old real controller rows',
      (tester) async {
        final repository = _AuditRepository(
          totalPages: 3,
          sessionTotalPages: 3,
        );
        final finder = await _mountCacheAudit(
          tester,
          repository,
          sessions: sessions,
        );
        final table = tester.widget<MasterDataTableView<dynamic>>(finder);
        final controller = table.rowsController!;
        expect(controller.items, hasLength(3));
        final proof = readWindowBindingOf(table.items)!;
        repository.highWaterMark = 9301;
        if (sessions) {
          repository.emptyCurrentSessions = true;
        } else {
          repository.emptyCurrentEvents = true;
        }
        final refresh = tester.widget<UtenAppBarActionButton>(
          find.byWidgetPredicate(
            (widget) =>
                widget is UtenAppBarActionButton && widget.label == '刷新',
          ),
        );
        final refreshed = Completer<void>();
        unawaited(
          Future<void>.sync(
            refresh.onPressed!,
          ).whenComplete(refreshed.complete),
        );
        for (var frame = 0; frame < 1000 && !refreshed.isCompleted; frame++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(refreshed.isCompleted, isTrue);
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        try {
          expect(finder, findsNothing);
          expect(controller.items, isEmpty);
          expect(proof.empty, isTrue);
          final export = tester.widget<UtenExportButton>(
            find.byType(UtenExportButton),
          );
          expect(export.queryParams['snapshotId'], 9301);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  for (final sessions in [false, true]) {
    testWidgets(
      '${sessions ? 'session' : 'event'} latest continuation denial retires real rows and every accepted owner',
      (tester) async {
        final repository = _AuditRepository(
          totalPages: 3,
          sessionTotalPages: 3,
        );
        final finder = await _mountCacheAudit(
          tester,
          repository,
          sessions: sessions,
        );
        final table = tester.widget<MasterDataTableView<dynamic>>(finder);
        final controller = table.rowsController!;
        final proof = readWindowBindingOf(table.items)!;
        final calls = sessions ? repository.sessionCalls : repository.listCalls;
        final gates = sessions
            ? repository.sessionPageGates
            : repository.eventPageGates;
        final tail = Completer<void>();
        gates[2] = tail;
        final before = calls.length;
        try {
          table.onRetry!();
          await _waitForAuditCalls(tester, calls, before + 2);
          expect(controller.items, hasLength(3));
          expect(proof.isCurrent, isTrue);
          tail.completeError(
            ApiException('FORBIDDEN', '审计读取权限已撤销', httpStatus: 403),
          );
          await tester.pumpAndSettle();
          expect(controller.items, isEmpty);
          expect(proof.isCurrent, isFalse);
          expect(finder, findsNothing);
          expect(find.textContaining('审计读取权限已撤销'), findsOneWidget);
          await tester.pump(const Duration(seconds: 1));
          expect(calls, hasLength(before + 2));
          expect(tester.takeException(), isNull);
        } finally {
          if (!tail.isCompleted) {
            tail.completeError(NetworkException('fixture cleanup'));
          }
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets(
      '${sessions ? 'session' : 'event'} query ABA cannot revive an old owner or publish held first-HWM responses',
      (tester) async {
        final repository = _HeaderAuditRepository(
          totalPages: 3,
          sessionTotalPages: 3,
        );
        final finder = await _mountCacheAudit(
          tester,
          repository,
          sessions: sessions,
        );
        MasterDataTableView<dynamic> table() =>
            tester.widget<MasterDataTableView<dynamic>>(finder);
        final oldProof = readWindowBindingOf(table().items)!;
        final controller = table().rowsController!;
        final change = table().onFilterChanged;
        final calls = sessions ? repository.sessionCalls : repository.listCalls;
        final gates = sessions
            ? repository.sessionPageGates
            : repository.eventPageGates;
        final oldA = Completer<void>(), pendingB = Completer<void>();
        final before = calls.length;
        try {
          gates[1] = oldA;
          repository.highWaterMark = 9051;
          await _resumeCacheAudit(tester);
          await _waitForAuditCalls(tester, calls, before + 1);
          gates[1] = pendingB;
          repository.highWaterMark = 9101;
          change('search.device', 'B');
          await _waitForAuditCalls(tester, calls, before + 2);
          repository.highWaterMark = 9201;
          change('search.device', null);
          await tester.pumpAndSettle();
          expect(controller.items, hasLength(3));
          final accepted = table().paginationRevision;
          expect(
            sessions
                ? (accepted as AuditSessionPage).snapshotAuditId
                : (accepted as AuditLogPage).snapshotId,
            9201,
          );
          expect(oldProof.isCurrent, isFalse);
          final firstOwners = sessions
              ? repository.firstSessionOwners
              : repository.firstEventOwners;
          expect(
            firstOwners
                .take(firstOwners.length - 1)
                .every((owner) => owner != null && !owner()),
            isTrue,
          );
          expect(firstOwners.last!(), isTrue);
          final currentProof = readWindowBindingOf(table().items)!;
          expect(currentProof.isCurrent, isTrue);
          final count = calls.length;
          expect(count, before + 5);
          oldA.complete();
          pendingB.complete();
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pumpAndSettle();
          expect(
            calls,
            hasLength(count),
            reason:
                'Retired initial HWM reads cannot request their later pages.',
          );
          expect(table().paginationRevision, same(accepted));
          expect(oldProof.isCurrent, isFalse);
          expect(currentProof.isCurrent, isTrue);
          expect(controller.items, hasLength(3));
          if (!sessions) {
            expect(repository.summaryCalls.last['snapshotId'], 9201);
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (!oldA.isCompleted) oldA.complete();
          if (!pendingB.isCompleted) pendingB.complete();
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  for (final sessions in [false, true]) {
    for (final silent in [false, true]) {
      testWidgets(
        '${sessions ? 'session' : 'event'} same-query ${silent ? 'resume' : 'refresh'} keeps real authorized rows while a new HWM tail is pending and offline',
        (tester) async {
          final repository = _AuditRepository(
            totalPages: 3,
            sessionTotalPages: 3,
          );
          final finder = await _mountCacheAudit(
            tester,
            repository,
            sessions: sessions,
          );
          MasterDataTableView<dynamic> table() =>
              tester.widget<MasterDataTableView<dynamic>>(finder);
          final original = table().items;
          final controller = table().rowsController!;
          final proof = readWindowBindingOf(original)!;
          final calls = sessions
              ? repository.sessionCalls
              : repository.listCalls;
          final key = sessions ? 'snapshotAuditId' : 'snapshotId';
          final tail = Completer<void>();
          final gates = sessions
              ? repository.sessionPageGates
              : repository.eventPageGates;
          gates[2] = tail;
          repository.highWaterMark = 9101;
          final before = calls.length;
          try {
            if (silent) {
              final container = ProviderScope.containerOf(
                tester.element(find.byType(AdminAuditLogPage)),
              );
              final resume = container.read(pageResumeProvider.notifier);
              bumpPageResumeState(resume, RouteName.adminAuditLogs);
              await tester.pump();
              bumpPageResumeState(resume, '/audit-test-detail');
              await tester.pump();
              bumpPageResumeState(resume, RouteName.adminAuditLogs);
            } else {
              final refresh = tester.widget<UtenAppBarActionButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is UtenAppBarActionButton && widget.label == '刷新',
                ),
              );
              unawaited(Future<void>.sync(refresh.onPressed!));
            }
            for (
              var frame = 0;
              frame < 100 && calls.length < before + 2;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 1));
            }
            expect(calls.length, before + 2);
            final firstOwners = sessions
                ? repository.firstSessionOwners
                : repository.firstEventOwners;
            expect(
              firstOwners.last,
              isNotNull,
              reason:
                  'The first HWM HTTP read belongs to the same cancellable query owner.',
            );
            expect(firstOwners.last!(), isTrue);
            // A normal resize must not rebuild the same authorized table as empty.
            tester.view.physicalSize = const Size(1210, 900);
            await tester.pump(const Duration(milliseconds: 1));
            expect(controller.items, hasLength(3));
            expect(proof.isCurrent, isTrue);
            expect(table().items, same(original));
            final revision = table().paginationRevision;
            expect(
              sessions
                  ? (revision as AuditSessionPage).snapshotAuditId
                  : (revision as AuditLogPage).snapshotId,
              9001,
            );
            expect(
              find.descendant(
                of: finder,
                matching: find.text(sessions ? '测试电脑' : '修改生产执行分段：状态由已就绪改为已下达'),
              ),
              findsWidgets,
            );
            expect(calls.skip(before).first[key], isNull);
            expect(calls.last[key], 9101);
            expect(
              tester
                  .widget<UtenExportButton>(find.byType(UtenExportButton))
                  .enabled,
              isFalse,
            );
            tail.completeError(NetworkException('controlled tail offline'));
            await tester.pumpAndSettle();
            expect(controller.items, hasLength(3));
            expect(proof.isCurrent, isTrue);
            expect(table().items, same(original));
            expect(calls, hasLength(before + 2));
            repository.highWaterMark = 9201;
            table().onRetry!();
            await tester.pumpAndSettle();
            expect(controller.items, hasLength(3));
            final accepted = table().paginationRevision;
            expect(
              sessions
                  ? (accepted as AuditSessionPage).snapshotAuditId
                  : (accepted as AuditLogPage).snapshotId,
              9201,
            );
            final retried = calls.skip(before + 2).toList();
            expect(retried.map((call) => call['page']), [1, 2, 3]);
            expect(retried.first[key], isNull);
            expect(retried.skip(1).every((call) => call[key] == 9201), isTrue);
            if (!sessions) {
              expect(repository.summaryCalls.last['snapshotId'], 9201);
            }
            expect(tester.takeException(), isNull);
          } finally {
            if (!tail.isCompleted) {
              tail.completeError(NetworkException('fixture cleanup'));
            }
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }

  for (final sessions in [false, true]) {
    testWidgets(
      '${sessions ? 'session' : 'event'} complete snapshot revalidates all rows and a new read proof on explicit refresh',
      (tester) async {
        final repository = _AuditRepository(totalPages: 3, sessionTotalPages: 3)
          ..readScopeVersion = 'proof-A';
        final finder = await _mountCacheAudit(
          tester,
          repository,
          sessions: sessions,
        );
        MasterDataTableView<dynamic> table() =>
            tester.widget<MasterDataTableView<dynamic>>(finder);
        final calls = sessions ? repository.sessionCalls : repository.listCalls;
        expect(calls.map((call) => call['page']), [1, 2, 3]);
        expect(table().items, hasLength(3));
        expect(
          (table().paginationRevision as PagedResult).readScopeVersion,
          'proof-A',
        );
        repository.readScopeVersion = 'proof-B';
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(calls.map((call) => call['page']), [1, 2, 3, 1, 2, 3]);
        expect(table().items, hasLength(3));
        expect(
          (table().paginationRevision as PagedResult).readScopeVersion,
          'proof-B',
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final silent in [false, true]) {
      testWidgets(
        '${sessions ? 'session' : 'event'} ${silent ? 'silent' : 'foreground'} denial retires cached private rows and waits for retry',
        (tester) async {
          final repository = _AuditRepository(
            totalPages: 3,
            sessionTotalPages: 3,
          );
          final finder = await _mountCacheAudit(
            tester,
            repository,
            sessions: sessions,
          );
          final calls = sessions
              ? repository.sessionCalls
              : repository.listCalls;
          final before = calls.length;
          final error = ApiException('FORBIDDEN', '审计读取权限已撤销', httpStatus: 403);
          if (sessions) {
            repository.nextSessionError = error;
          } else {
            repository.nextEventError = error;
          }
          if (silent) {
            final container = ProviderScope.containerOf(
              tester.element(find.byType(AdminAuditLogPage)),
            );
            final resume = container.read(pageResumeProvider.notifier);
            bumpPageResumeState(resume, RouteName.adminAuditLogs);
            await tester.pumpAndSettle();
            bumpPageResumeState(resume, '/audit-test-detail');
            await tester.pumpAndSettle();
            bumpPageResumeState(resume, RouteName.adminAuditLogs);
          } else {
            final table = tester.widget<MasterDataTableView<dynamic>>(finder);
            table.onRetry!();
          }
          await tester.pumpAndSettle();
          expect(finder, findsNothing);
          expect(find.textContaining('审计读取权限已撤销'), findsOneWidget);
          expect(calls, hasLength(before + 1));
          await tester.pump(const Duration(seconds: 1));
          expect(
            calls,
            hasLength(before + 1),
            reason: 'confirmed denial cannot create an automatic reread loop',
          );
          await tester.tap(find.text('重试').first);
          await tester.pumpAndSettle();
          expect(finder, findsOneWidget);
          final rereads = calls.skip(before + 1).toList();
          expect(rereads.map((call) => call['page']), [1, 2, 3]);
          final key = sessions ? 'snapshotAuditId' : 'snapshotId';
          expect(rereads.first[key], isNull);
          expect(rereads.skip(1).every((call) => call[key] == 9001), true);
          expect(
            tester.widget<MasterDataTableView<dynamic>>(finder).items,
            hasLength(3),
          );
          expect(find.textContaining('审计读取权限已撤销'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
