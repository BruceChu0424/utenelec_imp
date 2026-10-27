import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_access_batch_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/client_access_panel.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_owner.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
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
  (_) => {Perm.clientView, Perm.clientAssign},
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

const _settings = ClientAccessSettings(
  clientId: 'client-one',
  ownerEmployeeId: 'owner-A',
  ownerEmployeeName: '负责人甲',
  owners: [
    ClientAccessViewer(employeeId: 'owner-A', name: '负责人甲'),
    ClientAccessViewer(employeeId: 'owner-B', name: '负责人乙'),
  ],
  accessVersion: 4,
  viewers: [ClientAccessViewer(employeeId: 'viewer', name: '查看人')],
);

class _World implements ClientRepository {
  late ProviderContainer container;
  final navigator = GlobalKey<NavigatorState>();
  int writes = 0;
  int accepted = 0;
  ClientAccessUpdate? savedUpdate;
  AuthenticatedRequestScope? writeScope;
  Completer<ClientAccessSettings>? loadWait;
  Completer<void>? saveWait;

  Future<ClientAccessSettings> load(String _) async =>
      loadWait == null ? _settings : await loadWait!.future;

  Future<ClientAccessSettings> save(String _, ClientAccessUpdate value) async {
    writes++;
    savedUpdate = value;
    writeScope = AuthenticatedRequestScope.attach(
      RequestOptions(path: '/clients'),
    );
    await saveWait?.future;
    return _settings;
  }

