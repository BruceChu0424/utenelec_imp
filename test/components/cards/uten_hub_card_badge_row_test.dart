import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

// 2026-09-23 用户口径: 卡片的红/黄计数徽章不再浮在右上角, 放在图标那一行的最右边、
// 与图标齐平, 并放大醒目; 字号档放大时徽章跟着放大。
Widget _card({double textScale = 1.0}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: UtenHubCard(
            icon: Icons.inventory_2_outlined,
            label: '采购订货',
            description: '说明',
            onTap: () {},
            badge: const UtenNotificationBadge(count: 3),
            progressBadge: const UtenInProgressBadge(count: 12),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('badges sit on the icon row, flush right and centred with it', (
    tester,
  ) async {
    await tester.pumpWidget(_card());
    final card = tester.getRect(find.byType(UtenHubCard));
    final icon = tester.getRect(find.byIcon(Icons.inventory_2_outlined));
    final red = tester.getRect(find.byType(UtenNotificationBadge));
    final yellow = tester.getRect(find.byType(UtenInProgressBadge));

    expect(
      find.ancestor(
        of: find.byType(UtenNotificationBadge),
        matching: find.byType(Positioned),
      ),
      findsNothing,
    );
    expect((red.center.dy - icon.center.dy).abs(), lessThan(1.0));
    expect((yellow.center.dy - icon.center.dy).abs(), lessThan(1.0));
    expect(yellow.right, lessThan(red.left));
    expect(card.right - red.right, lessThanOrEqualTo(24));
    expect(red.height, closeTo(16 * 1.4, 0.01));
  });

  testWidgets('badges grow with the text-size setting', (tester) async {
    await tester.pumpWidget(_card(textScale: 1.5));
    final red = tester.getRect(find.byType(UtenNotificationBadge));
    expect(red.height, closeTo(16 * 1.4 * 1.5, 0.01));
  });
}
