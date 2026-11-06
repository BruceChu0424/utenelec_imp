import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/employee_reference.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/repositories/employee_reference_repository.dart';
import 'package:uten_imp/shared/widgets/business_employee_picker.dart';

import '../../support/warehouse_receiver_permissions.dart';

const _purpose = EmployeeReferencePurpose.warehouseArrivalReceiver;
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'warehouse-actor', epoch: 1),
);
final _permissions = StateProvider<Set<String>>(
  (_) => actualWarehouseReceiverPermissions,
);
final _server = StateProvider<String>((_) => 'https://api.example.test');

void main() {
  testWidgets(
    'exact ID label resolution does not also search the candidate directory',
    (tester) async {
      final api = _ReferenceApi()
        ..pendingLabels = Completer<List<Map<String, dynamic>>>();
      await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: 'e1',
          label: '收货人',
          initial: const UtenEmployeePickerItem(id: 'e1', name: '原单姓名'),
          onChanged: (_) {},
        ),
      );
      expect(api.labelQueries, hasLength(1));
      expect(
        api.queries,
        isEmpty,
        reason:
            'Only the authoritative ID lookup is needed to enhance the recorded label.',
      );
      api.pendingLabels!.complete([_row(1)]);
      await tester.pumpAndSettle();
      expect(find.textContaining('测试人员1'), findsOneWidget);
      expect(find.text('原单姓名'), findsNothing);
      expect(api.queries, isEmpty);
      await tester.tap(find.byType(InputDecorator).first);
      await tester.pumpAndSettle();
      expect(api.queries.map((query) => query['page']), [1, 2]);
      final complete = tester
          .widget<MasterDataTableView<UtenEmployeePickerItem>>(
            find.byKey(const Key('uten-employee-picker-candidates')),
          );
      expect(complete.items.map((item) => item.id), [
        for (var index = 1; index <= 101; index++) 'e$index',
      ]);
      final search = find.descendant(
        of: find.byKey(const Key('uten-employee-picker-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '后页职位');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.queries.map((query) => query['page']), [1, 2, 1]);
      expect(api.queries.last['search'], '后页职位');
      expect(
        find.byKey(const ValueKey('employee-picker-item-e101')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'read-only business view resolves an ID without candidates tree edit or HR',
    (tester) async {
      final api = _ReferenceApi();
      await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: 'e1',
          label: '收货人',
          enabled: false,
          onChanged: (_) {},
        ),
        permissions: {Perm.warehouseInboundView},
      );
      expect(find.textContaining('测试人员1'), findsOneWidget);
      expect(api.labelQueries, hasLength(1));
      expect(api.queries, isEmpty);
      expect(api.departmentReads, 0);
      expect(api.hrReads, 0);
      expect(
        tester
            .widget<UtenEmployeePicker>(find.byType(UtenEmployeePicker))
            .enabled,
        false,
      );
    },
  );
  test(
    'concurrent label hydration is single flight but never a permanent label cache',
    () async {
      final api = _ReferenceApi()
        ..pendingLabels = Completer<List<Map<String, dynamic>>>();
      final repository = DioEmployeeReferenceRepository(api);
      final first = repository.byIds(['e1'], purpose: _purpose);
      final second = repository.byIds(['e1'], purpose: _purpose);
      expect(api.labelQueries, hasLength(1));
      api.pendingLabels!.complete([_row(1)]);
      final values = await Future.wait([first, second]);
      expect(values.map((rows) => rows.single.id), ['e1', 'e1']);
      api.pendingLabels = null;
      await repository.byIds(['e1'], purpose: _purpose);
      expect(api.labelQueries, hasLength(2));
    },
  );

  testWidgets(
    'only original inbound view and stock_in can load the purpose department tree',
    (tester) async {
      final api = _ReferenceApi();
      final container = await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: null,
          label: '收货人',
          departmentCode: 'SUB_WH',
          onChanged: (_) {},
        ),
        permissions: {Perm.warehouseInboundView, Perm.warehouseInboundStockIn},
      );
      expect(container.read(currentPermissionsProvider), hasLength(2));
      await tester.tap(find.byType(InputDecorator).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('uten-employee-picker-candidates')),
        findsOneWidget,
      );
      expect(api.hrReads, 0);
      expect(api.queries.first['departmentId'], 'warehouse-dept');
    },
  );
  test(
    'reference pages retain purpose and filters with explicit complete continuation',
    () async {
      final api = _ReferenceApi();
      final repository = DioEmployeeReferenceRepository(api);
      Future<UtenEmployeePickerPage> read(int page) =>
          repository.listPickerPage(
            UtenEmployeePickerQuery(page: page),
            purpose: _purpose,
            statuses: {'active', 'probation'},
            departmentId: 'warehouse-dept',
            includeSubtree: true,
          );
      final first = await read(1);
      expect(api.queries.map((q) => q['page']), [1]);
      expect(first.items, hasLength(100));
      final last = await read(2);
      expect([...first.items, ...last.items], hasLength(101));
      expect(last.items.last.positionName, '后页职位');
      expect(api.queries.map((q) => q['page']), [1, 2]);
      for (final query in api.queries) {
        expect(query['purpose'], _purpose.apiValue);
        expect(query['statuses'], unorderedEquals(['active', 'probation']));
        expect(query['departmentId'], 'warehouse-dept');
        expect(query['includeSubtree'], true);
      }
      expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
    },
  );

  test(
    'byIds is a separate deduplicated label lookup and does not invent missing staff',
    () async {
      final api = _ReferenceApi();
      final repository = DioEmployeeReferenceRepository(api);
      expect(await repository.byIds([], purpose: _purpose), isEmpty);
      final rows = await repository.byIds([
        'e1',
        'e1',
        'deleted',
      ], purpose: _purpose);
      expect(rows.map((row) => row.id), ['e1']);
      expect(api.labelQueries.single['ids'], 'e1,deleted');
      expect(api.queries, isEmpty);
      final item = rows.single.toPickerItem();
      expect(item.accountStatus, 'disabled');
      expect(item.employmentStatus, 'resigned');
      expect(
        item.enabled,
        true,
        reason: 'status is not an invented command eligibility rule',
      );
      await expectLater(
        repository.byIds(List.generate(101, (i) => 'e$i'), purpose: _purpose),
        throwsArgumentError,
      );
    },
  );

  test(
    '403 and malformed pagination remain errors rather than empty successful lists',
    () async {
      final api = _ReferenceApi()
        ..listError = ApiException(
          'PERMISSION_DENIED',
          '业务人员引用无权限',
          httpStatus: 403,
        );
      final repository = DioEmployeeReferenceRepository(api);
      await expectLater(
        repository.listPickerPage(
          const UtenEmployeePickerQuery(),
          purpose: _purpose,
        ),
        throwsA(isA<ApiException>().having((e) => e.httpStatus, 'status', 403)),
      );
      api.listError = null;
      api.badPage = true;
      await expectLater(
        repository.listPickerPage(
          const UtenEmployeePickerQuery(),
          purpose: _purpose,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INVALID_PAGINATION',
          ),
        ),
      );
      expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
    },
  );

  testWidgets(
    'actual ordinary 52-code warehouse shape can resolve select search and reopen without HR',
    (tester) async {
      final api = _ReferenceApi();
      String? selected = 'e1';
      UtenEmployeePickerItem? snapshot;
      await _pump(
        tester,
        api,
        StatefulBuilder(
          builder: (context, update) => BusinessEmployeePicker(
            purpose: _purpose,
            selectedId: selected,
            label: '收货人',
            required: true,
            initial: snapshot,
            departmentCode: 'SUB_WH',
            onResolved: (value) => snapshot = value,
            onChanged: (value) => update(() {
              selected = value?.id;
              snapshot = value;
            }),
          ),
        ),
      );
      expect(actualWarehouseReceiverPermissions, hasLength(52));
      expect(
        actualWarehouseReceiverPermissions,
        isNot(contains('employee:view')),
      );
      expect(find.textContaining('测试人员1'), findsOneWidget);
      await tester.tap(find.byType(InputDecorator).first);
      await tester.pumpAndSettle();
      var table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
        find.byKey(const Key('uten-employee-picker-candidates')),
      );
      expect(table.items, hasLength(101));
      expect(api.queries.map((query) => query['page']), [1, 2]);
      expect(table.onLoadMore, isNull);
      final completeReadRequests = api.queries.length;
      await tester.drag(
        find.byKey(const Key('uten-employee-picker-candidates')),
        const Offset(0, -5000),
      );
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(completeReadRequests));
      table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
        find.byKey(const Key('uten-employee-picker-candidates')),
      );
      expect(table.items, hasLength(101));
      expect(
        find.byKey(const ValueKey('employee-picker-item-e101')),
        findsOneWidget,
      );
      expect(table.columns.map((column) => column.label), ['工号', '姓名', '部门']);
      expect(find.text('职位'), findsNothing);
      expect(find.text('账号状态'), findsNothing);
      expect(find.text('在职状态'), findsNothing);
      final search = find.descendant(
        of: find.byKey(const Key('uten-employee-picker-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '测试人员101');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.queries.last['search'], '测试人员101');
      expect(api.queries.last.containsKey('departmentId'), false);
      await tester.tap(find.byKey(const ValueKey('employee-picker-item-e101')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(selected, 'e101');
      expect(find.textContaining('测试人员101'), findsOneWidget);
      await tester.tap(find.byType(InputDecorator).first);
      await tester.pumpAndSettle();
      expect(find.byType(UtenEmployeeSelectionPanel), findsOneWidget);
      expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected label lookup failure is visible and never fetches full HR as fallback',
    (tester) async {
      final api = _ReferenceApi()
        ..labelError = ApiException(
          'PERMISSION_DENIED',
          '人员引用明确拒绝',
          httpStatus: 403,
        );
      await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: 'e1',
          label: '收货人',
          onChanged: (_) {},
        ),
      );
      expect(find.text('人员引用明确拒绝'), findsOneWidget);
      expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
    },
  );

  testWidgets('candidate 403 stays visible in the panel', (tester) async {
    final api = _ReferenceApi()
      ..listError = ApiException(
        'PERMISSION_DENIED',
        '候选明确拒绝',
        httpStatus: 403,
      );
    await _pump(
      tester,
      api,
      BusinessEmployeePicker(
        purpose: _purpose,
        selectedId: null,
        label: '收货人',
        onChanged: (_) {},
      ),
    );
    await tester.tap(find.byType(InputDecorator).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('候选明确拒绝'), findsOneWidget);
    expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
  });

  for (final boundary in ['identity', 'server', 'permissions']) {
    testWidgets(
      '$boundary ABA drops late default label and retires the old field',
      (tester) async {
        final api = _ReferenceApi()
          ..pendingLabels = Completer<List<Map<String, dynamic>>>();
        final container = await _pump(
          tester,
          api,
          BusinessEmployeePicker(
            purpose: _purpose,
            selectedId: 'e1',
            label: '收货人',
            onChanged: (_) {},
          ),
        );
        _changeBoundary(container, boundary, true);
        await tester.pump();
        _changeBoundary(container, boundary, false);
        api.pendingLabels!.complete([_row(1)]);
        await tester.pumpAndSettle();
        expect(find.textContaining('测试人员1'), findsNothing);
        expect(
          tester
              .widget<UtenEmployeePicker>(find.byType(UtenEmployeePicker))
              .enabled,
          false,
        );
        expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'identity change between pages cannot publish the old candidates',
    (tester) async {
      final api = _ReferenceApi()
        ..pendingSecondPage = Completer<Map<String, dynamic>>();
      final changes = <UtenEmployeePickerItem?>[];
      final container = await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: null,
          label: '收货人',
          onChanged: changes.add,
        ),
      );
      await tester.tap(find.byType(InputDecorator).first);
      await tester.pump();
      for (var attempt = 0; attempt < 30 && api.queries.length < 2; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(api.queries.map((q) => q['page']), [1, 2]);
      expect(find.byType(UtenEmployeeSelectionPanel), findsOneWidget);
      expect(
        find.byKey(const Key('uten-employee-picker-candidates')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-e1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-e101')),
        findsNothing,
      );
      _changeBoundary(container, 'identity', true);
      await tester.pump();
      api.pendingSecondPage!.complete(_page([_row(101)], 2));
      await tester.pumpAndSettle();
      expect(find.byType(UtenEmployeeSelectionPanel), findsNothing);
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disabled detail preserves its recorded label without write-purpose lookups',
    (tester) async {
      final api = _ReferenceApi();
      await _pump(
        tester,
        api,
        BusinessEmployeePicker(
          purpose: _purpose,
          selectedId: 'historical',
          label: '经办人',
          enabled: false,
          initial: const UtenEmployeePickerItem(
            id: 'historical',
            name: '原单留存姓名',
          ),
          onChanged: (_) {},
        ),
      );
      expect(find.text('原单留存姓名'), findsOneWidget);
      expect(api.labelQueries, isEmpty);
      expect(api.queries, isEmpty);
      expect(api.hrReads, 0, reason: api.unexpectedPaths.join(', '));
    },
  );
}

void _changeBoundary(
  ProviderContainer container,
  String boundary,
  bool changed,
) {
  switch (boundary) {
    case 'identity':
      container.read(_identity.notifier).state = AuthenticatedScope(
        userId: changed ? 'other' : 'warehouse-actor',
        epoch: changed ? 2 : 1,
      );
    case 'server':
      container.read(_server.notifier).state = changed
          ? 'https://other.test'
          : 'https://api.example.test';
    case 'permissions':
      container.read(_permissions.notifier).state = changed
          ? {}
          : actualWarehouseReceiverPermissions;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _ReferenceApi api,
  Widget child, {
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      if (permissions != null) _permissions.overrideWith((_) => permissions),
      apiClientProvider.overrideWithValue(api),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: SizedBox(width: 450, child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Map<String, dynamic> _row(int i) => {
  'id': 'e$i',
  'code': i.toString().padLeft(6, '0'),
  'fullName': '测试人员$i',
  'departmentId': 'warehouse-dept',
  'departmentName': '仓储部',
  'positionName': i == 101 ? '后页职位' : '仓管员',
  'status': 'resigned',
  'accountStatus': 'disabled',
};
Map<String, dynamic> _page(
  List<Map<String, dynamic>> rows,
  int page, {
  int total = 101,
}) => {
  'items': rows,
  'page': page,
  'size': 100,
  'total': total,
  'totalPages': (total / 100).ceil(),
};

class _ReferenceApi extends ApiClient {
  _ReferenceApi()
    : super(Dio(BaseOptions(baseUrl: 'https://api.example.test')));
  final queries = <Map<String, dynamic>>[];
  final labelQueries = <Map<String, dynamic>>[];
  int hrReads = 0;
  int departmentReads = 0;
  final unexpectedPaths = <String>[];
  Object? listError;
  Object? labelError;
  bool badPage = false;
  Completer<List<Map<String, dynamic>>>? pendingLabels;
  Completer<Map<String, dynamic>>? pendingSecondPage;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/auth/me') {
      return {
        'id': 'warehouse-actor',
        'code': 'TEST',
        'name': '测试仓管',
        'employeeId': 'e1',
        'session': <String, dynamic>{},
        'superAdmin': false,
        'permissions': actualWarehouseReceiverPermissions.toList(),
      };
    }
    if (path != ApiEndpoints.employeeReferences) {
      hrReads++;
      unexpectedPaths.add(path);
      throw StateError('Unexpected full HR read $path');
    }
    queries.add({...?query});
    if (listError case final error?) throw error;
    final page = query!['page'] as int;
    if (page == 2 && pendingSecondPage != null) {
      return pendingSecondPage!.future;
    }
    if (query['search'] != null) return _page([_row(101)], page, total: 1);
    return _page(
      page == 1 ? List.generate(100, (i) => _row(i + 1)) : [_row(101)],
      badPage ? page + 1 : page,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.employeeReferencesByIds) {
      labelQueries.add({...?query});
      if (labelError case final error?) throw error;
      if (pendingLabels != null) return pendingLabels!.future;
      return (query!['ids'] as String)
          .split(',')
          .where((id) => id.startsWith('e'))
          .map((id) => _row(int.parse(id.substring(1))))
          .toList();
    }
    if (path == ApiEndpoints.employeeReferenceDepartments) {
      departmentReads++;
      return [
        {
          'id': 'warehouse-dept',
          'code': 'SUB_WH',
          'name': '仓储部',
          'level': '二级班组',
          'parentId': null,
          'children': <Object>[],
        },
      ];
    }
    hrReads++;
    unexpectedPaths.add(path);
    throw StateError('Unexpected full organization read $path');
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'warehouse-actor',
      code: 'TEST',
      name: '测试仓管',
      employeeId: 'e1',
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}
