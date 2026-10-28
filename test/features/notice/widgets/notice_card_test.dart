import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/models/notice_group.dart';
import 'package:uten_imp/features/notice/widgets/notice_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Notice _notice(
  String id,
  NoticeType type, {
  NoticePriority priority = NoticePriority.normal,
  bool resolved = false,
}) => Notice(
  id: id,
  title: '订单进展与同事通知',
  content: '保留原通知正文与来源。',
  type: type,
  publisher: '行政与人力资源部',
  publishedAt: DateTime.utc(2026, 10, 28),
  isRead: false,
  priority: priority,
  resolvedAt: resolved ? DateTime.utc(2026, 10, 28) : null,
  interactionMode: NoticeInteractionMode.acknowledge,
);

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'receipt waits, prevents duplicate requests, and allows retry after failure',
    (tester) async {
      var attempts = 0;
      final gate = Completer<void>();
      await _mount(
        tester,
        NoticeCard(
          notice: _notice('hr', NoticeType.announcement),
          onTap: () {},
          onAcknowledge: () async {
            attempts++;
            if (attempts == 1) await gate.future;
          },
        ),
      );
      final action = find.byType(UtenButton);
      await tester.tap(action);
      await tester.pump();
      await tester.tap(action, warnIfMissed: false);
      expect(attempts, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(attempts, 2);
    },
  );

  testWidgets(
    'stack retains urgent importance even if its latest message is routine',
    (tester) async {
      final group = NoticeGroup(const NoticeGroupKey('SALES_ORDER', 'one'), [
        _notice('routine', NoticeType.workflow),
        _notice('urgent', NoticeType.urgent),
      ]);
      await _mount(tester, NoticeStackCard(group: group, onTap: () {}));
      expect(find.text('紧急'), findsOneWidget);
      expect(find.text('共 2 条 · 2 未读'), findsOneWidget);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'type labels remain readable for all notification types, dark=$dark',
      (tester) async {
        for (final type in NoticeType.values) {
          await _mount(
            tester,
            NoticeCard(notice: _notice(type.name, type), onTap: () {}),
            dark: dark,
          );
          final label = tester.widget<Text>(find.text(type.label).first);
          final context = tester.element(find.byType(NoticeCard));
          final background = Theme.of(
            context,
          ).colorScheme.surface.computeLuminance();
          final foreground = label.style!.color!.computeLuminance();
          final contrast = (foreground > background
              ? (foreground + 0.05) / (background + 0.05)
              : (background + 0.05) / (foreground + 0.05));
          expect(contrast, greaterThanOrEqualTo(4.5), reason: type.name);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
