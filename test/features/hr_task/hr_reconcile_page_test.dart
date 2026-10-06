// 员工资料核对更正页(ADR-160)：生成计划/逐行确认(建议·候选·手输)/提交体语义/
// 执行结果渲染/409 冲突自动重取/他人认领锁/空态/打码/窄屏卡片。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_revision_cell.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_card_list.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/hr_task/models/hr_reconcile_plan.dart';
import 'package:uten_imp/features/hr_task/pages/hr_reconcile_page.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_reconcile_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 与后端 IdCardUtil 校验一致的真实合法号码（手输用例必须过校验）。
const _kValidId = '11010519491231002X';
const _kBrokenId = '450303199001012646';

class _FakeRepo extends Fake implements HrReconcileRepository {
  /// createIdRepairPlan 的返回，也作为 getPlan 的默认返回。
  HrReconcilePlan plan;

  /// apply 成功后 getPlan 改回这份（结果列渲染）。
  HrReconcilePlan? planAfterApply;
  bool _applied = false;
  HrReconcileApplyResult? applyResult;
  Object? applyError;
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
    return plan;
  }

  @override
  Future<HrReconcilePlan> getPlan(String id) async {
    getPlanCalls++;
    fetched.add(id);
    return _applied ? (planAfterApply ?? plan) : plan;
  }

  @override
  Future<HrReconcilePlanSummaryPage> listPlans({
    int page = 1,
    int size = 50,
  }) async {
    listCalls++;
    return plansPage;
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
      ],
      child: MaterialApp.router(
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

List<String> _noticeMessages(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HrReconcilePage)),
  listen: false,
).read(appNotificationProvider).map((n) => n.message).toList();

void main() {
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
    // 行渲染：旧值/新值对照 + 把握徽标。
    expect(find.byType(UtenRevisionCell), findsNWidgets(2));
    expect(find.text(_kBrokenId), findsOneWidget);
    expect(find.text(_kValidId), findsOneWidget);
    expect(find.text('高'), findsOneWidget, reason: 'HIGH 把握徽标');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HIGH 默认采用：勾选即得「确认更正 1 人 1 处」', (tester) async {
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
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MEDIUM 未预选：点「采用」后计数 +1', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('hr-reconcile-adopt-1')));
    await tester.pumpAndSettle();
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget, reason: '采用后计数 +1');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MANUAL 候选 chip：点击采用', (tester) async {
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

    // 可疑位提示 + 候选 chips 都在。
    expect(find.textContaining('可能出错的位置'), findsOneWidget);
    expect(find.textContaining('90%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hr-reconcile-candidate-1-0')),
      findsOneWidget,
    );

    _table(tester).onSelectedIdsChanged!({'emp-1'});
    await tester.pumpAndSettle();
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hr-reconcile-candidate-1-0')));
    await tester.pumpAndSettle();
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
    await tester.enterText(field, '11010519491231002');
    await tester.pump();
    expect(
      tester
          .widget<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon))
          .errorMessage,
      '身份证号应为18位，当前为17位',
      reason: 'problemOf 的那句话即时出现',
    );
    expect(find.text('确认更正 0 人 0 处'), findsOneWidget);

    // 补上校验位：合法 → 计入。
    await tester.enterText(field, _kValidId);
    await tester.pumpAndSettle();
    expect(find.byType(UtenFieldHintIcon), findsNothing, reason: '合法输入不再带错误提示');
    expect(find.text('确认更正 1 人 1 处'), findsOneWidget);

    // 放行提交（提交体细节见下一用例）。
    await tester.tap(find.byKey(const Key('hr-reconcile-apply')));
    await tester.pumpAndSettle();
    expect(find.text('确认更正员工资料'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('提交体：rows 只含已确认行，candidateIndex/value 语义正确，requestId ≤64', (
    tester,
  ) async {
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

    await tester.tap(find.byKey(const ValueKey('hr-reconcile-candidate-2-0')));
    await tester.pumpAndSettle();
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
    expect(item1.value, isNull);
    // 行2：候选 → candidateIndex=0、value 不带。
    final item2 = byRow[2]!.items.single;
    expect(item2.candidateIndex, 0);
    expect(item2.value, isNull);
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

    expect(find.text('****2646'), findsOneWidget);
    final cell = tester.widget<UtenRevisionCell>(find.byType(UtenRevisionCell));
    expect(cell.masked, isTrue, reason: '无 pii:view 不做逐位差异高亮');
    expect(cell.changedPositions, isEmpty);
    expect(cell.before, '****2646');
    expect(cell.after, '****002X');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('375 宽窄屏：卡片形态渲染不炸', (tester) async {
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
      find.byType(MasterDataCardList<HrReconcileRow>),
      findsOneWidget,
      reason: '窄屏走卡片形态',
    );
    expect(
      find.byKey(const ValueKey('hr-reconcile-manual-1')),
      findsOneWidget,
      reason: '卡片里手输区可用',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
