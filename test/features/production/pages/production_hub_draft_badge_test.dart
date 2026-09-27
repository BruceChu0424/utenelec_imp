// 生产 hub「生产任务中心」卡红数口径（2026-09-26 全站草稿口径）：红数 =
// 待排产行数 + 生产草稿（计划 draft + 日报 status=0，服务端 facts + 本地表单
// 草稿投影）——红数里的每张草稿都能在生产任务中心「草稿」段看到行（下钻闭合）。
// 草稿数此前从不计入该卡（badgeScope 只取 productionSchedule，自定义徽章又只读
// 待排产），顶栏模块红数含草稿、卡片不含，两处对不上。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _FixedFormDrafts extends FormDraftsNotifier {
  _FixedFormDrafts(this.initial);
  final List<FormDraft> initial;
  @override
  List<FormDraft> build() => initial;
}

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    List<FormDraft> drafts = const [],
  }) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(true),
          authenticatedScopeProvider.overrideWithValue(null),
          // 待排产 2 行；服务端草稿：计划 2 + 日报 1。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                'productionSchedule.count': 2,
                'drafts.productionPlan': 2,
                'drafts.productionDailyReport': 1,
              },
            ),
          ),
          formDraftsProvider.overrideWith(() => _FixedFormDrafts(drafts)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: ProductionHubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Finder taskCard() => find.byWidgetPredicate(
    (widget) => widget is UtenHubCard && widget.label == '生产任务中心',
  );

  testWidgets('任务中心卡红数含生产草稿，与「草稿」段同源', (tester) async {
    // 本地「新建生产日报」填写草稿 1 份（kind=productionDailyReport，随
    // draftCounts 投影并入红数；2 待排产 + 3 服务端草稿 + 1 本地 = 6）。
    await pumpPage(
      tester,
      drafts: [
        FormDraft(
          id: 'local-1',
          title: '新建生产日报',
          module: BadgeModule.workshop,
          draftKind: 'productionDailyReport',
          route: '/production/daily-reports/new',
          permission: '',
          updatedAt: DateTime.now(),
          data: const {},
        ),
      ],
    );
    final redBadge = find.descendant(
      of: taskCard(),
      matching: find.byType(UtenNotificationBadge),
    );
    expect(tester.widget<UtenNotificationBadge>(redBadge).count, 6);
  });

  testWidgets('没有草稿时红数回到纯待排产口径', (tester) async {
    await pumpPage(tester);
    final redBadge = find.descendant(
      of: taskCard(),
      matching: find.byType(UtenNotificationBadge),
    );
    expect(tester.widget<UtenNotificationBadge>(redBadge).count, 5);
  });
}
