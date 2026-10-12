part of 'production_plan_edit_overproduction_rate_test.dart';

final _planReviewPermissionsProvider =
    NotifierProvider<_PlanReviewPermissions, Set<String>>(
      _PlanReviewPermissions.new,
    );

class _PlanReviewPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {Perm.productionPlanView, Perm.productionPlanApprove};
  void revoke() => state = {Perm.productionPlanView};
}

class _PendingPlanReviewSnapshot extends SessionSnapshotNotifier {
  _PendingPlanReviewSnapshot(this.gate);
  final Completer<SessionSnapshot?> gate;
  @override
  Future<SessionSnapshot?> build() => gate.future;
}

class _PlanReviewApi extends _PlanApi {
  _PlanReviewApi({this.quantityEditable = true, this.readGate})
    : super(secondRate: 0) {
    _detail['allowedActions'] = ['APPROVE'];
    for (final row in _detail['items'] as List) {
      (row as Map)['unitRate'] = 1;
      (row)['unitRateExact'] = '1';
    }
  }
  final bool quantityEditable;
  final Completer<void>? readGate;
  bool serverAuthorized = true;
  bool firstReadFailsAfterGate = false;
  int deniedReads = 0;
  int reads = 0;
  Map<String, dynamic>? reviewAttempt;
  static final snapshot = List.filled(64, 'a').join();
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/plan-1/draft-review') {
      final readNumber = ++reads;
      final authorizedWhenRequested = serverAuthorized;
      if (!authorizedWhenRequested) {
        deniedReads++;
        throw ApiException('FORBIDDEN', '审核权限已撤回');
      }
      if (readNumber == 1) {
        await readGate?.future;
        if (firstReadFailsAfterGate) {
          throw ApiException('FORBIDDEN', '旧请求的审核权限已过期');
        }
      }
      return {
        'snapshot': snapshot,
        'detail': _detail,
        'quantityEditable': quantityEditable,
      };
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    if (path != '/production/plans/plan-1/draft-review') {
      throw StateError('Reviewer must not call ordinary editing');
    }
    reviewAttempt = Map<String, dynamic>.from(body as Map);
    return {..._detail, 'status': 1};
  }
}

Future<ProviderContainer> _openPlanReview(
  WidgetTester tester,
  _PlanReviewApi api, {
  ValueNotifier<ThemeData>? theme,
  Completer<SessionSnapshot?>? meGate,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/review',
    routes: [
      GoRoute(
        path: '/review',
        builder: (_, _) =>
            const ProductionPlanEditPage(id: 'plan-1', reviewMode: true),
      ),
      GoRoute(
        path: '/production/plans/:id',
        builder: (_, _) => const Scaffold(body: Text('已审计划详情')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(includeSnapshot: meGate == null),
        if (meGate != null)
          sessionSnapshotProvider.overrideWith(
            () => _PendingPlanReviewSnapshot(meGate),
          ),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_planReviewPermissionsProvider),
        ),
        documentScopeCapabilityProvider.overrideWith(
          (ref, scope) async => DocumentScopeCapability(
            scope: scope.apiValue,
            writeAll: false,
            writableOwnerIds: const {},
          ),
        ),
      ],
      child: theme == null
          ? MaterialApp.router(routerConfig: router)
          : ValueListenableBuilder<ThemeData>(
              valueListenable: theme,
              builder: (_, current, _) => MaterialApp.router(
                routerConfig: router,
                theme: current,
              ),
            ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductionPlanEditPage)),
  );
}

