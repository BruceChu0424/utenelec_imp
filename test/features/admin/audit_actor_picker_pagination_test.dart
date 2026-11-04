import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/models/department_node.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _server = StateProvider<String>((_) => 'https://audit-a.test');
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'auditor-a', epoch: 1),
);
final _permissions = StateProvider<Set<String>>((_) => {'audit:view'});
final _repository = StateProvider<AuditLogRepository?>((_) => null);

void main() {
  testWidgets(
    'audit first page is bounded and one pinned source serves explicit continuation',
    (tester) async {
      final pending = Completer<AuditActorPage>();
      final original = _ActorRepository(pending: pending);
      final replacement = _ActorRepository();
      final container = await _pump(tester, original);
      expect(original.calls.map((call) => call.page), [1]);
      _table(tester).onLoadMore!();
      await tester.pump();
      expect(original.calls.map((call) => call.page), [1, 2]);
      container.read(_repository.notifier).state = replacement;
      pending.complete(_ActorRepository.response(2));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(200));
      _table(tester).onLoadMore!();
      await tester.pumpAndSettle();
      expect(original.calls.map((call) => call.page), [1, 2, 3]);
      expect(replacement.calls, isEmpty);
      expect(_table(tester).items, hasLength(300));
    },
  );

  for (final boundary in ['server', 'identity', 'permissions']) {
    testWidgets(
      'audit $boundary change rejects an old continuation without mixing identities',
      (tester) async {
        final pending = Completer<AuditActorPage>();
        final original = _ActorRepository(pending: pending);
        AuditActorOption? selected;
        final container = await _pump(
          tester,
          original,
          onSelected: (value) => selected = value,
        );
        _table(tester).onLoadMore!();
        await tester.pump();
        switch (boundary) {
          case 'server':
            container.read(_server.notifier).state = 'https://audit-b.test';
          case 'identity':
            container.read(_identity.notifier).state = const AuthenticatedScope(
              userId: 'auditor-b',
              epoch: 2,
            );
          case 'permissions':
            container.read(_permissions.notifier).state = {};
        }
        await tester.pump();
        pending.complete(_ActorRepository.response(2));
        await tester.pumpAndSettle();
        expect(original.calls.map((call) => call.page), [1, 2]);
        expect(find.byType(AuditActorPicker), findsNothing);
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'department filtering happens before audit paging and historical account identity is retained',
    (tester) async {
      final repository = _ActorRepository();
      AuditActorOption? selected;
      await _pump(tester, repository, onSelected: (value) => selected = value);
      final departments = await _departmentsVisible(tester);
      await tester.tap(find.byTooltip('展开测试公司'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: departments, matching: find.text('财务部')),
      );
      await tester.pumpAndSettle();
      expect(repository.calls.last.department, 'finance');
      expect(repository.calls.last.page, 1);
      expect(
        _table(tester).items.every((item) => item.departmentId == 'finance'),
        true,
      );
      _table(tester).onLoadMore!();
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(104));
      expect(_table(tester).items.last.id, 'historical-user-103');
      await tester.tap(
        find.byKey(const ValueKey('employee-picker-item-historical-user-0')),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(selected?.actorId, 'historical-user-0');
      expect(selected?.accountStatus, 'deleted');
      expect(selected?.employmentStatus, 'resigned');
    },
  );

  testWidgets(
    'visitors stay reachable from the first page and retain visitor actor identity',
    (tester) async {
      final repository = _ActorRepository();
      AuditActorOption? selected;
      await _pump(tester, repository, onSelected: (value) => selected = value);
      final departments = await _departmentsVisible(tester);
      await tester.tap(
        find.descendant(of: departments, matching: find.text('外部访客')),
      );
      await tester.pumpAndSettle();
      expect(repository.calls.last.actorType, 'visitor');
      expect(repository.calls.last.department, isNull);
      _table(tester).onLoadMore!();
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(104));
      expect(_table(tester).items.last.id, 'visitor-103');
      await tester.tap(
        find.byKey(const ValueKey('employee-picker-item-visitor-0')),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(selected?.actorId, 'visitor-0');
      expect(selected?.actorType, 'visitor');
    },
  );

  testWidgets(
    'unassigned historical accounts filter on the server and every page remains reachable',
    (tester) async {
      final repository = _ActorRepository();
      await _pump(tester, repository);
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar),
          matching: find.byType(TextField),
        ),
        '未分配',
      );
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      final departments = await _departmentsVisible(tester);
      await tester.tap(
        find.descendant(of: departments, matching: find.text('未提供部门')),
      );
      await tester.pumpAndSettle();
      expect(repository.calls.last.unassigned, true);
      expect(repository.calls.last.actorType, 'staff');
      expect(repository.calls.last.department, isNull);
      _table(tester).onLoadMore!();
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(104));
      expect(_table(tester).items.last.id, 'unassigned-user-103');
    },
  );

  testWidgets('new audit search rejects an older pending continuation', (
    tester,
  ) async {
    final pending = Completer<AuditActorPage>();
    final repository = _ActorRepository(pending: pending);
    await _pump(tester, repository);
    _table(tester).onLoadMore!();
    await tester.pump();
    final search = find.descendant(
      of: find.byType(UtenSearchBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(_table(tester).items.single.id, 'new-audit-user');
    pending.complete(_ActorRepository.response(2));
    await tester.pumpAndSettle();
    expect(_table(tester).items.single.id, 'new-audit-user');
    expect(tester.takeException(), isNull);
  });
}

Future<Finder> _departmentsVisible(WidgetTester tester) async {
  final tree = find.byKey(const Key('uten-employee-picker-departments'));
  if (!tester.any(tree)) {
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
  }
  return tree;
}

MasterDataTableView<UtenEmployeePickerItem> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
      find.byKey(const Key('uten-employee-picker-candidates')),
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _ActorRepository repository, {
  ValueChanged<AuditActorOption?>? onSelected,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        auditLogRepositoryProvider.overrideWith(
          (ref) => ref.watch(_repository) ?? repository,
        ),
        employeePickerDepartmentTreeProvider.overrideWith(
          (ref) async => [
            DepartmentNode(
              id: 'company',
              code: 'COMPANY',
              name: '测试公司',
              level: '公司',
              children: [
                DepartmentNode(
                  id: 'sales',
                  code: 'DEPT_SALES',
                  name: '销售部',
                  level: '一级部门',
                  parentId: 'company',
                  children: [],
                ),
                DepartmentNode(
                  id: 'finance',
                  code: 'DEPT_FIN',
                  name: '财务部',
                  level: '一级部门',
                  parentId: 'company',
                  children: [],
                ),
              ],
            ),
          ],
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final actor = await showDialog<AuditActorOption>(
                  context: context,
                  builder: (_) => const Dialog(
                    child: SizedBox(
                      width: 560,
                      height: 650,
                      child: AuditActorPicker(),
                    ),
                  ),
                );
                onSelected?.call(actor);
              },
              child: const Text('打开人员'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开人员'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return ProviderScope.containerOf(
    tester.element(find.byType(AuditActorPicker)),
    listen: false,
  );
}

class _ActorRepository extends Fake implements AuditLogRepository {
  _ActorRepository({this.pending});
  final Completer<AuditActorPage>? pending;
  final calls =
      <
        ({
          int page,
          String? keyword,
          String? department,
          String? actorType,
          bool unassigned,
        })
      >[];
  static List<AuditActorOption> get all => [
    for (var i = 0; i < 104; i++)
      AuditActorOption(
        actorId: 'account-user-$i',
        actorType: 'staff',
        name: '人员$i',
        departmentId: 'sales',
        department: '销售部',
      ),
    for (var i = 0; i < 104; i++)
      AuditActorOption(
        actorId: 'historical-user-$i',
        actorType: 'staff',
        name: '历史人员$i',
        departmentId: 'finance',
        department: '财务部',
        accountStatus: 'deleted',
        employmentStatus: 'resigned',
      ),
    for (var i = 0; i < 104; i++)
      AuditActorOption(
        actorId: 'unassigned-user-$i',
        actorType: 'staff',
        name: '未分配人员$i',
        accountStatus: 'deleted',
      ),
    for (var i = 0; i < 104; i++)
      AuditActorOption(
        actorId: 'visitor-$i',
        actorType: 'visitor',
        name: '访客$i',
        department: '外部访客',
      ),
  ];
  static AuditActorPage response(
    int page, {
    String? keyword,
    String? departmentId,
    String? actorType,
    bool unassignedOnly = false,
  }) {
    final rows = keyword == 'new'
        ? const [AuditActorOption(actorId: 'new-audit-user', name: 'new人员')]
        : all
              .where(
                (actor) =>
                    (keyword?.isNotEmpty != true ||
                        actor.primaryLabel.contains(keyword!)) &&
                    (departmentId == null ||
                        actor.departmentId == departmentId) &&
                    (actorType == null || actor.actorType == actorType) &&
                    (!unassignedOnly ||
                        actor.actorType == 'staff' &&
                            actor.departmentId == null),
              )
              .toList();
    return AuditActorPage(
      items: rows.skip((page - 1) * 100).take(100).toList(),
      page: page,
      size: 100,
      total: rows.length,
      totalPages: (rows.length / 100).ceil(),
    );
  }

  @override
  Future<AuditActorPage> actors({
    int page = 1,
    int size = 20,
    String? keyword,
    String? departmentId,
    bool includeSubtree = false,
    String? actorType,
    bool unassignedOnly = false,
  }) async {
    calls.add((
      page: page,
      keyword: keyword,
      department: departmentId,
      actorType: actorType,
      unassigned: unassignedOnly,
    ));
    if (page == 2 &&
        (keyword?.isEmpty ?? true) &&
        departmentId == null &&
        actorType == null &&
        pending != null) {
      return pending!.future;
    }
    return response(
      page,
      keyword: keyword,
      departmentId: departmentId,
      actorType: actorType,
      unassignedOnly: unassignedOnly,
    );
  }
}
