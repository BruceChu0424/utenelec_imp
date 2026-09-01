import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';

// 分段标签 + 计数徽章组件契约：
// - 正数 → 文字 + 红色圆数字徽章；
// - 0 / null（加载中、未知）→ 徽章不显示，不把「未知」伪装成 0；
// - 超过 99 → 99+（UtenNotificationBadge 行为）。

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('positive count renders label with red badge number', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const UtenSegmentBadgeLabel(label: '采购收货', count: 5)),
    );

    expect(find.text('采购收货'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsOneWidget);
  });

  testWidgets('zero count hides the badge entirely', (tester) async {
    await tester.pumpWidget(
      _wrap(const UtenSegmentBadgeLabel(label: '委外回厂', count: 0)),
    );

    expect(find.text('委外回厂'), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('null count (loading/unknown) hides the badge', (tester) async {
    await tester.pumpWidget(
      _wrap(const UtenSegmentBadgeLabel(label: '全部待检单')),
    );

    expect(find.text('全部待检单'), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsNothing);
  });

  testWidgets('count above 99 caps at 99+', (tester) async {
    await tester.pumpWidget(
      _wrap(const UtenSegmentBadgeLabel(label: '自制产成品', count: 150)),
    );

    expect(find.text('99+'), findsOneWidget);
    expect(find.text('150'), findsNothing);
  });

  testWidgets('works inside a SegmentedButton label slot', (tester) async {
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            var selected = 'all';
            return SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'all',
                  label: UtenSegmentBadgeLabel(label: '全部待检单', count: 3),
                ),
                ButtonSegment(value: 'fqc', label: Text('自制产成品')),
              ],
              selected: {selected},
              onSelectionChanged: (selection) =>
                  setState(() => selected = selection.first),
            );
          },
        ),
      ),
    );

    expect(find.text('全部待检单'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.text('自制产成品'));
    await tester.pumpAndSettle();
    expect(find.text('自制产成品'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
