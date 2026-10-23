import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/click_guard.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_master_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_owner.dart';
import 'package:uten_imp/features/basic_data/widgets/supplier_master_edit.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/department_employee_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'A'),
);
final _permissions = StateProvider<Set<String>>(
  (_) => {
    Perm.clientView,
    Perm.clientEdit,
    Perm.clientStatus,
    Perm.supplierView,
    Perm.supplierEdit,
    Perm.supplierStatus,
  },
);

class _Session extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState();
}

const _methods = [
  ReferenceMethodOption(id: 'method-one', code: 'JS01', name: '账期'),
];

class _References extends ReferenceMethodRepository {
  _References() : super(ApiClient(Dio()));
  int calls = 0;
  Completer<List<ReferenceMethodOption>>? pending;
  @override
  Future<List<ReferenceMethodOption>> settlementMethods() async {
    calls++;
    return pending == null ? _methods : await pending!.future;
  }
}

class _Currencies implements CurrencyRepository {
  Completer<List<CurrencyListItem>>? pending;
  @override
  Future<List<CurrencyListItem>> dict() async =>
      pending == null ? [] : await pending!.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Writes {
  int calls = 0;
  int accepted = 0;
  Completer<void>? pending;
  Map<String, dynamic>? lastBody;
  Future<void> save() async {
    calls++;
    await pending?.future;
  }
}

class _Clients implements ClientRepository {
  _Clients(this.writes);
  final _Writes writes;
  @override
  Future<void> update(String id, Map<String, dynamic> body) => writes.save();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Suppliers implements SupplierRepository {
  _Suppliers(this.writes);
  final _Writes writes;
  @override
  Future<void> update(String id, Map<String, dynamic> body) {
    writes.lastBody = body;
    return writes.save();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Employees implements EmployeeRepository {
  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async => PagedResult(
    items: departmentId == 'sales'
        ? const [
            EmployeeSummary(
              id: 'employee-one',
              code: 'E-100',
              fullName: '张三',
              departmentId: 'sales',
              departmentName: '销售部',
            ),
          ]
        : const [],
    page: page,
    size: size,
    total: departmentId == 'sales' ? 1 : 0,
    totalPages: departmentId == 'sales' ? 1 : 0,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  Completer<void>? capture;
  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    await capture?.future;
    return super.captureRequestScope(isCurrent: isCurrent);
  }
}

class _Harness extends ConsumerWidget {
  const _Harness(this.kind, this.writes);
  final String kind;
  final _Writes writes;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: UtenButton(
        onPressed: () async {
          if (kind == 'client') {
            await showClientMasterEdit(
              context,
              ref,
              const ClientDetail(
                id: 'client-one',
                name: '原名称',
                code: 'CL01',
                status: '使用',
                categoryId: 'category-one',
                version: 1,
                writable: true,
              ),
              onSaved: () => writes.accepted++,
            );
          } else if (kind == 'supplier') {
            await showSupplierMasterEdit(
              context,
              ref,
              const SupplierDetail(
                id: 'supplier-one',
                name: '原名称',
                code: 'SP01',
                status: '使用',
                categoryId: 'category-one',
                version: 1,
                linkman: '联系人',
              ),
              onSaved: () => writes.accepted++,
            );
          } else if (kind == 'read') {
            final owner = MasterEditOwner(
              context,
              ref,
              permissions: {Perm.clientView},
              requireWrite: false,
            );
            try {
              if (!await owner.bindRequests()) return;
              await owner.run(() async => await writes.pending!.future);
              if (owner.isCurrent) writes.accepted++;
            } finally {
              owner.dispose();
            }
          } else {
            var valid = true;
            final owner = MasterEditOwner(
              context,
              ref,
              permissions: {Perm.clientView, Perm.clientEdit},
              isCurrent: () => valid,
            );
            try {
              if (!await owner.bindRequests() || !context.mounted) return;
              await showMasterEditDialog(
                context: context,
                title: '归属契约',
                submissionOwner: owner,
                fields: const [MasterFieldDef(key: 'name', label: '名称')],
                initialValues: const {'name': '原名称'},
                onSubmit: (_) async => true,
                onAccepted: () {
                  writes.accepted++;
                  valid = false;
                },
              );
            } finally {
              owner.dispose();
            }
          }
        },
        child: const Text('打开编辑'),
      ),
    ),
  );
}

class _World {
  _World({this.nestedNavigator = false});
  final bool nestedNavigator;
  final writes = _Writes();
  final references = _References();
  final currencies = _Currencies();
  final api = _Api();
  final navigator = GlobalKey<NavigatorState>();
  late GoRouter router;
  late ProviderContainer container;
}

Future<_World> _pump(WidgetTester tester, String kind, [_World? world]) async {
  final w = world ?? _World();
  await tester.binding.setSurfaceSize(const Size(1280, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final pages = <RouteBase>[
    GoRoute(path: '/', builder: (_, _) => _Harness(kind, w.writes)),
    GoRoute(
      path: '/other',
      builder: (_, _) => const Scaffold(body: Text('别的页面')),
    ),
  ];
  w.router = GoRouter(
    navigatorKey: w.navigator,
    routes: w.nestedNavigator
        ? [ShellRoute(builder: (_, _, child) => child, routes: pages)]
        : pages,
  );
  addTearDown(w.router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(w.api),
        referenceMethodRepositoryProvider.overrideWithValue(w.references),
        currencyRepositoryProvider.overrideWithValue(w.currencies),
        clientRepositoryProvider.overrideWithValue(_Clients(w.writes)),
        supplierRepositoryProvider.overrideWithValue(_Suppliers(w.writes)),
        employeeRepositoryProvider.overrideWithValue(_Employees()),
        employeePickerDepartmentTreeProvider.overrideWith(
          (_) async => [
            DepartmentNode(
              id: 'sales',
              code: 'D1',
              name: '销售部',
              level: '一级部门',
              children: const [],
            ),
          ],
        ),
      ],
      child: MaterialApp.router(
        routerConfig: w.router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  w.container = ProviderScope.containerOf(
    tester.element(find.byType(_Harness)),
  );
  return w;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开编辑'));
  await tester.pumpAndSettle();
  expect(find.byType(MasterEditForm), findsOneWidget);
}

void _identityAba(_World w) {
  w.container.read(_identity.notifier).state = const AuthenticatedScope(
    userId: 'B',
  );
  w.container.read(sensitiveReadBoundaryProvider);
  w.container.read(_identity.notifier).state = const AuthenticatedScope(
    userId: 'A',
  );
  w.container.read(sensitiveReadBoundaryProvider);
}

void _permissionAba(_World w) {
  final original = w.container.read(_permissions);
  w.container.read(_permissions.notifier).state = {
    Perm.clientView,
    Perm.supplierView,
  };
  w.container.read(sensitiveReadBoundaryProvider);
  w.container.read(_permissions.notifier).state = original;
  w.container.read(sensitiveReadBoundaryProvider);
}

Future<void> _newWindow(WidgetTester tester, _World w) async {
  w.navigator.currentState!.push(
    DialogRoute<void>(
      context: w.navigator.currentContext!,
      builder: (_) => const Dialog(child: Text('新窗口')),
    ),
  );
  await tester.pumpAndSettle();
}

void _noOldFeedback(_World w) {
  expect(w.writes.accepted, 0);
  expect(w.container.read(appNotificationProvider), isEmpty);
}

void main() {
  for (final kind in ['client', 'supplier']) {
    testWidgets(
      '$kind nested shell root popup cannot revive after a foreign root page',
      (tester) async {
        final w = await _pump(tester, kind, _World(nestedNavigator: true));
        await _open(tester);
        final oldSave = tester
            .widget<UtenActionButton>(
              find.widgetWithText(UtenActionButton, '保存'),
            )
            .onAction;
        final page = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('外来根页面')),
        );
        unawaited(w.navigator.currentState!.push(page));
        await tester.pumpAndSettle();
        expect(find.text('外来根页面'), findsOneWidget);
        w.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(MasterEditForm), findsNothing);
        await Future<void>.sync(oldSave);
        await tester.pumpAndSettle();
        expect(w.writes.calls, 0);
        _noOldFeedback(w);
      },
    );
  }
  testWidgets(
    'a read owner completes while a plain popup covers its active page',
    (tester) async {
      final w = _World(nestedNavigator: true);
      w.writes.pending = Completer();
      await _pump(tester, 'read', w);
      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();
      await _newWindow(tester, w);
      w.writes.pending!.complete();
      await tester.pumpAndSettle();
      expect(w.writes.accepted, 1);
      expect(find.text('新窗口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final select in [false, true]) {
    testWidgets(
      'supplier owned employee picker select=$select preserves editing',
      (tester) async {
        final w = await _pump(
          tester,
          'supplier',
          _World(nestedNavigator: true),
        );
        await _open(tester);
        final employee = find.descendant(
          of: find.byType(DepartmentEmployeePickerField),
          matching: find.byType(TextField),
        );
        // Locate the existing picker by its explicit form label.
        final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
        expect(
          form.fields.any((field) => field.key == 'ownerEmployeeId'),
          isTrue,
        );
        await tester.ensureVisible(find.byType(DepartmentEmployeePickerField));
        await tester.pumpAndSettle();
        await tester.tap(employee);
        await tester.pumpAndSettle();
        expect(find.byType(UtenDepartmentTreeView), findsOneWidget);
        if (select) {
          await tester.tap(
            find.descendant(
              of: find.byType(UtenDepartmentTreeView),
              matching: find.text('销售部'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('张三'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确定'));
        } else {
          await tester.tap(find.text('取消').last);
        }
        await tester.pumpAndSettle();
        expect(find.byType(MasterEditForm), findsOneWidget);
        await tester.tap(find.widgetWithText(UtenButton, '保存'));
        await tester.pumpAndSettle();
        expect(w.writes.calls, 1);
        expect(w.writes.accepted, 1);
        expect(
          w.writes.lastBody?['ownerEmployeeId'],
          select ? 'employee-one' : null,
        );
        expect(find.byType(MasterEditForm), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final kind in ['client', 'supplier']) {
    testWidgets(
      '$kind old dictionary failure cannot release or close a newer editor load',
      (tester) async {
        final w = _World();
        final old = Completer<List<ReferenceMethodOption>>();
        w.references.pending = old;
        await _pump(tester, kind, w);
        await tester.tap(find.text('打开编辑'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        _identityAba(w);
        await tester.pumpAndSettle();
        final fresh = Completer<List<ReferenceMethodOption>>();
        w.references.pending = fresh;
        await tester.tap(find.text('打开编辑'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        expect(w.references.calls, 2);
        old.completeError(ApiException('CONFLICT', '旧请求失败', httpStatus: 409));
        await tester.pump(const Duration(milliseconds: 80));
        fresh.complete(_methods);
        await tester.pumpAndSettle();
        expect(find.byType(MasterEditForm), findsOneWidget);
        _noOldFeedback(w);
        await tester.tap(find.widgetWithText(UtenButton, '保存'));
        await tester.pumpAndSettle();
        expect(w.writes.calls, 1);
        expect(w.writes.accepted, 1);
      },
    );
    testWidgets('$kind current full editor saves and calls accepted once', (
      tester,
    ) async {
      final w = await _pump(tester, kind);
      await _open(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (v) => v is TextField && v.controller?.text == '原名称',
        ),
        '改名',
      );
      await tester.tap(find.widgetWithText(UtenButton, '保存'));
      await tester.pumpAndSettle();
      expect(w.writes.calls, 1);
      expect(w.writes.accepted, 1);
      expect(find.byType(MasterEditForm), findsNothing);
    });
    testWidgets(
      '$kind old loading result cannot open an editor or pop a new window after A-B-A',
      (tester) async {
        final w = _World();
        w.references.pending = Completer();
        await _pump(tester, kind, w);
        await tester.tap(find.text('打开编辑'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        expect(w.references.calls, 1);
        _identityAba(w);
        await tester.pumpAndSettle();
        await _newWindow(tester, w);
        w.references.pending!.complete(_methods);
        await tester.pumpAndSettle();
        expect(find.text('新窗口'), findsOneWidget);
        expect(find.byType(MasterEditForm), findsNothing);
        expect(w.writes.calls, 0);
        _noOldFeedback(w);
      },
    );
    testWidgets(
      '$kind currency load cannot continue after permissions are revoked and restored',
      (tester) async {
        final w = _World();
        w.currencies.pending = Completer();
        await _pump(tester, kind, w);
        await tester.tap(find.text('打开编辑'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        _permissionAba(w);
        await tester.pumpAndSettle();
        await _newWindow(tester, w);
        w.currencies.pending!.complete([]);
        await tester.pumpAndSettle();
        expect(find.text('新窗口'), findsOneWidget);
        expect(find.byType(MasterEditForm), findsNothing);
        _noOldFeedback(w);
      },
    );
    testWidgets(
      '$kind captured old save stays inert after open-editor permission A-B-A',
      (tester) async {
        final w = await _pump(tester, kind);
        await _open(tester);
        final save = tester
            .widget<UtenActionButton>(
              find.widgetWithText(UtenActionButton, '保存'),
            )
            .onAction;
        _permissionAba(w);
        await tester.pumpAndSettle();
        await _newWindow(tester, w);
        await Future<void>.sync(save);
        await tester.pumpAndSettle();
        expect(w.writes.calls, 0);
        expect(find.text('新窗口'), findsOneWidget);
        _noOldFeedback(w);
      },
    );
    for (final failure in [false, true]) {
      testWidgets(
        '$kind late save failure=$failure has no old toast/callback and cannot close a new window',
        (tester) async {
          final w = await _pump(tester, kind);
          w.writes.pending = Completer();
          await _open(tester);
          await tester.tap(find.widgetWithText(UtenButton, '保存'));
          await tester.pump(const Duration(milliseconds: 80));
          await tester.pump(const Duration(milliseconds: 80));
          expect(w.writes.calls, 1);
          _identityAba(w);
          await tester.pumpAndSettle();
          await _newWindow(tester, w);
          if (failure) {
            w.writes.pending!.completeError(
              ApiException('CONFLICT', '旧请求失败', httpStatus: 409),
            );
          } else {
            w.writes.pending!.complete();
          }
          await tester.pumpAndSettle();
          expect(find.text('新窗口'), findsOneWidget);
          _noOldFeedback(w);
        },
      );
    }
    testWidgets(
      '$kind leaving and returning to the owner route invalidates pending loading',
      (tester) async {
        final w = _World();
        w.references.pending = Completer();
        await _pump(tester, kind, w);
        await tester.tap(find.text('打开编辑'));
        await tester.pump(const Duration(milliseconds: 80));
        w.router.push('/other');
        await tester.pumpAndSettle();
        expect(find.text('别的页面'), findsOneWidget);
        w.router.pop();
        await tester.pumpAndSettle();
        w.references.pending!.complete(_methods);
        await tester.pumpAndSettle();
        expect(find.text('打开编辑'), findsOneWidget);
        expect(find.byType(MasterEditForm), findsNothing);
        _noOldFeedback(w);
      },
    );
    testWidgets(
      '$kind changed request intent during capture sends no dictionary or update request',
      (tester) async {
        final w = _World();
        w.api.capture = Completer();
        await _pump(tester, kind, w);
        await tester.tap(find.text('打开编辑'));
        await tester.pump();
        (w.container.read(sessionProvider.notifier) as _Session).intent++;
        w.api.capture!.complete();
        await tester.pumpAndSettle();
        expect(w.references.calls, 0);
        expect(w.writes.calls, 0);
        expect(find.byType(MasterEditForm), findsNothing);
        _noOldFeedback(w);
      },
    );
  }
  testWidgets(
    'accepted callback may invalidate query epoch after its own successful modal closes',
    (tester) async {
      final w = await _pump(tester, 'contract');
      await _open(tester);
      await tester.tap(find.widgetWithText(UtenButton, '保存'));
      await tester.pumpAndSettle();
      expect(w.writes.accepted, 1);
      expect(find.byType(MasterEditForm), findsNothing);
    },
  );
}
