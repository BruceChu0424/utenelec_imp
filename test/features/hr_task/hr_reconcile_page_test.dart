// 员工资料核对更正页(ADR-160)：生成计划/逐行确认(建议·候选·手输)/提交体语义/
// 执行结果渲染/409 冲突自动重取/他人认领锁/空态/打码/窄屏卡片。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_paged_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/hr_task/models/hr_reconcile_plan.dart';
import 'package:uten_imp/features/hr_task/pages/hr_reconcile_page.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_reconcile_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

// 与后端 IdCardUtil 校验一致的真实合法号码（手输用例必须过校验）。
const _kValidId = '11010519491231002X';
const _kBrokenId = '450303199001012646';

class _FakeRepo extends Fake implements HrReconcileRepository {
  /// createIdRepairPlan 的返回，也作为 getPlan 的默认返回。
  HrReconcilePlan plan;
  HrReconcilePlan? createdPlan;

  /// apply 成功后 getPlan 改回这份（结果列渲染）。
  HrReconcilePlan? planAfterApply;
  bool _applied = false;
  HrReconcileApplyResult? applyResult;
  Object? applyError;
  Object? receiptError;
  HrReconcileApplyReceipt receipt = const HrReconcileApplyReceipt(
    status: 'RUNNING',
  );
  Completer<HrReconcileApplyReceipt>? delayedReceipt;
  final List<({String planId, String requestId})> receiptReads = [];
  HrReconcilePlanSummaryPage plansPage = const HrReconcilePlanSummaryPage(
    items: [],
    page: 1,
    size: 50,
    total: 0,
    totalPages: 1,
  );

  final List<String> fetched = [];
  final List<List<String>> created = [];
  int getPlanCalls = 0;
  int listCalls = 0;
  final List<int> recordPagesRequested = [];
  final Map<int, HrReconcilePlanSummaryPage> recordPages = {};
  final Map<int, Object> recordPageErrors = {};
  final List<Future<HrReconcilePlanSummaryPage>> delayedRecordResponses = [];
  final List<
    ({
      String planId,
      int planVersion,
      String requestId,
      List<HrReconcileApplyRow> rows,
    })
  >
  applies = [];

  _FakeRepo(this.plan);

  @override
  Future<HrReconcilePlan> createIdRepairPlan(List<String> employeeIds) async {
    created.add(List<String>.of(employeeIds));
    return createdPlan ?? plan;
  }

  @override
  Future<HrReconcilePlan> getPlan(String id) async {
    getPlanCalls++;
    fetched.add(id);
    if (createdPlan?.id == id) return createdPlan!;
    return _applied ? (planAfterApply ?? plan) : plan;
  }

  @override
  Future<HrReconcileApplyReceipt> getApplyReceipt(
    String planId,
    String requestId,
  ) async {
    receiptReads.add((planId: planId, requestId: requestId));
    if (delayedReceipt != null) return delayedReceipt!.future;
    if (receiptError != null) throw receiptError!;
    return receipt;
  }

  @override
  Future<HrReconcilePlanSummaryPage> listPlans({
    int page = 1,
    int size = 50,
  }) async {
    listCalls++;
    recordPagesRequested.add(page);
    if (delayedRecordResponses.isNotEmpty) {
      return delayedRecordResponses.removeAt(0);
    }
    if (recordPageErrors[page] != null) throw recordPageErrors[page]!;
    return recordPages[page] ?? plansPage;
  }

  @override
  Future<HrReconcileApplyResult> apply(
    String planId, {
    required int planVersion,
    required String requestId,
    required List<HrReconcileApplyRow> rows,
  }) async {
    applies.add((
      planId: planId,
      planVersion: planVersion,
      requestId: requestId,
      rows: rows,
    ));
    if (applyError != null) throw applyError!;
    _applied = true;
    return applyResult ??
        HrReconcileApplyResult(
          planVersion: planVersion + 1,
          round: 1,
          counts: const HrReconcileApplyCounts(
            applied: 0,
            skipped: 0,
            failed: 0,
          ),
          rows: const [],
          summary: 'ok',
        );
  }
}

// ── JSON 夹具（与服务端 PlanView 契约一致） ────────────────────────────────

Map<String, dynamic> _itemJson({
  int itemNo = 1,
  String? oldValue = _kBrokenId,
  String? newValue,
  List<int> diffPositions = const [10],
  String tier = 'HIGH',
  double? probability,
  bool preselected = false,
  bool permitted = true,
  List<Map<String, dynamic>> candidates = const [],
  List<int> suspectPositions = const [],
  List<String> notes = const [],
  Map<String, dynamic>? outcome,
  String basisCode = 'BIRTH_ANCHOR',
}) => {
  'itemNo': itemNo,
  'field': 'idNumber',
  'label': '证件号码',
  'writePath': 'CHANGE_IDENTITY',
  'oldValue': oldValue,
  'newValue': newValue,
  'diffPositions': diffPositions,
  if (basisCode.isNotEmpty) 'basis': {'code': basisCode, 'label': '生日对齐'},
  'tier': tier,
  'probability': probability,
  'preselected': preselected,
  'permitted': permitted,
  'permissionLabel': null,
  'candidates': candidates,
  'suspectPositions': suspectPositions,
  'notes': notes,
  'outcome': outcome,
};

Map<String, dynamic> _rowJson({
  int rowNo = 1,
  int employeeVersion = 4,
  String kind = 'UPDATE',
  String employeeId = 'emp-1',
  String name = '王五',
  String code = 'UT0050',
  Map<String, dynamic>? claim,
  Map<String, dynamic>? item,
  Map<String, dynamic>? result,
  List<Map<String, dynamic>> notices = const [
    {'code': 'X', 'message': '第18位校验码与前17位不符'},
  ],
}) => {
  'rowNo': rowNo,
  'employeeVersion': employeeVersion,
  'kind': kind,
  'employee': {
    'id': employeeId,
    'code': code,
    'name': name,
    'deptName': '装配第一车间',
    'positionName': '操作工',
    'hireDate': '2024-05-01',
  },
  'claim': ?claim,
  'notices': notices,
  'items': item == null ? const <Map<String, dynamic>>[] : [item],
  'result': ?result,
};

