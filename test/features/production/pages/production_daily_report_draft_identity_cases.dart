part of 'production_daily_report_exact_segment_test.dart';

final _identityScope = StateProvider<AuthenticatedScope>(
  (_) => const AuthenticatedScope(userId: 'draft-user'),
);
final _identityServer = StateProvider<String>(
  (_) => 'https://identity-test.invalid/api',
);
final _identityPermissions = StateProvider<Set<String>>(
  (_) => {Perm.productionDailyReportCreate, Perm.productionDailyReportView},
);

class _IdentityReaderSession extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: ref.watch(_identityScope).userId,
      code: 'draft-user',
      name: '原提交读者',
    ),
  );
}

const _identityField = PlatformColumnDefinition(
  id: 'batch-ref',
  scope: 'production_daily_report_item',
  name: '外部批号',
);

class _IdentityApi {
  final materialCounts = <String, int>{'segment-1': 1};
  final creates = <Map<String, dynamic>>[];
  final valueQueries = <List<String>>[];
  int detailReads = 0;
  bool failDetail = false;
  bool successfulCreate = false;
  int? createHttpError;
  int? receiptHttpError;
  String receiptStatus = 'COMMITTED';
  String receiptReportId = 'created-report';
  final receiptBodies = <Map<String, dynamic>>[];
  late final api = _api(
    sourceOverrides: const {'planId': 'plan-1', 'maxReportQty': 100},
    onCreate: creates.add,
    responseOverride: (request) {
      if (request.method == 'POST' &&
          request.path.endsWith('/daily-reports') &&
          (successfulCreate || createHttpError != null)) {
        creates.add(Map<String, dynamic>.from(request.data as Map));
        if (createHttpError != null) {
          return _createFixtureHttpError(request, createHttpError!);
        }
        return {
          'id': 'created-report',
          'billNo': 'SR-CREATED',
          'status': 0,
          'makerId': 'employee-1',
          'items': <dynamic>[],
        };
      }
      if (request.path.endsWith('/daily-reports/create-receipt')) {
        final body = Map<String, dynamic>.from(request.data as Map);
        receiptBodies.add(body);
        if (receiptHttpError != null) {
          return _createFixtureHttpError(request, receiptHttpError!);
        }
        return _createProofBody(body, receiptReportId, status: receiptStatus);
      }
      if (request.method == 'GET' &&
          request.path.endsWith('/daily-reports/created-report')) {
        return {
          'id': 'created-report',
          'billNo': 'SR-CREATED',
          'status': 0,
          'makerId': 'employee-1',
          'items': <Object?>[],
        };
      }
      if (request.path.endsWith('/material-usage-sources')) {
        return [
          {
            'executionSegmentId': request.queryParameters['executionSegmentId'],
            'sourcePlanId': 'plan-1',
            'canOpen': true,
            'canSettle': true,
            'shared': false,
          },
        ];
      }
      if (request.path.endsWith('/clearance')) {
        final segment =
            request.queryParameters['executionSegmentId'] as String?;
        return [
          for (var i = 0; i < (materialCounts[segment] ?? 0); i++)
            {
              'planId': 'plan-1',
              'demandId': '$segment-material-$i',
              'goodsId': 'raw-$i',
              'goodsName': '真实夹具原料$i',
              'executionSegmentId': segment,
              'issuedQty': 100,
              'unclearedQty': 100,
              'availableToSettleQty': 100,
              'requiredQty': 100,
              'requiredForProductQty': 100,
              'requirementMode': 'LINEAR',
            },
        ];
      }
      if (request.path.endsWith('/direct-transfers/candidates')) {
        return {'candidates': <dynamic>[]};
      }
      if (request.path.endsWith('/platform-columns/scopes')) {
        return [
          {
            'scope': 'production_daily_report_item',
            'supportsValues': true,
            'canWrite': true,
            'priceVisible': true,
          },
        ];
      }
      if (request.path.endsWith('/values:batch')) {
        final ids = ((request.data as Map)['recordIds'] as List).cast<String>();
        valueQueries.add(ids);
        return [
          for (final id in ids)
            {
              'recordId': id,
              'version': 7,
              'canWrite': false,
              'cells': [
                {
                  'columnId': _identityField.id,
                  'value': 'SERVER-$id',
                  'definition': _identityField.toJson(),
                  'persisted': true,
                },
              ],
            },
        ];
      }
      if (request.path.endsWith('/daily-reports/accepted-report')) {
        detailReads++;
        if (failDetail) throw StateError('server detail unavailable');
        return {
          'id': 'accepted-report',
          'billNo': 'SR-ACCEPTED',
          'status': 1,
          'rowVersion': 9,
          'departmentId': 'workshop',
          'items': [
            for (final id in ['server-B', 'server-A'])
              {
                'id': id,
                'goodsId': 'goods-1',
                'goodsName': '服务器正式成品',
                'goodsCode': 'P-001',
                'unitId': 'unit-1',
                'unitRate': 1,
                'qty': id == 'server-A' ? 1 : 2,
                'remark': '正式$id',
                'destination': id == 'server-B' ? 'WORKSHOP' : 'WAREHOUSE',
                'directTransferTargetLabel': id == 'server-B' ? '下一工序X' : null,
              },
          ],
        };
      }
      return null;
    },
  );
}

