import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/approvals/pages/approval_policy_settings_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_APPROVAL_CAPTURE');
final _captureKey = GlobalKey();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'admin',
      employeeId: 'admin-employee',
      code: 'A001',
      name: '审批管理员',
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://policy.test/api')));
  int reads = 0;
  int candidates = 0;
  bool manyCandidates = false;
  final candidateQueries = <({String path, Map<String, dynamic> query})>[];
  int version = 0;
  String? substitute;
  String managerId = 'manager';
  Completer<Map<String, dynamic>>? writeGate;
  Completer<void>? captureGate;
  bool loseResponse = false;
  final writes = <Map<String, dynamic>>[];
  Map<String, dynamic> get policy => {
    'departmentId': 'department-finance',
    'departmentCode': 'DEPT_FIN',
    'departmentName': '财税部',
    'managerId': managerId,
    'managerName': '财务负责人',
    'substituteEmployeeId': substitute,
    'substituteEmployeeName': substitute == null ? null : '上级审批人',
    'version': version,
  };
  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    if (captureGate != null) await captureGate!.future;
    return super.captureRequestScope(isCurrent: isCurrent);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/candidates/page')) {
      candidates++;
      candidateQueries.add((path: path, query: {...?query}));
      final page = query?['page'] as int? ?? 1;
      return {
        'items': [
          if (manyCandidates)
            for (
              var index = (page - 1) * 100;
              index < (page == 1 ? 100 : 101);
              index++
            )
              {
                'id': 'substitute-$index',
                'name': '候选审批人$index',
                'employeeCode': 'G$index',
                'departmentId': 'executive-department',
                'departmentName': '总经办',
              }
          else
            {
              'id': 'substitute',
              'name': '上级审批人',
              'employeeCode': 'G001',
              'departmentName': '总经办',
            },
        ],
        'page': page,
        'size': 100,
        'total': manyCandidates ? 101 : 1,
        'totalPages': manyCandidates ? 2 : 1,
      };
    }

    reads++;
    return {
      'departments': [policy],
    };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final value = Map<String, dynamic>.from(body as Map);
    writes.add(value);
    substitute = value['substituteEmployeeId'] as String?;
    version++;
    if (loseResponse) throw NetworkTimeoutException();
    return writeGate?.future ?? policy;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  Set<String> permissions = const {Perm.approvalPolicyManage},
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://policy.test/api'),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      fixedBadgeSummaryOverride(),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ApprovalPolicySettingsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openAndPick(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('approval-policy-edit-department-finance')),
  );
  await tester.pumpAndSettle();
  final picker = tester.widget<UtenEmployeePicker>(
    find.byKey(const Key('approval-policy-substitute')),
  );
  picker.onChanged(
    const UtenEmployeePickerItem(id: 'substitute', name: '上级审批人'),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'avoidance reviewer opens actual bounded pages without mixing policy context and candidate department',
    (tester) async {
      final api = _Api()..manyCandidates = true;
      await _pump(tester, api);
      await tester.tap(
        find.byKey(const ValueKey('approval-policy-edit-department-finance')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('approval-policy-substitute'));
      await tester.tap(
        find.descendant(of: field, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(api.candidateQueries.map((entry) => entry.query['page']), [1]);
      final table = find.byKey(const Key('uten-employee-picker-candidates'));
      tester
          .widget<MasterDataTableView<UtenEmployeePickerItem>>(table)
          .onLoadMore!();
      await tester.pumpAndSettle();
      expect(api.candidateQueries.map((entry) => entry.query['page']), [1, 2]);
      expect(
        api.candidateQueries.every(
          (entry) =>
              entry.path ==
              '/approval-policy/departments/department-finance/candidates/page',
        ),
        true,
      );
      final last = find.byKey(
        const ValueKey('employee-picker-item-substitute-100'),
      );
      final scrollable = find
          .descendant(
            of: table,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .last;
      await tester.scrollUntilVisible(
        last,
        500,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tester.tap(last);
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenEmployeePicker>(field).initial?.id,
        'substitute-100',
      );
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual policy example shows department and selected substitute',
    (tester) async {
      if (_capture) await loadAuditScreenshotFonts(tester);
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, _Api());
      await _openAndPick(tester);
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'manual-approval-policy',
        );
      }
    },
  );

  testWidgets(
    'department managers cannot configure their own avoidance reviewer',
    (tester) async {
      final api = _Api()..managerId = 'admin-employee';
      await _pump(tester, api);
      final configure = tester.widget<UtenButton>(
        find.byKey(const ValueKey('approval-policy-edit-department-finance')),
      );
      expect(configure.onPressed, isNull);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('policy settings require explicit configuration permission', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, permissions: {Perm.expenseApproveFinanceInitial});
    expect(find.text('没有审批设置权限'), findsOneWidget);
    expect(api.reads, 0);
  });
  testWidgets(
    'one selected substitute is saved once with its original version',
    (tester) async {
      final api = _Api()..writeGate = Completer<Map<String, dynamic>>();
      await _pump(tester, api);
      await _openAndPick(tester);
      final save = tester.widget<UtenButton>(
        find.byKey(const Key('approval-policy-save')),
      );
      final futures = [
        for (var i = 0; i < 8; i++) Future<void>.sync(save.onPressed!),
      ];
      await tester.pump();
      expect(api.writes, hasLength(1));
      expect(api.writes.single, {
        'substituteEmployeeId': 'substitute',
        'expectedVersion': 0,
      });
      api.writeGate!.complete(api.policy);
      await Future.wait(futures);
      await tester.pumpAndSettle();
      expect(find.text('上级审批人'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'uncertain policy save reconciles with GET without repeating PUT',
    (tester) async {
      final api = _Api()..loseResponse = true;
      await _pump(tester, api);
      await _openAndPick(tester);
      await tester.tap(find.byKey(const Key('approval-policy-save')));
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(find.text('核对设置'), findsOneWidget);
      await tester.tap(find.text('核对设置'));
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(api.reads, greaterThanOrEqualTo(2));
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('approval-policy-save')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'picker candidates use policy authority without employee directory permission',
    (tester) async {
      final api = _Api();
      await _pump(tester, api);
      await tester.tap(
        find.byKey(const ValueKey('approval-policy-edit-department-finance')),
      );
      await tester.pumpAndSettle();
      final picker = tester.widget<UtenEmployeePicker>(
        find.byKey(const Key('approval-policy-substitute')),
      );
      final future = picker.pagedLoader!(
        const UtenEmployeePickerQuery(keyword: '上级'),
      );
      await tester.pump();
      final values = await future;
      await tester.pumpAndSettle();
      expect(api.candidates, 1);
      expect(values.items.single.id, 'substitute');
      expect(
        api.candidateQueries.single.path,
        '/approval-policy/departments/department-finance/candidates/page',
      );
      expect(api.candidateQueries.single.query, {
        'search': '上级',
        'page': 1,
        'size': 100,
      });
      expect(tester.takeException(), isNull);
    },
  );
}
