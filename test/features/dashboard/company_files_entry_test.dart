import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'test-user', code: 'E001', name: '测试员工'),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  test('library route and page permission drawer share the catalog scope', () {
    expect(locationAllowedFor({}, false, RouteName.companyFiles), isFalse);
    expect(
      locationAllowedFor({Perm.companyFileView}, false, RouteName.companyFiles),
      isTrue,
    );
    expect(
      locationAllowedFor(
        {Perm.companyFileUpload},
        false,
        RouteName.companyFiles,
      ),
      isFalse,
      reason: 'an operation permission alone cannot bypass the view dependency',
    );
    final scope = pagePermissionScopeFor(
      '${RouteName.companyFiles}?folder=abc',
    );
    expect(scope?.surfaceKey, 'common.company-files');
    expect(pagePermissionScopeBySurfaceKey(scope!.surfaceKey)?.title, '公司资料库');
    expect(pagePermissionScopeFor('/company-files-unrelated'), isNull);
  });

  for (final customOrder in [false, true]) {
    testWidgets(
      customOrder
          ? 'saved common-card ordering is preserved'
          : 'common cards use the requested default order',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_Session.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'test-user'),
            ),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.goodsView,
              Perm.companyFileView,
              Perm.expenseApply,
              Perm.payrollViewSelf,
              Perm.suggestionSubmit,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        if (customOrder) {
          container
              .read(workbenchLayoutProvider.notifier)
              .reorderItem(
                'common',
                [RouteName.basicinfo, RouteName.payrollSlipList],
                RouteName.basicinfo,
                RouteName.payrollSlipList,
              );
        }
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(child: WorkbenchModuleArea()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cardFinder = find.byWidgetPredicate(
          (widget) => widget is LongPressDraggable<String>,
        );
        final visibleCards =
            cardFinder.evaluate().map((element) {
              final widget = element.widget as LongPressDraggable<String>;
              final box = element.renderObject! as RenderBox;
              return (
                location: widget.data,
                offset: box.localToGlobal(Offset.zero),
              );
            }).toList()..sort((a, b) {
              final row = a.offset.dy.compareTo(b.offset.dy);
              return row == 0 ? a.offset.dx.compareTo(b.offset.dx) : row;
            });
        final cards = visibleCards.map((card) => card.location);
        final expected = customOrder
            ? [
                RouteName.payrollSlipList,
                RouteName.basicinfo,
                RouteName.companyFiles,
                RouteName.expense,
                RouteName.suggestion,
              ]
            : [
                RouteName.basicinfo,
                RouteName.companyFiles,
                RouteName.expense,
                RouteName.payrollSlipList,
                RouteName.suggestion,
              ];
        expect(cards.take(expected.length), expected);
        expect(find.text('公司资料库'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