  @override
  Future<PagedResult<ClientAccessCandidate>> accessCandidates({
    String? search,
    int page = 1,
    int size = 20,
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

Future<_World> _pump(
  WidgetTester tester, {
  bool batch = false,
  _World? world,
}) async {
  final w = world ?? _World();
  await tester.binding.setSurfaceSize(const Size(1280, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
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
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        clientRepositoryProvider.overrideWithValue(w),
        employeePickerDepartmentTreeProvider.overrideWith((_) async => []),
      ],
      child: MaterialApp(
        navigatorKey: w.navigator,
        home: Consumer(
          builder: (context, ref, _) {
            w.container = ProviderScope.containerOf(context);
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    if (!batch) {
                      final result = await showClientAccessPanel(
                        context: context,
                        ref: ref,
                        clientId: 'client-one',
                        clientName: '客户一号',
                        loader: w.load,
                        saver: w.save,
                      );
                      if (result != null) w.accepted++;
                      return;
                    }
                    final owner = MasterEditOwner(
                      context,
                      ref,
                      permissions: {Perm.clientView, Perm.clientAssign},
                    );
                    try {
                      if (!await owner.bindRequests() || !context.mounted) {
                        return;
                      }
                      final choice = await showClientAccessBatchDialog(
                        context: context,
                        ref: ref,
                        clientCount: 2,
                        assignOwner: false,
                        submissionOwner: owner,
                      );
                      if (choice == null || !owner.isCurrent) return;
                      await owner.run(
                        () => w.save(
                          'batch',
                          ClientAccessUpdate(
                            viewerEmployeeIds: choice.employeeIds,
                            expectedAccessVersion: 4,
                            reason: choice.reason,
                          ),
                        ),
                      );
                      if (owner.isCurrent) w.accepted++;
                    } finally {
                      owner.dispose();
                    }
                  },
                  child: const Text('打开'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开'));
  await tester.pump();
  return w;
}

Future<void> _changeAndConfirm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  tester.widget<InputChip>(find.widgetWithText(InputChip, '查看人')).onDeleted!();
  await tester.pump();
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('client-access-reason')),
      matching: find.byType(TextField),
    ),
    '客户交接',
  );
  await tester.tap(find.byKey(const ValueKey('client-access-save')));
  await tester.pumpAndSettle();
  expect(find.text('确认保存客户访问设置？'), findsOneWidget);
}

void _changeBoundary(_World w, {required bool permission}) {
  if (permission) {
    w.container.read(_permissions.notifier).state = {Perm.clientView};
  } else {
    w.container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'B',
    );
  }
  w.container.read(sensitiveReadBoundaryProvider);
}

void main() {
  for (final permission in [false, true]) {
    testWidgets('单客户确认中${permission ? '撤权' : '换账号'}关闭旧设置且不提交', (tester) async {
      final w = await _pump(tester);
      await _changeAndConfirm(tester);
      _changeBoundary(w, permission: permission);
      await tester.pumpAndSettle();
      expect(find.text('确认保存客户访问设置？'), findsNothing);
      expect(find.byType(ClientAccessPanel), findsNothing);
      expect(w.writes, 0);
      expect(w.accepted, 0);
    });

    testWidgets('批量设置中${permission ? '撤权' : '换账号'}关闭旧选择且不提交', (tester) async {
      final w = await _pump(tester, batch: true);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('client-batch-access-reason')),
          matching: find.byType(TextField),
        ),
        '客户交接',
      );
      _changeBoundary(w, permission: permission);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('client-batch-access-submit')),
        findsNothing,
      );
      expect(w.writes, 0);
    });
  }

  testWidgets('加载中A→B→A不接收原设置晚响应', (tester) async {
    final w = await _pump(tester, world: _World()..loadWait = Completer());
    _changeBoundary(w, permission: false);
    w.container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'A',
    );
    w.container.read(sensitiveReadBoundaryProvider);
    w.loadWait!.complete(_settings);
    await tester.pumpAndSettle();
    expect(find.byType(ClientAccessPanel), findsNothing);
    expect(find.text('负责人甲'), findsNothing);
    expect(w.writes, 0);
  });

  testWidgets('撤权后立即恢复也不能确认旧选择', (tester) async {
    final w = await _pump(tester);
    await _changeAndConfirm(tester);
    _changeBoundary(w, permission: true);
    w.container.read(_permissions.notifier).state = {
      Perm.clientView,
      Perm.clientAssign,
    };
    w.container.read(sensitiveReadBoundaryProvider);
    await tester.pumpAndSettle();
    expect(find.text('确认保存客户访问设置？'), findsNothing);
    expect(find.byType(ClientAccessPanel), findsNothing);
    expect(w.writes, 0);
  });

  testWidgets('页面导航盖住设置后关闭旧设置并保留新页面', (tester) async {
    final w = await _pump(tester);
    await tester.pumpAndSettle();
    w.navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页面')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('另一页面'), findsOneWidget);
    expect(find.byType(ClientAccessPanel, skipOffstage: false), findsNothing);
    expect(w.writes, 0);
  });

  testWidgets('批量确认结果仍绑定打开时身份作用域', (tester) async {
    final w = await _pump(tester, batch: true);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('client-batch-access-reason')),
        matching: find.byType(TextField),
      ),
      '结束临时查看',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('client-batch-access-submit')));
    await tester.pumpAndSettle();
    expect(w.writes, 1);
    expect(w.accepted, 1);
    expect(w.writeScope, isNotNull);
  });

  testWidgets('已提交请求绑定原身份，换账号后晚完成不显示成功', (tester) async {
    final w = await _pump(tester, world: _World()..saveWait = Completer());
    await _changeAndConfirm(tester);
    await tester.tap(find.text('确认保存'));
    await tester.pump();
    expect(w.writes, 1);
    expect(w.writeScope, isNotNull);
    _changeBoundary(w, permission: false);
    w.saveWait!.complete();
    await tester.pumpAndSettle();
    expect(w.writeScope!.isCurrent, isFalse);
    expect(w.accepted, 0);
    expect(find.textContaining('负责人和可见人已保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套人员选择属于原设置，撤权时两层一起关闭', (tester) async {
    final w = await _pump(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('client-access-owners')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenEmployeeSelectionPanel), findsOneWidget);
    expect(find.byType(ClientAccessPanel), findsOneWidget);
    _changeBoundary(w, permission: true);
    await tester.pumpAndSettle();
    expect(find.byType(UtenEmployeeSelectionPanel), findsNothing);
    expect(find.byType(ClientAccessPanel), findsNothing);
    expect(w.writes, 0);
  });

  testWidgets('同一负责人集合改顺序可明确保存新主负责人', (tester) async {
    final w = await _pump(tester);
    await tester.pumpAndSettle();
    final picker = tester.widget<UtenEmployeeMultiPicker>(
      find.byKey(const ValueKey('client-access-owners')),
    );
    picker.onChanged(const [
      UtenEmployeePickerItem(id: 'owner-B', name: '负责人乙'),
      UtenEmployeePickerItem(id: 'owner-A', name: '负责人甲'),
    ]);
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('client-access-reason')),
        matching: find.byType(TextField),
      ),
      '调整主负责人',
    );
    await tester.tap(find.byKey(const ValueKey('client-access-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(w.savedUpdate!.ownerEmployeeIds, ['owner-B', 'owner-A']);
    expect(w.savedUpdate!.ownerEmployeeId, 'owner-B');
    expect(w.accepted, 1);
    expect(w.writeScope, isNotNull);
  });
}