Map<String, dynamic> _planJson({
  String id = 'plan-1',
  int version = 1,
  String status = 'OPEN',
  String? closedReason,
  bool canApply = true,
  bool viewPii = true,
  bool piiEdit = true,
  required List<Map<String, dynamic>> rows,
}) {
  final update = rows.where((r) => r['kind'] == 'UPDATE').length;
  final info = rows.where((r) => r['kind'] == 'INFO').length;
  final same = rows.where((r) => r['kind'] == 'SAME').length;
  return {
    'id': id,
    'version': version,
    'status': status,
    'closedReason': ?closedReason,
    'source': 'ID_REPAIR',
    'origin': 'PAGE',
    'actorName': '张三',
    'createdAt': '2026-10-05T09:00:00+08:00',
    'expiresAt': '2026-10-06T09:00:00+08:00',
    'canApply': canApply,
    'readOnlyReason': null,
    'capabilities': {'viewPii': viewPii, 'piiEdit': piiEdit},
    'counts': {
      'rows': rows.length,
      'update': update,
      'updateItems': update,
      'info': info,
      'same': same,
      'applied': 0,
      'skipped': 0,
      'failed': 0,
    },
    'rows': rows,
  };
}

HrReconcileApplyResult _finishedResult({int version = 2, int rowNo = 1}) =>
    HrReconcileApplyResult(
      planVersion: version,
      round: 1,
      counts: const HrReconcileApplyCounts(applied: 1, skipped: 0, failed: 0),
      rows: [
        HrReconcileApplyRowResult(
          rowNo: rowNo,
          result: HrReconcileRowResultStatus.applied,
          items: const [
            HrReconcileApplyItemResult(
              itemNo: 1,
              status: HrReconcileOutcomeStatus.applied,
            ),
          ],
        ),
      ],
      summary: '原更正已完成',
    );

HrReconcilePlanSummaryPage _recordsPage(
  int page,
  List<String> ids, {
  int totalPages = 1,
}) => HrReconcilePlanSummaryPage.fromJson({
  'items': [
    for (final id in ids)
      {
        'id': id,
        'createdAt': '2026-10-05T09:00:00+08:00',
        'actorName': '张三',
        'status': 'CLOSED',
        'closedReason': 'EXPIRED',
        'counts': {
          'rows': 1,
          'update': 1,
          'updateItems': 1,
          'info': 0,
          'same': 0,
          'applied': 1,
          'skipped': 0,
          'failed': 0,
        },
      },
  ],
  'page': page,
  'size': 50,
  'total': totalPages == 1 ? ids.length : 51,
  'totalPages': totalPages,
});

// ── 页面夹具：GoRouter + 假仓库 + 中文 locale ──────────────────────────────

class _Home extends StatelessWidget {
  const _Home({required this.go});

  final Future<void> Function(BuildContext context) go;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => go(context), child: const Text('go')),
    ),
  );
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required _FakeRepo repo,
  String? pushUri,
  void Function(bool?)? onResult,
  List<String>? routeUris,
  Set<String> permissions = const {
    Perm.employeeView,
    Perm.employeeEdit,
    Perm.employeePiiEdit,
  },
  StateProvider<Set<String>>? permissionState,
  StateProvider<String>? recordSessionState,
  FormDraftStorage? draftStorage,
  double? displayFactor,
  double systemFactor = 1,
  bool dark = false,
}) async {
  bool? pushed;
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => _Home(
          go: (context) async {
            pushed = await context.push<bool>(pushUri ?? RouteName.hrReconcile);
            onResult?.call(pushed);
          },
        ),
      ),
      GoRoute(
        path: RouteName.hrReconcile,
        builder: (_, state) {
          // pushReplacement 换参后本 builder 会带着新 query 重建——记录之。
          routeUris?.add(state.uri.toString());
          return const HrReconcilePage();
        },
      ),
      GoRoute(
        path: '/hr/tasks/identity',
        builder: (_, _) => const Scaffold(body: Text('identity-list')),
      ),
    ],
  );
  addTearDown(router.dispose);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hrReconcileRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWith(
          (ref) => permissionState == null
              ? permissions
              : ref.watch(permissionState),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        if (draftStorage != null) ...[
          formDraftStorageProvider.overrideWithValue(draftStorage),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'hr-editor'),
          ),
        ],
        if (recordSessionState != null)
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(recordSessionState),
          ),
      ],
      child: MaterialApp.router(
        theme: dark
            ? buildDarkTheme()
            : displayFactor == null
            ? null
            : buildLightTheme(),
        builder: (context, child) => displayFactor == null
            ? child!
            : MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(systemFactor)),
                child: UtenDisplayZoomBox(
                  fontFactor: displayFactor,
                  child: UtenControlTheme(child: child!),
                ),
              ),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return router;
}

MasterDataTableView<HrReconcileRow> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<HrReconcileRow>>(
      find.byKey(const Key('hr-reconcile-table')),
    );

HrReconcileRow _row(WidgetTester tester, String employeeId) =>
    _table(tester).items.firstWhere((row) => row.employee.id == employeeId);

Future<void> _typeManual(
  WidgetTester tester,
  int rowNo, [
  String value = _kValidId,
]) async {
  await tester.enterText(
    find.byKey(ValueKey('hr-reconcile-manual-$rowNo')),
    value,
  );
  await tester.pumpAndSettle();
}

List<String> _noticeMessages(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HrReconcilePage)),
  listen: false,
).read(appNotificationProvider).map((n) => n.message).toList();

Future<FormDraft> _seedUnknown(
  WidgetTester tester,
  _FakeRepo repo,
  MemoryFormDraftStorage storage,
) async {
  await _pump(
    tester,
    repo: repo,
    draftStorage: storage,
    pushUri: '${RouteName.hrReconcile}?planId=plan-1',
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HrReconcilePage)),
  );
  final editor =
      tester.state(find.byType(HrReconcilePage))
          as FormDraftMixin<HrReconcilePage>;
  final spec = editor.formDraftSpec;
  final snapshot = editor.captureFormDraft();
  final rows = snapshot['rows'] as List;
  final saved = await container
      .read(formDraftsProvider.notifier)
      .save(
        FormDraft(
          id: 'unknown-input',
          title: spec.title,
          module: spec.module,
          route: spec.route,
          permission: spec.permission,
          draftKind: spec.draftKind,
          updatedAt: DateTime.utc(2026, 10, 11),
          data: {
            ...snapshot,
            'rows': [
              for (var i = 0; i < rows.length; i++)
                {
                  ...Map<String, dynamic>.from(rows[i] as Map),
                  'manual': i == 0 ? _kValidId : '1101051949',
                  'selected': i == 0,
                },
            ],
            'submission': {
              'planId': 'plan-1',
              'planVersion': 1,
              'requestId': 'original-command',
              'rows': [
                {
                  'rowNo': 1,
                  'items': [
                    {'itemNo': 1, 'value': _kValidId},
                  ],
                },
              ],
            },
            '_formDraftHasUnknownSubmission': true,
          },
        ),
      );
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  return saved;
}

