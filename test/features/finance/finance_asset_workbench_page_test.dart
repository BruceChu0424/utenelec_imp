import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/finance/models/finance_asset_category_models.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/pages/finance_asset_workbench_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_category_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_overview_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('overview keeps policy readiness separate from posting safety', () {
    final overview = FinanceAssetWorkbenchOverview.fromJson(const {
      'originalValue': '9007199254740993.12',
      'netBookValue': '1.00',
      'deferredBalance': '2.00',
      'policyReady': true,
      'missingPolicyItems': <String>[],
      'postedWorkflowsEnabled': false,
      'operationalBlockers': <String>['BUSINESS_EVENT_REVERSAL_NOT_READY'],
    });

    expect(overview.metrics.originalValue, '9007199254740993.12');
    expect(overview.policyReady, isTrue);
    expect(overview.postedWorkflowsEnabled, isFalse);
    expect(overview.operationalBlockers, const <String>[
      'BUSINESS_EVENT_REVERSAL_NOT_READY',
    ]);
  });

  testWidgets('workbench has no overflow at 360, 720 and 1280 widths', (
    tester,
  ) async {
    for (final width in [360.0, 720.0, 1280.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await _pumpWorkbench(tester, repository: _FakeAssetRepository());
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('read-only permission exposes no write entry', (tester) async {
    final repository = _FakeAssetRepository();
    await tester.binding.setSurfaceSize(const Size(360, 900));
    await _pumpWorkbench(
      tester,
      repository: repository,
      permissions: const {Perm.financeAssetView},
    );

    expect(find.textContaining('新建固定资产'), findsNothing);
    expect(
      find.byKey(const Key('finance-asset-configure-policy')),
      findsNothing,
    );
    expect(repository.createCalls, 0);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('posting safety gate is distinct from category policy', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    await _pumpWorkbench(
      tester,
      repository: _FakeAssetRepository(),
      postedWorkflowsEnabled: false,
    );

    expect(
      find.byKey(const Key('finance-asset-posted-workflow-gate')),
      findsOneWidget,
    );
    expect(find.text('核心落账暂未开放'), findsOneWidget);
    expect(
      find.byKey(const Key('finance-asset-configure-policy')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('finance-asset-create-FIXED_ASSET')),
      findsOneWidget,
    );
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('list failure renders a real retry and recovers', (tester) async {
    final repository = _FakeAssetRepository(failFirstList: true);
    await tester.binding.setSurfaceSize(const Size(360, 900));
    await _pumpWorkbench(tester, repository: repository);

    expect(
      find.byKey(const Key('finance-asset-retry-FIXED_ASSET')),
      findsOneWidget,
    );
    await tester.tap(find.text('重试').last);
    await tester.pumpAndSettle();

    expect(repository.listCalls, 2);
    expect(
      find.byKey(const Key('finance-asset-retry-FIXED_ASSET')),
      findsNothing,
    );
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('blocking preview never exposes submit or post actions', (
    tester,
  ) async {
    final repository = _FakeAssetRepository(blockPreview: true);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await _pumpWorkbench(
      tester,
      repository: repository,
      permissions: const {
        Perm.financeAssetView,
        Perm.financeAssetPost,
        Perm.financeAssetApprove,
      },
    );

    await tester.tap(find.text('月末处理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('finance-asset-post-preview')),
    );
    await tester.tap(find.byKey(const Key('finance-asset-post-preview')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('finance-asset-post-blocked')), findsOneWidget);
    expect(find.byKey(const Key('finance-asset-post-submit')), findsNothing);
    expect(find.byKey(const Key('finance-asset-post-post')), findsNothing);
    expect(repository.postingActionCalls, 0);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'preview workflow advances optimistic-lock version at each step',
    (tester) async {
      final repository = _FakeAssetRepository();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await _pumpWorkbench(
        tester,
        repository: repository,
        permissions: const {
          Perm.financeAssetView,
          Perm.financeAssetPost,
          Perm.financeAssetApprove,
        },
      );

      await tester.tap(find.text('月末处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-asset-post-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-asset-post-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-asset-post-approve')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-asset-post-post')));
      await tester.pumpAndSettle();

      expect(repository.postingExpectedVersions, [0, 1, 2]);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('preview workflow obeys server maker-checker actions', (
    tester,
  ) async {
    final repository = _FakeAssetRepository(denyMakerApproval: true);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await _pumpWorkbench(
      tester,
      repository: repository,
      permissions: const {
        Perm.financeAssetView,
        Perm.financeAssetPost,
        Perm.financeAssetApprove,
      },
    );

    await tester.tap(find.text('月末处理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-asset-post-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-asset-post-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('finance-asset-post-approve')), findsNothing);
    expect(repository.postingActionCalls, 1);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('history exposes server-allowed approve and post actions', (
    tester,
  ) async {
    final repository = _FakeAssetRepository(
      historyRuns: const [
        AssetPostingRun(
          id: 'run-history',
          runType: AssetPostingRunType.depreciation,
          period: '2026-08',
          status: 'APPROVED',
          itemCount: 1,
          totalAmount: '100.00',
          allowedActions: {'APPROVE', 'POST'},
          version: 6,
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await _pumpWorkbench(
      tester,
      repository: repository,
      permissions: const {
        Perm.financeAssetView,
        Perm.financeAssetPost,
        Perm.financeAssetApprove,
      },
    );

    await tester.tap(find.text('月末处理'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('finance-asset-history-approve-run-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('finance-asset-history-post-run-history')),
      findsOneWidget,
    );
    await tester.binding.setSurfaceSize(null);
  });
}

Future<void> _pumpWorkbench(
  WidgetTester tester, {
  required _FakeAssetRepository repository,
  Set<String> permissions = const {
    Perm.financeAssetView,
    Perm.financeAssetEdit,
    Perm.financeAssetApprove,
    Perm.financeAssetPost,
    Perm.financeAssetDispose,
    Perm.financeAssetPeriodManage,
  },
  bool postedWorkflowsEnabled = true,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        financeAssetWorkbenchRepositoryProvider.overrideWithValue(repository),
        financeAssetOverviewRepositoryProvider.overrideWithValue(
          _FakeOverviewRepository(
            postedWorkflowsEnabled: postedWorkflowsEnabled,
          ),
        ),
        financeAssetCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
      ],
      child: const MaterialApp(home: FinanceAssetWorkbenchPage()),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeOverviewRepository implements FinanceAssetOverviewRepository {
  const _FakeOverviewRepository({this.postedWorkflowsEnabled = true});

  final bool postedWorkflowsEnabled;

  @override
  Future<FinanceAssetWorkbenchOverview> load() async {
    return FinanceAssetWorkbenchOverview(
      metrics: const FinanceAssetOverview(
        originalValue: '100000.00',
        netBookValue: '82000.00',
        deferredBalance: '21000.00',
        pendingOrExceptionCount: 2,
      ),
      policyReady: true,
      missingPolicyItems: const <String>[],
      postedWorkflowsEnabled: postedWorkflowsEnabled,
      operationalBlockers: postedWorkflowsEnabled
          ? const <String>[]
          : const <String>['BUSINESS_EVENT_REVERSAL_NOT_READY'],
    );
  }
}

class _FakeCategoryRepository implements FinanceAssetCategoryRepository {
  @override
  Future<FinanceAssetCategory> activate(
    String id, {
    required int? expectedVersion,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<FinanceAssetCategory> create(FinanceAssetCategoryInput input) {
    throw UnimplementedError();
  }

  @override
  Future<List<FinanceAssetCategory>> list(FinanceAssetLedger objectType) async {
    return const <FinanceAssetCategory>[];
  }

  @override
  Future<FinanceAssetCategory> update(
    String id,
    FinanceAssetCategoryInput input,
  ) {
    throw UnimplementedError();
  }
}

class _FakeAssetRepository implements FinanceAssetWorkbenchRepository {
  _FakeAssetRepository({
    this.failFirstList = false,
    this.blockPreview = false,
    this.denyMakerApproval = false,
    this.historyRuns = const <AssetPostingRun>[],
  });

  final bool failFirstList;
  final bool blockPreview;
  final bool denyMakerApproval;
  final List<AssetPostingRun> historyRuns;
  int listCalls = 0;
  int createCalls = 0;
  int postingActionCalls = 0;
  final List<int?> postingExpectedVersions = <int?>[];

  @override
  Future<PagedResult<FinanceAssetSummary>> list(
    FinanceAssetLedger ledger, {
    FinanceAssetQuery query = const FinanceAssetQuery(),
  }) async {
    listCalls++;
    if (failFirstList && listCalls == 1) throw StateError('offline');
    return PagedResult<FinanceAssetSummary>(
      items: const <FinanceAssetSummary>[],
      page: query.page,
      size: query.size,
      total: 0,
      totalPages: 1,
    );
  }

  @override
  Future<FinanceAssetOverview> loadOverview() async {
    return const FinanceAssetOverview(
      originalValue: '0',
      netBookValue: '0',
      deferredBalance: '0',
      pendingOrExceptionCount: 0,
    );
  }

  @override
  Future<List<AssetPeriod>> listPeriods() async => const <AssetPeriod>[];

  @override
  Future<PagedResult<AssetPostingRun>> listPostingRuns({
    int page = 1,
    int size = 20,
    String? period,
    AssetPostingRunType? runType,
    String? status,
  }) async {
    return PagedResult<AssetPostingRun>(
      items: historyRuns,
      page: page,
      size: size,
      total: 0,
      totalPages: 1,
    );
  }

  @override
  Future<AssetPostingPreview> previewPosting({
    required AssetPostingRunType runType,
    required String period,
    String? bookType,
  }) async {
    return AssetPostingPreview(
      runId: 'run-1',
      status: 'PREVIEWED',
      token: 'token-1',
      count: 1,
      totalAmount: '100.00',
      warnings: const <AssetPostingMessage>[],
      errors: blockPreview
          ? const [
              AssetPostingMessage(code: 'MISSING_POLICY', message: '资产分类政策缺失'),
            ]
          : const <AssetPostingMessage>[],
      lines: const <AssetPostingLine>[],
      allowedActions: const {'SUBMIT'},
      version: 0,
    );
  }

  @override
  Future<FinanceAssetWorkflowResponse> createDraft(
    FinanceAssetLedger ledger,
    FinanceAssetDraftInput input,
  ) async {
    createCalls++;
    return _workflow();
  }

  @override
  Future<FinanceAssetWorkflowResponse> assetAction(
    FinanceAssetLedger ledger,
    String id,
    String action,
    FinanceAssetWorkflowRequest request,
  ) async {
    return _workflow();
  }

  @override
  Future<void> deleteDraft(
    FinanceAssetLedger ledger,
    String id, {
    required int expectedVersion,
  }) async {}

  @override
  Future<FinanceAssetDetail> detail(FinanceAssetLedger ledger, String id) {
    throw UnimplementedError();
  }

  @override
  Future<FinanceAssetWorkflowResponse> periodAction(
    String period,
    String action, {
    required String reason,
    int? expectedVersion,
  }) async {
    return _workflow();
  }

  @override
  Future<FinanceAssetWorkflowResponse> postingAction(
    String id,
    String action, {
    String? token,
    int? expectedVersion,
    String? reason,
  }) async {
    postingActionCalls++;
    postingExpectedVersions.add(expectedVersion);
    return _workflow(
      status: switch (action) {
        'submit' => 'SUBMITTED',
        'approve' => 'APPROVED',
        'post' => 'POSTED',
        _ => 'DRAFT',
      },
      allowedActions: switch (action) {
        'submit' when denyMakerApproval => const <String>{},
        'submit' => const {'APPROVE'},
        'approve' => const {'POST'},
        _ => const <String>{},
      },
      version: postingActionCalls,
    );
  }

  @override
  Future<FinanceAssetWorkflowResponse> updateDraft(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetDraftInput input,
  ) async {
    return _workflow();
  }

  FinanceAssetWorkflowResponse _workflow({
    String status = 'DRAFT',
    int version = 0,
    Set<String> allowedActions = const <String>{},
  }) {
    return FinanceAssetWorkflowResponse(
      id: 'row-1',
      status: status,
      allowedActions: allowedActions,
      version: version,
    );
  }
}
