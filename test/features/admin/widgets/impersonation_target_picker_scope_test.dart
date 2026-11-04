import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/models/impersonation.dart';
import 'package:uten_imp/features/admin/repositories/impersonation_repository.dart';
import 'package:uten_imp/features/admin/widgets/impersonation_actions.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/department_node.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'active mode target picker uses its management tree even when the current target has no organization rights',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final repository = _Targets();
      var ordinaryTreeReads = 0;
      ImpersonationTarget? picked;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_ModeSession.new),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(
                userId: 'current-target',
                actorId: 'real-admin',
                readOnly: true,
              ),
            ),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
            isSuperAdminProvider.overrideWithValue(false),
            apiBaseUrlProvider.overrideWithValue('https://example.test/api'),
            impersonationRepositoryProvider.overrideWithValue(repository),
            employeePickerDepartmentTreeProvider.overrideWith((ref) async {
              ordinaryTreeReads++;
              throw StateError(
                'Current target has no ordinary organization rights',
              );
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    picked = await showImpersonationTargetPicker(context, ref);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(repository.treeReads, 1);
      expect(repository.pageReads, 1);
      expect(ordinaryTreeReads, 0);
      await tester.tap(
        find.byKey(const ValueKey('employee-picker-item-next-target')),
      );
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(picked?.employeeId, 'next-target');
      expect(tester.takeException(), isNull);
    },
  );
}

class _Targets extends ImpersonationRepository {
  _Targets() : super(ApiClient(Dio()));
  int treeReads = 0, pageReads = 0;
  @override
  Future<List<DepartmentNode>> targetDepartments() async {
    treeReads++;
    return [
      DepartmentNode(
        id: 'd1',
        code: 'D1',
        name: '示例部门',
        level: '一级部门',
        children: [],
      ),
    ];
  }

  @override
  Future<PagedResult<ImpersonationTarget>> targetsPage(
    String? keyword, {
    int page = 1,
    int size = 100,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    pageReads++;
    return PagedResult(
      items: const [
        ImpersonationTarget(
          employeeId: 'next-target',
          name: '员工甲',
          employeeCode: 'E001',
          departmentId: 'd1',
          departmentName: '示例部门',
          accountStatus: 'active',
          employmentStatus: 'active',
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }
}

class _ModeSession extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: const AppUser(id: 'current-target', code: 'T', name: '当前视角'),
    actor: const AppUser(
      id: 'real-admin',
      code: 'A',
      name: '管理员',
      superAdmin: true,
    ),
    impersonationReadOnly: true,
    impersonationModeExpiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}