void main() {
  for (final systemFactor in [1.0, 2.0]) {
    testWidgets('closed reconcile summary at 200% keeps counts $systemFactor', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            status: 'CLOSED',
            canApply: false,
            closedReason: 'EXPIRED',
            rows: [_rowJson(kind: 'SAME')],
          ),
        ),
      );
      await _pump(
        tester,
        repo: repo,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
        displayFactor: 2,
        systemFactor: systemFactor,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('核对记录 ·'), findsOneWidget);
      expect(find.byKey(const Key('hr-reconcile-apply')), findsNothing);
      expect(repo.applies, isEmpty);
      expect(repo.created, isEmpty);
    });
  }

  testWidgets(
    'interrupted receipt shows real outcomes and explicitly rebuilds without old input',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [
              _rowJson(item: _itemJson(tier: 'MANUAL')),
              _rowJson(
                rowNo: 2,
                employeeId: 'emp-2',
                item: _itemJson(tier: 'MANUAL'),
              ),
            ],
          ),
        ),
      );
      final saved = await _seedUnknown(tester, repo, storage);
      repo.plan = HrReconcilePlan.fromJson(
        _planJson(
          version: 2,
          status: 'CLOSED',
          closedReason: 'EXPIRED',
          canApply: false,
          rows: [
            _rowJson(
              employeeVersion: 5,
              item: _itemJson(
                newValue: _kValidId,
                outcome: {'status': 'APPLIED'},
              ),
              result: {'status': 'APPLIED'},
            ),
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              item: _itemJson(oldValue: null, tier: 'MANUAL'),
            ),
          ],
        ),
      );
      repo.receipt = const HrReconcileApplyReceipt(status: 'INTERRUPTED');
      repo.createdPlan = HrReconcilePlan.fromJson(
        _planJson(
          id: 'fresh-plan',
          rows: [
            _rowJson(kind: 'SAME', employeeVersion: 5),
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              item: _itemJson(tier: 'MANUAL'),
            ),
          ],
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      await tester.tap(
        find.byKey(const Key('hr-reconcile-check-original-receipt')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已更正'), findsWidgets);
      expect(_table(tester).selectable, isFalse);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      final known = container.read(formDraftsProvider).single;
      expect(known.hasUnknownSubmission, isFalse);
      expect(
        (known.data['knownInterruptedReceipt'] as Map)['sourcePlanVersion'],
        1,
      );
      expect(
        (known.data['knownInterruptedReceipt'] as Map)['status'],
        'INTERRUPTED',
      );
      expect(repo.created, isEmpty);
      await tester.tap(
        find.byKey(const Key('hr-reconcile-rebuild-interrupted')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('重新核对'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.created.single, ['emp-1', 'emp-2']);
      expect(repo.applies, isEmpty);
      final current =
          tester.state(find.byType(HrReconcilePage))
              as FormDraftMixin<HrReconcilePage>;
      final snapshot = current.captureFormDraft();
      expect(snapshot['planId'], 'fresh-plan');
      expect(
        (snapshot['rows'] as List).cast<Map<String, dynamic>>().every(
          (row) => (row['manual'] ?? '') == '',
        ),
        isTrue,
      );
      expect(
        storage.records.values
            .map((value) => jsonDecode(value) as Map<String, dynamic>)
            .any(
              (record) =>
                  record['completed'] == true &&
                  record['data'] is Map &&
                  ((record['data'] as Map)['knownInterruptedReceipt']
                          as Map?)?['status'] ==
                      'INTERRUPTED',
            ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late receipt cannot complete a draft after the route changes plans',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [
              _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            ],
          ),
        ),
      );
      final saved = await _seedUnknown(tester, repo, storage);
      final delayed = Completer<HrReconcileApplyReceipt>();
      repo.delayedReceipt = delayed;
      final router = await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      await tester.tap(
        find.byKey(const Key('hr-reconcile-check-original-receipt')),
      );
      await tester.pump();
      repo.plan = HrReconcilePlan.fromJson(
        _planJson(
          id: 'other-plan',
          rows: [_rowJson(item: _itemJson(tier: 'MANUAL'))],
        ),
      );
      router.go('${RouteName.hrReconcile}?planId=other-plan');
      await tester.pump();
      delayed.complete(
        HrReconcileApplyReceipt(status: 'FINISHED', result: _finishedResult()),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      expect(container.read(formDraftsProvider).single.id, saved.id);
      expect(
        container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(repo.applies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final status in [
    'RUNNING',
    'INTERRUPTED',
    'FINISHED_WITHOUT_RESULT',
    'FINISHED_WRONG_VERSION',
    'FINISHED_OTHER_ROW',
    'NOT_FOUND',
  ]) {
    testWidgets(
      'receipt $status keeps the frozen request and never sends another apply',
      (tester) async {
        final storage = MemoryFormDraftStorage();
        final repo = _FakeRepo(
          HrReconcilePlan.fromJson(
            _planJson(
              rows: [
                _rowJson(
                  item: _itemJson(newValue: _kValidId, preselected: true),
                ),
              ],
            ),
          ),
        );
        await _pump(
          tester,
          repo: repo,
          draftStorage: storage,
          pushUri: '${RouteName.hrReconcile}?planId=plan-1',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HrReconcilePage)),
        );
        final editor =
            tester.state(find.byType(HrReconcilePage))
                as FormDraftMixin<HrReconcilePage>;
        final spec = editor.formDraftSpec;
        final submission = {
          'planId': 'plan-1',
          'planVersion': 1,
          'requestId': 'original-command',
          'rows': [
            {
              'rowNo': 1,
              'items': [
                {'itemNo': 1},
              ],
            },
          ],
        };
        final saved = await container
            .read(formDraftsProvider.notifier)
            .save(
              FormDraft(
                id: 'unknown-input',
                title: spec.title,
                module: spec.module,
                route: spec.route,
                permission: spec.permission,
                draftKind: spec.draftKind,
                updatedAt: DateTime.utc(2026, 10, 11),
                data: {
                  ...editor.captureFormDraft(),
                  'submission': submission,
                  '_formDraftHasUnknownSubmission': true,
                },
              ),
            );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        if (status == 'NOT_FOUND') {
          repo.receiptError = ApiException(
            'NOT_FOUND',
            'no receipt',
            httpStatus: 404,
          );
        } else {
          repo.receipt = HrReconcileApplyReceipt(
            status: status.startsWith('FINISHED') ? 'FINISHED' : status,
            result: status == 'FINISHED_WRONG_VERSION'
                ? _finishedResult(version: 3)
                : status == 'FINISHED_OTHER_ROW'
                ? _finishedResult(rowNo: 99)
                : null,
          );
        }
        await _pump(
          tester,
          repo: repo,
          draftStorage: storage,
          pushUri: saved.resumeLocation,
        );
        await tester.tap(
          find.byKey(const Key('hr-reconcile-check-original-receipt')),
        );
        await tester.pumpAndSettle();
        expect(repo.applies, isEmpty);
        expect(repo.receiptReads.single.requestId, 'original-command');
        final resumed = ProviderScope.containerOf(
          tester.element(find.byType(HrReconcilePage)),
        );
        expect(
          resumed.read(formDraftsProvider).single.hasUnknownSubmission,
          status == 'INTERRUPTED' ? isFalse : isTrue,
        );
        expect(repo.created, isEmpty, reason: '读到中断也必须由用户显式重建');
        expect(
          resumed.read(formDraftsProvider).single.data['submission'],
          submission,
        );
        expect(find.byKey(const Key('hr-reconcile-apply')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'CAS conflict prevents apply and keeps the newer editor snapshot intact',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [_rowJson(item: _itemJson(tier: 'MANUAL'))],
          ),
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('hr-reconcile-manual-1')),
        _kValidId,
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      final original = container.read(formDraftsProvider).single;
      final next = await container
          .read(formDraftsProvider.notifier)
          .save(
            FormDraft(
              id: original.id,
              title: original.title,
              module: original.module,
              route: original.route,
              permission: original.permission,
              draftKind: original.draftKind,
              updatedAt: DateTime.utc(2026, 10, 12),
              data: {
                ...original.data,
                'rows': [
                  {
                    ...(original.data['rows'] as List).single
                        as Map<String, dynamic>,
                    'manual': 'newer-input',
                  },
                ],
              },
            ),
            expectedRevision: original.revision,
          );
      _table(tester).onSelectedIdsChanged!({'emp-1'});
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      expect(repo.applies, isEmpty);
      expect(container.read(formDraftsProvider).single.revision, next.revision);
      expect(
        container.read(formDraftsProvider).single.data['rows'],
        next.data['rows'],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual raw input autosaves and resumes by employee identity after line reorder',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [
              _rowJson(item: _itemJson(tier: 'MANUAL')),
              _rowJson(
                rowNo: 2,
                employeeId: 'emp-2',
                item: _itemJson(tier: 'MANUAL'),
              ),
            ],
          ),
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('hr-reconcile-manual-1')),
        '1101051949',
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      final saved = container.read(formDraftsProvider).single;
      final rows = saved.data['rows'] as List;
      expect((rows.first as Map)['manual'], '1101051949');
      expect((rows.first as Map)['employeeId'], 'emp-1');
      expect((rows.first as Map)['sourceVersion'], 4);
      expect(saved.data.keys, isNot(contains('password')));
      expect(saved.data.keys, isNot(contains('stepUpToken')));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      repo.plan = HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(
              employeeId: 'emp-2',
              item: _itemJson(tier: 'MANUAL'),
            ),
            _rowJson(rowNo: 2, item: _itemJson(tier: 'MANUAL')),
          ],
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('hr-reconcile-manual-2')),
            )
            .controller!
            .text,
        '1101051949',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('hr-reconcile-manual-1')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(repo.applies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'legacy draft resumes manual text only and leaves suggestion-only rows blank',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [
              _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
              _rowJson(
                rowNo: 2,
                employeeId: 'emp-2',
                item: _itemJson(
                  newValue: _kValidId,
                  tier: 'MEDIUM',
                  candidates: [
                    {'value': _kValidId, 'probability': 0.9},
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      );
      final editor =
          tester.state(find.byType(HrReconcilePage))
              as FormDraftMixin<HrReconcilePage>;
      final spec = editor.formDraftSpec;
      final snapshot = editor.captureFormDraft()..remove('inputMode');
      final rows = snapshot['rows'] as List;
      final saved =
          await ProviderScope.containerOf(
                tester.element(find.byType(HrReconcilePage)),
              )
              .read(formDraftsProvider.notifier)
              .save(
                FormDraft(
                  id: 'legacy-manual-and-choice',
                  title: spec.title,
                  module: spec.module,
                  route: spec.route,
                  permission: spec.permission,
                  draftKind: spec.draftKind,
                  updatedAt: DateTime.utc(2026, 10, 11),
                  data: {
                    ...snapshot,
                    'rows': [
                      {
                        ...Map<String, dynamic>.from(rows.first as Map),
                        'manual': '1101051949',
                        'adopted': true,
                        'selected': true,
                      },
                      {
                        ...Map<String, dynamic>.from(rows.last as Map),
                        'manual': '',
                        'candidateValue': _kValidId,
                        'selected': true,
                      },
                    ],
                  },
                ),
              );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('hr-reconcile-manual-1')),
            )
            .controller!
            .text,
        '1101051949',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('hr-reconcile-manual-2')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const Key('hr-reconcile-legacy-input-notice')),
        findsOneWidget,
      );
      expect(find.text('确认更正 0 人 0 处'), findsOneWidget);
      expect(repo.applies, isEmpty);
      await _typeManual(tester, 2);
      expect(find.text('确认更正 1 人 1 处'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      expect(repo.applies.single.rows.map((row) => row.rowNo), [2]);
      expect(repo.applies.single.rows.single.items.single.value, _kValidId);
      expect(
        repo.applies.single.rows.single.items.single.candidateIndex,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(1440, 1000), const Size(375, 1000)]) {
    testWidgets('manual editor remains usable at $size dark and large text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final row = _rowJson(
        item: _itemJson(newValue: _kValidId, tier: 'NONE'),
      );
      row['employee'] = {
        ...Map<String, dynamic>.from(row['employee'] as Map),
        'positionName': null,
      };
      final repo = _FakeRepo(HrReconcilePlan.fromJson(_planJson(rows: [row])));
      await _pump(
        tester,
        repo: repo,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
        displayFactor: 1.6,
        systemFactor: 1.5,
        dark: true,
      );
      expect(tester.takeException(), isNull);
      expect(
        _table(tester).columns
            .where((column) => column.key == 'position')
            .single
            .value(_row(tester, 'emp-1')),
        '—',
      );
      await _typeManual(tester, 1);
      _table(tester).onSelectedIdsChanged!({'emp-1'});
      await tester.pumpAndSettle();
      expect(find.text('确认更正 1 人 1 处'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('hr-reconcile-manual-1')),
            )
            .controller!
            .text,
        _kValidId,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'changed source version blocks restoration and retains original input',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [_rowJson(item: _itemJson(tier: 'MANUAL'))],
          ),
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('hr-reconcile-manual-1')),
        '1101051949',
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      final saved = container.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      repo.plan = HrReconcilePlan.fromJson(
        _planJson(
          rows: [_rowJson(employeeVersion: 5, item: _itemJson(tier: 'MANUAL'))],
        ),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      final resumed = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      expect(
        resumed.read(formDraftsProvider).single.data['rows'],
        saved.data['rows'],
      );
      expect(_table(tester).selectable, isFalse);
      expect(repo.applies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lost apply response is resolved by GET receipt even after plan expiration',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryFormDraftStorage();
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(
          _planJson(
            rows: [
              _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            ],
          ),
        ),
      )..applyError = StateError('lost response');
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      );
      await _typeManual(tester, 1);
      _table(tester).onSelectedIdsChanged!({'emp-1'});
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      final saved = container.read(formDraftsProvider).single;
      expect(saved.hasUnknownSubmission, isTrue);
      final original = repo.applies.single;
      expect(
        (saved.data['submission'] as Map)['requestId'],
        original.requestId,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      repo.plan = HrReconcilePlan.fromJson(
        _planJson(
          version: 2,
          status: 'CLOSED',
          closedReason: 'EXPIRED',
          canApply: false,
          rows: [
            _rowJson(
              employeeVersion: 5,
              item: _itemJson(
                newValue: _kValidId,
                outcome: {'status': 'APPLIED'},
              ),
              result: {'status': 'APPLIED'},
            ),
          ],
        ),
      );
      repo.receipt = HrReconcileApplyReceipt(
        status: 'FINISHED',
        result: _finishedResult(),
      );
      await _pump(
        tester,
        repo: repo,
        draftStorage: storage,
        pushUri: saved.resumeLocation,
      );
      await tester.tap(
        find.byKey(const Key('hr-reconcile-check-original-receipt')),
      );
      await tester.pumpAndSettle();
      expect(repo.receiptReads.single, (
        planId: 'plan-1',
        requestId: original.requestId,
      ));
      expect(repo.applies, hasLength(1), reason: '回执核对不得再次发送更正请求');
      final resumed = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      expect(resumed.read(formDraftsProvider), isEmpty);
      expect(find.text('已更正'), findsWidgets);
      expect(_table(tester).selectable, isFalse);
      expect(find.byKey(const Key('hr-reconcile-apply')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reason in ['EXPIRED', 'DISCARDED']) {
    testWidgets(
      'closed $reason keeps completed results readable and forbids execution',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _FakeRepo(
          HrReconcilePlan.fromJson(
            _planJson(
              status: 'CLOSED',
              closedReason: reason,
              // An obsolete capability cannot reopen a closed record in the UI.
              rows: [
                _rowJson(
                  item: _itemJson(
                    newValue: _kValidId,
                    outcome: {'status': 'APPLIED'},
                  ),
                  result: {'status': 'APPLIED'},
                ),
              ],
            ),
          ),
        );
        await _pump(
          tester,
          repo: repo,
          pushUri: '${RouteName.hrReconcile}?planId=plan-1',
        );
        final table = _table(tester);
        expect(table.selectable, isFalse);
        expect(table.batchActionsBuilder, isNull);
        expect(find.byKey(const Key('hr-reconcile-apply')), findsNothing);
        expect(find.byKey(const Key('hr-reconcile-select-high')), findsNothing);
        expect(find.text('已更正'), findsWidgets);
        expect(find.text(_kBrokenId), findsNothing);
        expect(find.text(_kValidId), findsOneWidget);
        final input = tester.widget<TextField>(
          find.byKey(const ValueKey('hr-reconcile-manual-1')),
        );
        expect(input.enabled, isFalse);
        expect(input.controller?.text ?? '', isEmpty);
        expect(repo.applies, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'records paginate to older completed plans and open read-only details',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo =
          _FakeRepo(
              HrReconcilePlan.fromJson(
                _planJson(
                  id: 'older-plan',
                  status: 'CLOSED',
                  closedReason: 'EXPIRED',
                  canApply: false,
                  rows: [
                    _rowJson(
                      item: _itemJson(
                        newValue: _kValidId,
                        outcome: {'status': 'APPLIED'},
                      ),
                      result: {'status': 'APPLIED'},
                    ),
                  ],
                ),
              ),
            )
            ..recordPages[1] = _recordsPage(1, ['newer-plan'], totalPages: 2)
            ..recordPages[2] = _recordsPage(2, ['older-plan'], totalPages: 2);
      await _pump(tester, repo: repo);
      await tester.tap(find.byKey(const Key('hr-reconcile-records')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-newer-plan')),
        findsOneWidget,
      );
      var pager = tester.widget<UtenGridPager>(
        find.byKey(const Key('hr-reconcile-records-pager')),
      );
      expect(pager.onPrev, isNull);
      pager.onNext!();
      await tester.pumpAndSettle();
      expect(repo.recordPagesRequested, [1, 2]);
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-newer-plan')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-older-plan')),
        findsOneWidget,
      );
      pager = tester.widget<UtenGridPager>(
        find.byKey(const Key('hr-reconcile-records-pager')),
      );
      expect(pager.currentPage, 2);
      expect(pager.onNext, isNull);
      expect(pager.onPrev, isNotNull);
      await tester.tap(
        find.byKey(const ValueKey('hr-reconcile-record-older-plan')),
      );
      await tester.pumpAndSettle();
      expect(repo.fetched.last, 'older-plan');
      expect(_table(tester).selectable, isFalse);
      expect(find.text('已更正'), findsWidgets);
      expect(repo.created, isEmpty);
      expect(repo.applies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('records page failure can retry the same page', (tester) async {
    final repo = _FakeRepo(HrReconcilePlan.fromJson(_planJson(rows: const [])))
      ..recordPages[1] = _recordsPage(1, ['newer-plan'], totalPages: 2)
      ..recordPages[2] = _recordsPage(2, ['older-plan'], totalPages: 2)
      ..recordPageErrors[2] = StateError('failed page');
    await _pump(tester, repo: repo);
    await tester.tap(find.byKey(const Key('hr-reconcile-records')));
    await tester.pumpAndSettle();
    tester
        .widget<UtenGridPager>(
          find.byKey(const Key('hr-reconcile-records-pager')),
        )
        .onNext!();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('hr-reconcile-record-newer-plan')),
      findsNothing,
    );
    repo.recordPageErrors.remove(2);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repo.recordPagesRequested, [1, 2, 2]);
    expect(
      find.byKey(const ValueKey('hr-reconcile-record-older-plan')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pii edit alone cannot list global records from the reconcile page',
    (tester) async {
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(_planJson(rows: const [])),
      );
      await _pump(
        tester,
        repo: repo,
        permissions: {Perm.employeeView, Perm.employeePiiEdit},
      );
      expect(find.byKey(const Key('hr-reconcile-records')), findsNothing);
      expect(find.text('核对记录'), findsNothing);
      expect(repo.listCalls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'records stop showing rows when the listing permission is revoked',
    (tester) async {
      final permissions = StateProvider<Set<String>>(
        (_) => {Perm.employeeView, Perm.employeeEdit},
      );
      final repo = _FakeRepo(
        HrReconcilePlan.fromJson(_planJson(rows: const [])),
      )..plansPage = _recordsPage(1, ['private-plan']);
      await _pump(tester, repo: repo, permissionState: permissions);
      await tester.tap(find.byKey(const Key('hr-reconcile-records')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-private-plan')),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      container.read(permissions.notifier).state = {
        Perm.employeeView,
        Perm.employeePiiEdit,
      };
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-private-plan')),
        findsNothing,
      );
      expect(find.byKey(const Key('hr-reconcile-records-pager')), findsNothing);
      expect(find.text('当前账号没有查看核对记录的权限'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'records discard a late page response after the account changes',
    (tester) async {
      final oldResponse = Completer<HrReconcilePlanSummaryPage>();
      final session = StateProvider<String>((_) => 'session-old');
      final repo =
          _FakeRepo(HrReconcilePlan.fromJson(_planJson(rows: const [])))
            ..delayedRecordResponses.add(oldResponse.future)
            ..plansPage = _recordsPage(1, ['current-plan']);
      await _pump(tester, repo: repo, recordSessionState: session);
      await tester.tap(find.byKey(const Key('hr-reconcile-records')));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HrReconcilePage)),
      );
      container.read(session.notifier).state = 'session-current';
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-current-plan')),
        findsOneWidget,
      );
      oldResponse.complete(_recordsPage(1, ['previous-account-plan']));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-current-plan')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('hr-reconcile-record-previous-account-plan')),
        findsNothing,
      );
      expect(repo.recordPagesRequested, [1, 1]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('生成流程：employeeIds → POST → pushReplacement 带上 planId → 渲染行', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            _rowJson(
              rowNo: 2,
              kind: 'INFO',
              employeeId: 'emp-2',
              name: '赵六',
              item: _itemJson(oldValue: '450303199001012628', tier: 'NONE'),
            ),
          ],
        ),
      ),
    );
    final routeUris = <String>[];
    await _pump(
      tester,
      repo: repo,
      pushUri: RoutePath.hrReconcile(
        employeeIds: const ['emp-1', 'emp-2'],
        returnTo: '/hr/tasks/identity',
      ),
      routeUris: routeUris,
    );

    expect(repo.created.single, ['emp-1', 'emp-2'], reason: '带员工列表生成计划');
    expect(routeUris, isNotEmpty);
    final location = routeUris.last;
    expect(location, contains('planId=plan-1'), reason: '生成后换参为可恢复深链');
    expect(
      location,
      contains('employeeIds=emp-1%2Cemp-2'),
      reason: '深链保留 employeeIds 供过期重核对',
    );
    expect(find.text(_kBrokenId), findsNothing);
    expect(find.text(_kValidId), findsOneWidget, reason: '唯一建议只读');
    expect(find.text('高'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('hr-reconcile-manual-1')),
          )
          .controller!
          .text,
      isEmpty,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HIGH 默认建议不填入：必须手填后勾选确认', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(
      find.byKey(const ValueKey('hr-reconcile-adopt-1')),
      findsNothing,
      reason: '已预选：不出现「采用」按钮',
    );
    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('hr-reconcile-manual-1')),
          )
          .controller!
          .text,
      isEmpty,
    );
    await _typeManual(tester, 1, '1101051949');
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget, reason: '非法手输不能回退为建议');
    await _typeManual(tester, 1);
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MEDIUM 建议只读，手填后计数 +1', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(
              item: _itemJson(
                newValue: _kValidId,
                tier: 'MEDIUM',
                probability: 0.72,
              ),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget, reason: '未采用不计入');

    expect(find.byKey(const ValueKey('hr-reconcile-adopt-1')), findsNothing);
    await _typeManual(tester, 1);
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget, reason: '手填后计数 +1');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MANUAL 仅一个空输入框，不显示候选百分比或错误位', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(
              item: _itemJson(
                tier: 'MANUAL',
                candidates: [
                  {
                    'value': '450303199001012646',
                    'probability': 0.9,
                    'diffPositions': [10],
                  },
                  {
                    'value': '450303199001012628',
                    'probability': 0.6,
                    'diffPositions': [10],
                  },
                ],
                suspectPositions: const [10, 17],
              ),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(find.textContaining('可能出错的位置'), findsNothing);
    expect(find.textContaining('90%'), findsNothing);
    expect(
      find.byKey(const ValueKey('hr-reconcile-candidate-1-0')),
      findsNothing,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('hr-reconcile-manual-1')),
          )
          .controller!
          .text,
      isEmpty,
    );
    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);
    await _typeManual(tester, 1);
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手输：非法红字不计入，合法计入并放行提交', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(
              item: _itemJson(tier: 'MANUAL', basisCode: ''),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );
    final field = find.byKey(const ValueKey('hr-reconcile-manual-1'));
    expect(field, findsOneWidget, reason: 'MANUAL 行有手输区');

    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();

    // 17 位：非法 → 即时错误（UtenInputDecoration 收进输入框内披露图标）+ 不计数。
    // 注意限定在手输框内找图标：表头的列说明 ⓘ 也是 UtenFieldHintIcon。
    await tester.enterText(field, '11010519491231002');
    await tester.pump();
    expect(
      tester
          .widget<UtenFieldHintIcon>(
            find.descendant(
              of: field,
              matching: find.byType(UtenFieldHintIcon),
            ),
          )
          .errorMessage,
      '身份证号应为18位，当前为17位',
      reason: 'problemOf 的那句话即时出现',
    );
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);

    // 补上校验位：合法 → 计入。
    await tester.enterText(field, _kValidId);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: field, matching: find.byType(UtenFieldHintIcon)),
      findsNothing,
      reason: '合法输入不再带错误提示',
    );
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    // 放行提交（提交体细节见下一用例）。
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    expect(find.text('确认更正员工资料'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('提交体：所有类型只提交手输 value，无候选下标，requestId ≤64', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          version: 3,
          rows: [
            // 行1：HIGH 预选 → 采用建议（candidate/value 都不带）。
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            // 行2：MANUAL 候选 → candidateIndex。
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              name: '赵六',
              item: _itemJson(
                tier: 'MANUAL',
                candidates: [
                  {
                    'value': '45030319900101264X',
                    'probability': 0.8,
                    'diffPositions': [17],
                  },
                ],
              ),
            ),
            // 行3：NONE 手输 → value。
            _rowJson(
              rowNo: 3,
              employeeId: 'emp-3',
              name: '钱七',
              item: _itemJson(tier: 'NONE', basisCode: ''),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    await _typeManual(tester, 1);
    await _typeManual(tester, 2);
    await tester.enterText(
      find.byKey(const ValueKey('hr-reconcile-manual-3')),
      _kValidId,
    );
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'emp-1', 'emp-2', 'emp-3'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 3 人 3 处'), findsOneWidget);

    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    expect(find.text('确认更正员工资料'), findsOneWidget);
    expect(find.text('性别与出生日期将按新证件号自动更正'), findsOneWidget);
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();

    expect(repo.applies, hasLength(1));
    final call = repo.applies.single;
    expect(call.planId, 'plan-1');
    expect(call.planVersion, 3);
    expect(call.requestId, isNotEmpty);
    expect(call.requestId.length, lessThanOrEqualTo(64));
    expect(call.rows.map((r) => r.rowNo), [1, 2, 3]);
    final byRow = {for (final row in call.rows) row.rowNo: row};
    // 行1：建议预选 → 都不带 = 采用建议 newValue。
    final item1 = byRow[1]!.items.single;
    expect(item1.candidateIndex, isNull);
    expect(item1.value, _kValidId);
    // 行2：候选 → candidateIndex=0、value 不带。
    final item2 = byRow[2]!.items.single;
    expect(item2.candidateIndex, isNull);
    expect(item2.value, _kValidId);
    // 行3：手输 → value、candidateIndex 不带。
    final item3 = byRow[3]!.items.single;
    expect(item3.candidateIndex, isNull);
    expect(item3.value, _kValidId);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('apply 成功：结果列「已更正」渲染，返回 pop(true)', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo =
        _FakeRepo(
            HrReconcilePlan.fromJson(
              _planJson(
                rows: [
                  _rowJson(
                    item: _itemJson(newValue: _kValidId, preselected: true),
                  ),
                ],
              ),
            ),
          )
          ..applyResult = const HrReconcileApplyResult(
            planVersion: 2,
            round: 1,
            counts: HrReconcileApplyCounts(applied: 1, skipped: 0, failed: 0),
            rows: [],
            summary: '已更正 1 人 1 处，完成',
          );
    repo.planAfterApply = HrReconcilePlan.fromJson(
      _planJson(
        version: 2,
        rows: [
          _rowJson(
            item: _itemJson(
              newValue: _kValidId,
              preselected: true,
              outcome: {'status': 'APPLIED', 'code': null, 'message': null},
            ),
            result: {'status': 'APPLIED', 'message': null},
          ),
        ],
      ),
    );
    bool? popped;
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
      onResult: (v) => popped = v,
    );

    await _typeManual(tester, 1);
    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();

    expect(repo.applies, hasLength(1));
    expect(
      _noticeMessages(tester),
      contains('已更正 1 人 1 处，完成'),
      reason: '顶部通知显示服务端 summary',
    );
    expect(
      find.byKey(const ValueKey('hr-reconcile-row-result-1')),
      findsOneWidget,
    );
    expect(
      find.text('已更正'),
      findsWidgets,
      reason: '结果列渲染「已更正」(项级 outcome + 行级 result)',
    );

    // 用户手动返回 → pop(true)，列表页据此刷新。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('409 RECONCILE_PLAN_CHANGED：提示并自动重取（保留草稿）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo =
        _FakeRepo(
            HrReconcilePlan.fromJson(
              _planJson(
                rows: [
                  _rowJson(
                    item: _itemJson(newValue: _kValidId, preselected: true),
                  ),
                ],
              ),
            ),
          )
          ..applyError = ApiException(
            'CONFLICT',
            '核对计划已变更',
            httpStatus: 409,
            fieldErrors: const [
              ApiFieldError(
                field: 'errorCode',
                message: 'RECONCILE_PLAN_CHANGED',
              ),
            ],
          );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(repo.getPlanCalls, 1, reason: '首次进入 GET 一次');
    await _typeManual(tester, 1);
    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();

    expect(repo.getPlanCalls, 2, reason: '409 CHANGED 自动重取计划');
    expect(_noticeMessages(tester), contains('这份核对已被更新，已重新加载最新内容'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('他人认领行：idOf 为 null，勾选位换成带认领人的锁', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(item: _itemJson(newValue: _kValidId)),
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              name: '赵六',
              claim: {
                'byName': '王某',
                'byMe': false,
                'leaseUntil': '2026-10-05T10:00:00+08:00',
              },
              item: _itemJson(newValue: _kValidId),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    final table = _table(tester);
    expect(table.idOf!(_row(tester, 'emp-1')), 'emp-1');
    expect(table.idOf!(_row(tester, 'emp-2')), isNull, reason: '他人处理中不可勾选');
    expect(table.rowKeyOf!(_row(tester, 'emp-2')), 'emp-2');
    expect(
      tester.widgetList<Tooltip>(find.byType(Tooltip)).map((t) => t.message),
      contains('王某 处理中'),
      reason: '锁图标悬停可见认领人',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无参进入：空态引导 +「核对记录」入口', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(HrReconcilePlan.fromJson(_planJson(rows: const [])));
    await _pump(tester, repo: repo);

    expect(find.text('请从「证件核对」页勾选员工后进入'), findsOneWidget);
    expect(find.text('核对记录'), findsWidgets, reason: '空态带核对记录入口');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('viewPii=false：打码显示且不做差异位高亮', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          viewPii: false,
          rows: [
            _rowJson(
              item: _itemJson(
                oldValue: '****2646',
                newValue: '****002X',
                diffPositions: const [],
                preselected: true,
              ),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(find.text('****2646'), findsNothing);
    expect(find.text('****002X'), findsOneWidget, reason: '建议沿用服务端打码');
    expect(
      tester
              .widget<TextField>(
                find.byKey(const ValueKey('hr-reconcile-manual-1')),
              )
              .controller
              ?.text ??
          '',
      isEmpty,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('375 宽窄屏：同一张表格渲染不炸', (tester) async {
    tester.view.physicalSize = const Size(375, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(
              item: _itemJson(
                tier: 'MANUAL',
                basisCode: '',
                candidates: [
                  {
                    'value': '45030319900101264X',
                    'probability': 0.9,
                    'diffPositions': [17],
                  },
                ],
                suspectPositions: const [17],
              ),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(tester.takeException(), isNull, reason: '375 宽不溢出');
    expect(
      find.byKey(const ValueKey('hr-reconcile-manual-1')),
      findsOneWidget,
      reason: '窄屏表格里手输区可用',
    );
    // 员工合并列的 cellBuilder(姓名主行 + 工号·部门副行)在表格格内照常渲染。
    expect(find.text('王五'), findsOneWidget);
    expect(find.text('UT0050'), findsOneWidget);
    expect(find.text('装配第一车间'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('摘要保留进度，去掉把握分类并说明人工确认', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            // 两行 HIGH + 一行 MANUAL：胶囊 高把握 2 / 需人工 1，中把握不出现。
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              name: '赵六',
              item: _itemJson(newValue: _kValidId, preselected: true),
            ),
            _rowJson(
              rowNo: 3,
              employeeId: 'emp-3',
              name: '钱七',
              item: _itemJson(tier: 'MANUAL', basisCode: ''),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(find.text('待核对 3 人'), findsOneWidget);
    expect(find.text('需更正 3'), findsOneWidget, reason: 'kind 副行');
    expect(find.text('高把握 2'), findsNothing);
    expect(find.text('需人工 1'), findsNothing);
    expect(find.text('建议仅供核对。所有证件号码请手动填写，勾选后确认更正。'), findsOneWidget);
    expect(find.textContaining('中把握'), findsNothing, reason: '0 值档不占位');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('员工拆为四列，唯一建议紧邻证件号码左侧', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    final columns = _table(tester).columns;
    expect(columns.map((c) => c.key), [
      'kind',
      'name',
      'code',
      'department',
      'position',
      'reason',
      'suggestion',
      'field-idNumber',
      'notes',
    ]);
    expect(columns.map((c) => c.label), [
      '类型',
      '姓名',
      '工号',
      '部门',
      '职位',
      '原因',
      '建议',
      '证件号码',
      '说明/结果',
    ]);
    expect(find.text('王五'), findsOneWidget);
    expect(find.text('UT0050'), findsOneWidget);
    expect(find.text('装配第一车间'), findsOneWidget);
    expect(find.text('操作工'), findsOneWidget, reason: '服务端实际职位');
    expect(find.text('UT0050 · 装配第一车间'), findsNothing);
    expect(_table(tester).tableKey, endsWith('.manual_v2'));
    expect(
      find.byKey(const ValueKey('hr-reconcile-suggestion-1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('hr-reconcile-tier-1')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无高把握批选，填入但未显式勾选仍不能提交', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(
      HrReconcilePlan.fromJson(
        _planJson(
          rows: [
            _rowJson(item: _itemJson(newValue: _kValidId, preselected: true)),
            _rowJson(
              rowNo: 2,
              employeeId: 'emp-2',
              name: '赵六',
              claim: {
                'byName': '王某',
                'byMe': false,
                'leaseUntil': '2026-10-05T10:00:00+08:00',
              },
              item: _itemJson(newValue: _kValidId, preselected: true),
            ),
            _rowJson(
              rowNo: 3,
              employeeId: 'emp-3',
              name: '钱七',
              item: _itemJson(tier: 'MANUAL', basisCode: ''),
            ),
          ],
        ),
      ),
    );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    expect(find.byKey(const Key('hr-reconcile-select-high')), findsNothing);
    await _typeManual(tester, 1);
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);
    expect(_table(tester).selectedIds, isEmpty);
    expect(repo.applies, isEmpty);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('hr-reconcile-manual-2')),
          )
          .enabled,
      isFalse,
      reason: '他人认领不开放填写',
    );
    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('409 重取后残留选中含已执行行：请求体只带未执行行(与弹窗计数同口径)', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appliedJson = _itemJson(
      newValue: _kValidId,
      preselected: true,
      outcome: {'status': 'APPLIED', 'code': null, 'message': null},
    );
    final repo =
        _FakeRepo(
            HrReconcilePlan.fromJson(
              _planJson(
                rows: [
                  // 行1：重取后已被执行(result=APPLIED)。
                  _rowJson(
                    item: appliedJson,
                    result: {'status': 'APPLIED', 'message': null},
                  ),
                  // 行2：仍待执行。
                  _rowJson(
                    rowNo: 2,
                    employeeId: 'emp-2',
                    name: '赵六',
                    item: _itemJson(newValue: _kValidId, preselected: true),
                  ),
                ],
              ),
            ),
          )
          // 首轮 apply 抛 CHANGED 触发自动重取(返回上面的已执行版本)；
          // 之后清掉错误，允许第二轮成功。
          ..applyError = ApiException(
            'CONFLICT',
            '核对计划已变更',
            httpStatus: 409,
            fieldErrors: const [
              ApiFieldError(
                field: 'errorCode',
                message: 'RECONCILE_PLAN_CHANGED',
              ),
            ],
          );
    await _pump(
      tester,
      repo: repo,
      pushUri: '${RouteName.hrReconcile}?planId=plan-1',
    );

    // 选中两行(含已执行行)后首轮 apply → 409 → 自动重取，勾选残留。
    await _typeManual(tester, 2);
    _table(tester).onSelectedIdsChanged!({'emp-1', 'emp-2'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();
    expect(repo.getPlanCalls, 2, reason: '409 CHANGED 自动重取计划');

    // 重取后行1 已执行：按钮计数只剩行2(勾选残留但不复活已执行行)。
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);
    repo.applyError = null;

    // 二轮提交：请求体必须只带 rowNo=2，不带已执行的 rowNo=1。
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();
    expect(repo.applies, hasLength(2));
    expect(
      repo.applies.last.rows.map((r) => r.rowNo),
      [2],
      reason: '已执行行不进请求体(与 _applyCounts 弹窗口径一致)',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
