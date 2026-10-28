part of 'admin_audit_log_detail_test.dart';

Future<Finder> _mountCacheAudit(
  WidgetTester tester,
  _AuditRepository repository, {
  required bool sessions,
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
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: AdminAuditLogPage(),
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

void auditCacheCases() {
  for (final sessions in [false, true]) {
    testWidgets(
      '${sessions ? 'session' : 'event'} cache restores older pages and retires a changed read proof',
      (tester) async {
        final repository = _AuditRepository(
          totalPages: 12,
          sessionTotalPages: 12,
        )..readScopeVersion = 'proof-A';
        final finder = await _mountCacheAudit(
          tester,
          repository,
          sessions: sessions,
        );
        MasterDataTableView<dynamic> table() =>
            tester.widget<MasterDataTableView<dynamic>>(finder);
        final calls = sessions ? repository.sessionCalls : repository.listCalls;
        for (var page = table().currentPage + 1; page <= 8; page++) {
          await Future<void>.sync(() => table().onPageChange!(page));
          await tester.pumpAndSettle();
        }
        final readsBeforeReturn = calls
            .where((call) => call['page'] == 2)
            .length;
        expect(readsBeforeReturn, greaterThanOrEqualTo(1));
        await Future<void>.sync(() => table().onPageChange!(2));
        await tester.pumpAndSettle();
        expect(table().currentPage, 2);
        expect(
          calls.where((call) => call['page'] == 2),
          hasLength(readsBeforeReturn),
        );
        expect(table().items, hasLength(1));
        expect(
          sessions
              ? (table().items.single as AuditSessionSummary).sessionId
              : (table().items.single as AuditLogEntry).id,
          sessions ? '${_AuditRepository.sessionId}-2' : 43,
        );
        expect(calls.last[sessions ? 'snapshotAuditId' : 'snapshotId'], 9001);
        repository.readScopeVersion = 'proof-B';
        await Future<void>.sync(() => table().onPageChange!(11));
        await tester.pumpAndSettle();
        await Future<void>.sync(() => table().onPageChange!(2));
        await tester.pumpAndSettle();
        expect(
          calls.where((call) => call['page'] == 2),
          hasLength(readsBeforeReturn + 1),
        );
        final model = table().paginationRevision as PagedResult<dynamic>;
        expect(model.readScopeVersion, 'proof-B');
        expect(tester.takeException(), isNull);
      },
    );

    for (final silent in [false, true]) {
      testWidgets(
        '${sessions ? 'session' : 'event'} ${silent ? 'silent' : 'foreground'} denial retires cached private rows and waits for retry',
        (tester) async {
          final repository = _AuditRepository(
            totalPages: 100,
            sessionTotalPages: 100,
          );
          final finder = await _mountCacheAudit(
            tester,
            repository,
            sessions: sessions,
          );
          final calls = sessions
              ? repository.sessionCalls
              : repository.listCalls;
          // A compact query header can expose the next one-row page while the
          // fixture scrolls the table into view. Retry must keep that page.
          final visiblePage = tester
              .widget<MasterDataTableView<dynamic>>(finder)
              .currentPage;
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
            await Future<void>.sync(() => table.onPageChange!(90));
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
          final retryPage = silent ? visiblePage : 90;
          final retryPages = [
            retryPage,
            retryPage + 1,
            retryPage + 2,
            if (retryPage > 1) retryPage - 1,
            if (retryPage > 2) retryPage - 2,
          ];
          final snapshotKey = sessions ? 'snapshotAuditId' : 'snapshotId';
          final originalQuery = Map<String, Object?>.of(calls.first)
            ..remove('page')
            ..remove(snapshotKey);
          expect(calls.skip(before + 1), [
            for (var index = 0; index < retryPages.length; index++)
              {
                ...originalQuery,
                'page': retryPages[index],
                snapshotKey: index == 0 ? null : 9001,
              },
          ]);
          expect(
            tester.widget<MasterDataTableView<dynamic>>(finder).currentPage,
            retryPage,
          );
          expect(find.textContaining('审计读取权限已撤销'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
