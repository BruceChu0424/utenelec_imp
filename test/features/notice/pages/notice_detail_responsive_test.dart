import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_detail_page.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/widgets/notice_interaction_footer.dart';

void main() {
  for (final systemFactor in [1.0, 2.0]) {
    for (final mode in NoticeInteractionMode.values) {
      testWidgets('notice detail keeps metadata at 200%/$systemFactor/$mode', (
        tester,
      ) async {
        final notice = _notice(mode);
        await _pump(
          tester,
          NoticeDetailPage(noticeId: notice.id, onBack: () {}),
          systemFactor,
          notice: notice,
        );
        final scrollable = find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('已于 2026-10-13 08:30(北京) 阅读'),
          200,
          scrollable: scrollable,
          maxScrolls: 150,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('已于 2026-10-13 08:30(北京) 阅读'), findsOneWidget);
      });
    }
    for (final mode in [
      NoticeInteractionMode.acknowledge,
      NoticeInteractionMode.bless,
    ]) {
      testWidgets('notice footer keeps action at 200%/$systemFactor/$mode', (
        tester,
      ) async {
        var presses = 0;
        await _pump(
          tester,
          Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: NoticeInteractionFooter(
                  notice: _notice(mode, received: false),
                  onOpenDetail: () => presses++,
                  onAcknowledge: () => presses++,
                ),
              ),
            ),
          ),
          systemFactor,
        );
        expect(tester.takeException(), isNull);
        final action = find.byType(UtenButton);
        expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(presses, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Notice _notice(NoticeInteractionMode mode, {bool received = true}) => Notice(
  id: 'notice-responsive',
  title: '完整的工作通知与接收范围',
  content: '原通知的全部正文保留。',
  type: mode == NoticeInteractionMode.bless
      ? NoticeType.birthday
      : mode == NoticeInteractionMode.none
      ? NoticeType.task
      : NoticeType.announcement,
  publisher: '负责发布通知的长姓名同事',
  // Notice models carry Beijing wall-clock fields in a UTC date carrier.
  publishedAt: DateTime.utc(2026, 10, 13, 8, 30),
  readAt: DateTime.utc(2026, 10, 13, 8, 30),
  isRead: true,
  kind: NoticeKind.todo,
  dueAt: DateTime.utc(2026, 10, 31, 18),
  taskCompleted: true,
  priority: NoticePriority.urgent,
  topPriority: true,
  interactionMode: mode,
  ackCount: 123456,
  blessingCount: 1,
  myAcked: received,
  recentAckers: const ['负责接收公告的长姓名同事'],
  blessingTemplates: const ['祝同事生日快乐，工作顺利'],
  recentBlessings: [
    NoticeBlessing(
      id: 'blessing-responsive',
      senderName: '负责送祝福的长姓名同事',
      content: '完整的祝福内容。',
      createdAt: DateTime.utc(2026, 10, 13, 8, 30),
      mine: true,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  double systemFactor, {
  Notice? notice,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_Session.new),
        if (notice != null)
          noticeDetailProvider(notice.id).overrideWith((ref) async => notice),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: buildLightTheme().copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(systemFactor)),
          child: UtenDisplayZoomBox(
            fontFactor: 2,
            child: UtenControlTheme(child: child!),
          ),
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}
