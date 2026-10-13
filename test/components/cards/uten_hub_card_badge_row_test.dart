import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_responsive_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

// 2026-09-23 用户口径: 卡片的红/黄计数徽章不再浮在右上角, 放在图标那一行的最右边、
// 与图标齐平, 并放大醒目; 字号档放大时徽章跟着放大。
Widget _card({
  double textScale = 1.0,
  double width = 320,
  int count = 3,
  bool showLabel = false,
  bool adaptive = false,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: Builder(
            builder: (context) {
              Widget entry() => UtenHubCard(
                icon: Icons.inventory_2_outlined,
                label: '采购订货',
                description: '说明',
                onTap: () {},
                badge: UtenNotificationBadge(
                  count: count,
                  showLabel: showLabel,
                ),
                progressBadge: UtenInProgressBadge(
                  count: count,
                  showLabel: showLabel,
                ),
              );
              return adaptive
                  ? UtenResponsiveGrid(
                      itemCount: 1,
                      columns: const UtenResponsiveColumns(compact: 2),
                      spacing: 12,
                      minItemWidth: UtenHubCard.minimumBadgeRowWidth(context),
                      itemBuilder: (context, index, itemWidth) => entry(),
                    )
                  : entry();
            },
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

  testWidgets('compact grids keep capped counts inside their bounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      // 原固定两列会把卡压成 (324 - 12) / 2 = 156dp；按真实计数字宽减列。
      _card(
        width: 324,
        textScale: 1.5,
        count: 120,
        showLabel: true,
        adaptive: true,
      ),
    );
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byType(UtenHubCard));
    final red = tester.getRect(find.byType(UtenNotificationBadge));
    final yellow = tester.getRect(find.byType(UtenInProgressBadge));
    expect(card.width, 324);
    expect(red.right, lessThanOrEqualTo(card.right));
    expect(yellow.left, greaterThanOrEqualTo(card.left));
    expect(yellow.right, lessThan(red.left));
    expect(find.text('99+'), findsNWidgets(2));
  });
}
