import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/audit/audit_retention_presentation.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

const _workspaceHelp = '按人员与时间查看登录记录，沿操作记录追溯业务变化。';

class _UnusedAuditRepository extends Fake implements AuditLogRepository {}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  for (final applied in [false, true]) {
    testWidgets(
      'workspace help is inline and real applied scope stays visible: $applied',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: _app(
              SingleChildScrollView(
                child: AuditQueryScopeComposer(
                  selectedActor: applied
                      ? const AuditActorOption(
                          actorId: 'auditor',
                          displayName: '审核员',
                        )
                      : null,
                  anonymousMode: false,
                  systemAnomalyMode: false,
                  dateRange: applied
                      ? DateTimeRange(
                          start: DateTime(2026, 10, 28),
                          end: DateTime(2026, 10, 28),
                        )
                      : null,
                  requestIdController: controller,
                  requestInvestigation: applied,
                  loading: false,
                  scopeApplied: applied,
                  onPickActor: () {},
                  onSelectAnonymous: () {},
                  onSelectSystemAnomaly: () {},
                  onToday: () {},
                  onYesterday: () {},
                  onSevenDays: () {},
                  onThirtyDays: () {},
                  onCustomDate: () {},
                  onRunQuery: () {},
                  onRequestIdChanged: (_) {},
                  onRequestIdSubmitted: (_) => false,
                  onClear: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_workspaceHelp), findsNothing);
        if (applied) {
          expect(find.text('审核员 · 2026-10-28(单日) · 全部为北京时间'), findsOneWidget);
        } else {
          expect(find.text('建立审计调查范围'), findsOneWidget);
          expect(find.text('已完成 0 / 2 步'), findsOneWidget);
        }
        final help = find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon && widget.info == _workspaceHelp,
        );
        await tester.tap(help);
        await tester.pumpAndSettle();
        expect(find.text(_workspaceHelp), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in AuditArchivePurgeMode.values) {
    testWidgets(
      'retention keeps actual $mode state and discloses the policy on demand',
      (tester) async {
        tester.view.physicalSize = const Size(390, 920);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({Perm.auditLogView}),
              auditLogRepositoryProvider.overrideWithValue(
                _UnusedAuditRepository(),
              ),
              auditArchivePurgeModeProvider.overrideWithValue(mode),
            ],
            child: _app(const AdminAuditLogPage()),
          ),
        );
        await tester.pumpAndSettle();
        final heading = find.text('留存与归档');
        final pageScrollable = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          heading,
          200,
          scrollable: pageScrollable,
        );
        await tester.pumpAndSettle();
        final policy = AuditRetentionPresentation.historyHint(mode);
        expect(
          find.text(AuditRetentionPresentation.modeLabel(mode)),
          findsOneWidget,
        );
        expect(find.text(policy), findsNothing);
        final help = find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && widget.info == policy,
        );
        await Scrollable.ensureVisible(tester.element(help), alignment: .5);
        await tester.pumpAndSettle();
        for (
          var attempt = 0;
          attempt < 8 && help.hitTestable().evaluate().isEmpty;
          attempt++
        ) {
          await tester.drag(pageScrollable, const Offset(0, -160));
          await tester.pumpAndSettle();
        }
        expect(help.hitTestable(), findsOneWidget);
        await tester.tap(help.hitTestable());
        await tester.pumpAndSettle();
        expect(find.text(policy), findsOneWidget);
        expect(
          find.text(AuditRetentionPresentation.modeLabel(mode)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