void registerPlanReviewedSaveTests() {
  testWidgets(
    'review requests wait for the first confirmed Me snapshot',
    (tester) async {
      final meGate = Completer<SessionSnapshot?>();
      final api = _PlanReviewApi();
      await _openPlanReview(tester, api, meGate: meGate);
      expect(api.reads, 0);
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsNothing);
      meGate.complete(SessionSnapshot());
      await tester.pumpAndSettle();
      expect(api.reads, greaterThan(0));
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsOneWidget);
      expect(api.reviewAttempt, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'review-only plan uses original grid and retained redline then dedicated snapshot save',
    (tester) async {
      final api = _PlanReviewApi();
      await _openPlanReview(tester, api);
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<ProductionGridRow>>(
        find.byType(UtenEditableGrid<ProductionGridRow>),
      );
      expect(grid.showAddRow, isFalse);
      expect(grid.showRowDelete, isFalse);
      final row = grid.controller.rows.first;
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.qty),
        ),
        '12.1256',
      );
      await tester.pump();
      expect(
        find.byKey(ValueKey('plan-review-before-qty-${row.hashCode}')),
        findsOneWidget,
      );
      final retained = tester.widget<Text>(
        find.byKey(ValueKey('plan-review-before-qty-${row.hashCode}')),
      );
      expect(retained.data, '10');
      expect(retained.style!.decoration, TextDecoration.lineThrough);
      await tester.tap(find.text('保存并审核'));
      await tester.pumpAndSettle();
      expect(api.reviewAttempt!['expectedSnapshot'], _PlanReviewApi.snapshot);
      expect(api.reviewAttempt!['approveNow'], isTrue);
      final item =
          ((api.reviewAttempt!['document'] as Map)['items'] as List).first
              as Map;
      expect(item['qty'], '12.1256');
      expect(item['sourceItemId'], 'item-1');
      expect(item['goodsId'], 'goods-1');
      expect(item['unitRate'], '1');
      expect(find.text('已审计划详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'generated-source quantity stays unfocusable while remarks remain editable',
    (tester) async {
      final api = _PlanReviewApi(quantityEditable: false);
      await _openPlanReview(tester, api);
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<ProductionGridRow>>(
        find.byType(UtenEditableGrid<ProductionGridRow>),
      );
      final row = grid.controller.rows.first;
      final qtyField = find.byWidgetPredicate(
        (w) => w is TextField && identical(w.controller, row.qty),
      );
      expect(
        find.ancestor(
          of: qtyField,
          matching: find.byWidgetPredicate(
            (w) => w is AbsorbPointer && w.absorbing,
          ),
        ),
        findsWidgets,
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.remark),
        ),
        '审前核对备注',
      );
      await tester.pump();
      expect(row.qty.text, '10');
      expect(
        find.byKey(ValueKey('plan-review-before-remark-${row.hashCode}')),
        findsOneWidget,
      );
      expect(api.reviewAttempt, isNull);
    },
  );
  testWidgets(
    'revoking review authority hides already accepted plan cells and cannot submit',
    (tester) async {
      final api = _PlanReviewApi();
      final container = await _openPlanReview(tester, api);
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsOneWidget);
      api.serverAuthorized = false;
      container.read(_planReviewPermissionsProvider.notifier).revoke();
      await tester.pump();
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsNothing);
      expect(find.text('保存并审核'), findsNothing);
      expect(api.reviewAttempt, isNull);
      expect(api.deniedReads, 1);
    },
  );
  testWidgets(
    'late reviewer response after permission revocation never adopts its editable snapshot',
    (tester) async {
      final gate = Completer<void>();
      final api = _PlanReviewApi(readGate: gate);
      final container = await _openPlanReview(tester, api);
      expect(api.reads, greaterThan(0));
      api.serverAuthorized = false;
      container.read(_planReviewPermissionsProvider.notifier).revoke();
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsNothing);
      expect(api.reviewAttempt, isNull);
      expect(tester.takeException(), isNull);
      expect(api.deniedReads, 1);
    },
  );
  testWidgets(
    'an old denial cannot hide the latest server-authorized reviewer snapshot',
    (tester) async {
      final gate = Completer<void>();
      final api = _PlanReviewApi(readGate: gate)..firstReadFailsAfterGate = true;
      final theme = ValueNotifier(ThemeData.light());
      addTearDown(theme.dispose);
      final container = await _openPlanReview(tester, api, theme: theme);
      container.read(_planReviewPermissionsProvider.notifier).revoke();
      await tester.pumpAndSettle();
      expect(api.reads, greaterThanOrEqualTo(2));
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      theme.value = ThemeData.dark();
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<ProductionGridRow>), findsOneWidget);
      expect(find.text('旧请求的审核权限已过期'), findsNothing);
      expect(api.reviewAttempt, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