Future<({GoRouter router, ProviderContainer container})> _openIdentityPage(
  WidgetTester tester,
  MemoryFormDraftStorage storage,
  _IdentityApi fake, {
  String location = '/production/daily-reports/new',
  AttachmentService? attachments,
  Set<String>? initialPermissions,
  String? initialServer,
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      if (initialPermissions != null)
        _identityPermissions.overrideWith((_) => initialPermissions),
      if (initialServer != null)
        _identityServer.overrideWith((_) => initialServer),
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
      sessionProvider.overrideWith(_IdentityReaderSession.new),
      apiClientProvider.overrideWithValue(fake.api),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_identityServer)),
      authenticatedScopeProvider.overrideWith(
        (ref) => ref.watch(_identityScope),
      ),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_identityPermissions),
      ),
      if (attachments != null)
        attachmentServiceProvider.overrideWithValue(attachments),
      formDraftStorageProvider.overrideWithValue(storage),
      departmentRepositoryProvider.overrideWithValue(
        _FakeDepartmentRepository(),
      ),
      masterNameServiceProvider.overrideWithValue(MasterNameService(fake.api)),
      productionDailyReportRepositoryProvider.overrideWithValue(
        ProductionDailyReportRepository(fake.api),
      ),
      employeeRepositoryProvider.overrideWithValue(_FakeEmployeeRepository()),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      DraftAwareGoRoute(
        path: '/production/daily-reports/new',
        builder: (_, state) => ProductionDailyReportEditPage(
          key: state.pageKey,
          initialExecutionSegmentId: 'segment-1',
        ),
      ),
      GoRoute(
        path: '/production/daily-reports/create-recovery',
        builder: (_, state) => ProductionDailyReportCreateRecoveryPage(
          draftId: state.uri.queryParameters['draftId']!,
          returnToEditor: state.uri.queryParameters['returnToEditor'] == '1',
        ),
      ),
      GoRoute(
        path: '/production/daily-reports/:id',
        builder: (_, state) =>
            Scaffold(body: Text('正式详情 ${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: PlatformTableCatalogScope(
        resolver: resolvePlatformTable,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return (router: router, container: container);
}

Future<void> _closeIdentityPage(
  WidgetTester tester,
  ({GoRouter router, ProviderContainer container}) env,
) async {
  await tester.pumpWidget(const SizedBox());
  env.router.dispose();
  env.container.dispose();
}

UtenEditableGridController<DailyGridRow> _identityGrid(WidgetTester tester) =>
    tester
        .widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        )
        .controller;

FormDraftMixin<ProductionDailyReportEditPage> _identityState(
  WidgetTester tester,
) =>
    tester.state(find.byType(ProductionDailyReportEditPage))
        as FormDraftMixin<ProductionDailyReportEditPage>;

void _rewriteIdentityRecord(
  MemoryFormDraftStorage storage,
  void Function(Map<String, dynamic>) rewrite,
) {
  final key = storage.records.keys.single;
  final envelope = Map<String, dynamic>.from(
    jsonDecode(storage.records[key]!) as Map,
  );
  final data = Map<String, dynamic>.from(envelope['data'] as Map);
  rewrite(data);
  envelope['data'] = data;
  storage.records[key] = jsonEncode(envelope);
}

void registerDailyReportDraftIdentityTests() {
  testWidgets(
    'stable draft products survive duplicate goods, reorder and changed dynamic material rows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryFormDraftStorage();
      final fake = _IdentityApi();
      var env = await _openIdentityPage(tester, storage, fake);
      var grid = _identityGrid(tester);
      final a = grid.rows.singleWhere((r) => !r.isSubRow)..qty.text = '1';
      final b = a.clone()..qty.text = '2';
      a.platformFields.setValue(_identityField, 'A-ONLY');
      b.platformFields.setValue(_identityField, 'B-ONLY');
      expect(b.localRowId, isNot(a.localRowId));
      grid.addRow(b);
      grid.setSelected([a, b], true);
      await tester.pumpAndSettle();
      expect(grid.rows.where((r) => r.isMaterialRow), hasLength(2));
      await _identityState(tester).saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      final fields = draft.data['_platformGridDrafts'] as Map;
      expect(
        fields['rows'] as List,
        hasLength(2),
        reason: 'No derived child gets persisted metadata.',
      );
      final ids = [a.localRowId, b.localRowId];
      await _closeIdentityPage(tester, env);
      _rewriteIdentityRecord(storage, (data) {
        data['rows'] = (data['rows'] as List).reversed.toList();
      });
      fake.materialCounts['segment-1'] = 2;
      env = await _openIdentityPage(
        tester,
        storage,
        fake,
        location: draft.resumeLocation,
      );
      grid = _identityGrid(tester);
      final products = grid.rows.where((r) => !r.isSubRow).toList();
      expect(products.map((r) => r.localRowId), ids.reversed);
      expect(products.map((r) => r.platformFields.cells.single.value), [
        'B-ONLY',
        'A-ONLY',
      ]);
      expect(grid.rows.where((r) => r.isMaterialRow), hasLength(4));
      expect(
        grid.rows
            .where((r) => r.isSubRow)
            .every((r) => r.platformFields.cells.isEmpty),
        isTrue,
      );
      expect(_identityState(tester).formDraftRestorationBlocked, isFalse);
      // Actual page submission proves local identity is not a formal entity ID.
      for (final child in grid.rows.where(
        (r) => r.isMaterialRow && r.materialEditable,
      )) {
        child.materialUsed.text = '0';
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final items = fake.creates.single['items'] as List;
      expect(items, hasLength(2));
      expect((items[0] as Map)['qty'], 2);
      expect(
        (items[0] as Map)['platformFields'].toString(),
        contains('B-ONLY'),
      );
      expect(
        (items[1] as Map)['platformFields'].toString(),
        contains('A-ONLY'),
      );
      expect(jsonEncode(items), isNot(contains('localRowId')));
      for (final id in ids) {
        expect(jsonEncode(items), isNot(contains(id)));
      }
      await _closeIdentityPage(tester, env);
    },
  );

  for (final meaningful in [false, true]) {
    testWidgets(
      'legacy daily draft preserves unprovable values; meaningful=$meaningful',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = MemoryFormDraftStorage();
        final fake = _IdentityApi();
        var env = await _openIdentityPage(tester, storage, fake);
        final grid = _identityGrid(tester);
        final product = grid.rows.singleWhere((r) => !r.isSubRow)
          ..qty.text = '2';
        if (meaningful) {
          product.platformFields.setValue(_identityField, 'DO-NOT-GUESS');
        }
        await _identityState(tester).saveFormDraftNow();
        final draft = env.container.read(formDraftsProvider).single;
        final legacyFields = [
          for (final r in grid.rows) r.platformFields.exportDraft(),
        ];
        await _closeIdentityPage(tester, env);
        _rewriteIdentityRecord(storage, (data) {
          for (final row in data['rows'] as List) {
            (row as Map).remove('localRowId');
          }
          data['_platformGridDrafts'] = [legacyFields];
        });
        final original = Map<String, String>.of(storage.records);
        fake.materialCounts['segment-1'] = 2;
        env = await _openIdentityPage(
          tester,
          storage,
          fake,
          location: draft.resumeLocation,
        );
        expect(_identityState(tester).formDraftRestorationBlocked, meaningful);
        expect(
          storage.records,
          original,
          reason: 'Recovery cannot overwrite old evidence.',
        );
        expect(fake.creates, isEmpty);
        if (meaningful) {
          expect(find.textContaining('这份草稿暂时无法恢复'), findsOneWidget);
          expect(
            _identityGrid(
              tester,
            ).rows.every((r) => r.platformFields.cells.isEmpty),
            isTrue,
          );
        } else {
          expect(
            _identityGrid(tester).rows.singleWhere((r) => !r.isSubRow).qty.text,
            '2',
          );
          expect(
            _identityGrid(tester).rows.where((r) => r.isMaterialRow),
            hasLength(2),
          );
        }
        await _closeIdentityPage(tester, env);
      },
    );
  }

  for (final unavailable in [false, true]) {
    testWidgets(
      'accepted daily draft resumes authoritative item IDs without recreate; unavailable=$unavailable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = MemoryFormDraftStorage();
        final fake = _IdentityApi();
        var env = await _openIdentityPage(tester, storage, fake);
        final grid = _identityGrid(tester);
        final product = grid.rows.singleWhere((r) => !r.isSubRow)
          ..qty.text = '2';
        product.platformFields.setValue(_identityField, 'STALE-LOCAL');
        await _identityState(tester).saveFormDraftNow();
        final draft = env.container.read(formDraftsProvider).single;
        final legacy = [
          for (final row in grid.rows) row.platformFields.exportDraft(),
        ];
        await _closeIdentityPage(tester, env);
        _rewriteIdentityRecord(storage, (data) {
          data['createdReportId'] = 'accepted-report';
          data['_platformGridDrafts'] = [legacy];
          for (final row in data['rows'] as List) {
            (row as Map).remove('localRowId');
          }
        });
        final original = Map<String, String>.of(storage.records);
        fake.failDetail = unavailable;
        env = await _openIdentityPage(
          tester,
          storage,
          fake,
          location: draft.resumeLocation,
        );
        final actual = _identityGrid(tester).rows;
        expect(fake.detailReads, 1);
        if (unavailable) {
          expect(_identityState(tester).formDraftRestorationBlocked, isTrue);
          expect(storage.records, original);
          expect(fake.creates, isEmpty);
          expect(fake.valueQueries, isEmpty);
          await _closeIdentityPage(tester, env);
          return;
        }
        expect(actual.map((r) => r.platformFields.sourceRecordId), [
          'server-B',
          'server-A',
        ]);
        expect(
          actual.map((r) => r.platformFields.cells.single.value).toList(),
          ['SERVER-server-B', 'SERVER-server-A'],
        );
        expect(actual.every((r) => !r.isSubRow), isTrue);
        expect(actual.map((r) => r.acceptedDestinationLabel), [
          '转下一道工序 · 下一工序X',
          '送入仓库',
        ]);
        expect(_identityState(tester).captureFormDraftPlatformFields(), isNull);
        expect(
          fake.valueQueries.expand((ids) => ids),
          containsAll(['server-B', 'server-A']),
        );
        expect(_identityState(tester).formDraftRestorationBlocked, isFalse);
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(fake.creates, isEmpty);
        expect(find.text('正式详情 accepted-report'), findsOneWidget);
        await _closeIdentityPage(tester, env);
      },
    );
  }
}
