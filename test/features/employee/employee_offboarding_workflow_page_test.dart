import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_offboarding_workflow_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('no-data offboarding needs no successor and sends stable code', (
    tester,
  ) async {
    final employees = _EmployeeRepositoryFake();
    final handover = _HandoverRepositoryFake(_noDataPreview);
    final router = _router();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeRepositoryProvider.overrideWithValue(employees),
          dataHandoverRepositoryProvider.overrideWithValue(handover),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('离职员工'), findsWidgets);
    await _fillDepartureAndContinue(tester);
    expect(find.text('当前没有需要移交的责任数据，可不选择默认接手人。'), findsOneWidget);

    await _tapNext(tester); // 数据盘点
    expect(find.text('没有需要交接的数据'), findsOneWidget);
    await _tapNext(tester); // 回收确认
    for (final label in const [
      '已线下确认门禁卡回收',
      '已线下确认公司资产已清点并完成回收安排',
      '已知悉：交接与离职事务成功后系统自动停用账号',
      '已线下确认社保公积金停缴安排',
    ]) {
      final item = find.text(label);
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pumpAndSettle();
    }
    await _tapNext(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认办理离职'),
      ),
    );
    await tester.pumpAndSettle();

    expect(employees.offboardBody, isNotNull);
    expect(employees.offboardBody!['requestId'], isA<String>());
    expect((employees.offboardBody!['requestId'] as String), isNotEmpty);
    expect(employees.offboardBody!['resignType'], 'VOLUNTARY');
    expect(employees.offboardBody!['reason'], '个人原因');
    expect(employees.offboardBody!['confirmedChecklistCodes'], const [
      'ACCESS_CARD_RETURNED',
      'COMPANY_ASSETS_ACCOUNTED',
      'ACCOUNT_DISABLE_ACKNOWLEDGED',
      'SOCIAL_BENEFITS_ARRANGED',
    ]);
    expect(employees.offboardBody, isNot(contains('successorEmployeeId')));
    expect(employees.offboardBody, isNot(contains('handoverRequestId')));
    expect(find.text('员工详情'), findsOneWidget);
  });

  testWidgets('requires-target preview blocks continuing without successor', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeRepositoryProvider.overrideWithValue(
            _EmployeeRepositoryFake(),
          ),
          dataHandoverRepositoryProvider.overrideWithValue(
            _HandoverRepositoryFake(_requiresTargetPreview),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await _fillDepartureAndContinue(tester);
    await _tapNext(tester);

    expect(find.textContaining('默认承接尚未交接的责任'), findsOneWidget);
    expect(find.text('2. 选择默认接手人'), findsOneWidget);
  });

  testWidgets('375px dark mode with large text remains operable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeRepositoryProvider.overrideWithValue(
            _EmployeeRepositoryFake(),
          ),
          dataHandoverRepositoryProvider.overrideWithValue(
            _HandoverRepositoryFake(_noDataPreview),
          ),
        ],
        child: MaterialApp.router(
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          routerConfig: _router(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1. 离职信息'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('employee-offboarding-next')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _fillDepartureAndContinue(WidgetTester tester) async {
  await tester.tap(find.text('请选择日期'));
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byType(TextButton),
        )
        .last,
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find
        .descendant(
          of: find.byType(UtenInput),
          matching: find.byType(TextField),
        )
        .first,
    '个人原因',
  );
  await _tapNext(tester);
}

Future<void> _tapNext(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('employee-offboarding-next')));
  await tester.pumpAndSettle();
}

GoRouter _router() => GoRouter(
  initialLocation: '/employee/source-1/offboarding',
  routes: [
    GoRoute(
      path: '/employee/:id/offboarding',
      builder: (_, state) => EmployeeOffboardingWorkflowPage(
        employeeId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/employee/:id',
      builder: (_, _) => const Scaffold(body: Text('员工详情')),
    ),
  ],
);

const _noDataPreview = DataHandoverPreview(
  sourceEmployeeId: 'source-1',
  scopes: {},
  items: [],
  hasBlockers: false,
  requiresTarget: false,
  total: 0,
);

const _requiresTargetPreview = DataHandoverPreview(
  sourceEmployeeId: 'source-1',
  scopes: {'client'},
  items: [
    DataHandoverPreviewItem(
      key: 'target.required',
      label: '存在需交接的数据，请选择接手人',
      scope: 'all',
      count: 1,
      action: DataHandoverAction.blocking,
    ),
  ],
  hasBlockers: true,
  requiresTarget: true,
  total: 1,
);

class _EmployeeRepositoryFake implements EmployeeRepository {
  Map<String, dynamic>? offboardBody;

  @override
  Future<EmployeeProfile> getById(String id) async => const EmployeeProfile(
    id: 'source-1',
    code: 'E001',
    fullName: '离职员工',
    departmentName: '销售一组',
    positionName: '销售员',
    status: 'active',
  );

  @override
  Future<void> offboard(String id, Map<String, dynamic> body) async {
    offboardBody = body;
  }

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async => PagedResult(
    items: const [],
    page: page,
    size: size,
    total: 0,
    totalPages: 0,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HandoverRepositoryFake extends DataHandoverRepository {
  _HandoverRepositoryFake(this.preview)
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost'))));

  final DataHandoverPreview preview;

  @override
  Future<DataHandoverPreview> employeePreview(
    String sourceEmployeeId, {
    String? successorEmployeeId,
  }) async => preview;
}
