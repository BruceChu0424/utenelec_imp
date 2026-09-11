import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_count_suffix.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';

// 分段标签计数的两种形态契约（docs/00-项目准则/14-徽章与计数口径.md）：
//
// - 默认 [UtenSegmentCountForm.browsing]：中性括号 `(N)`，0 显示 `(0)` 保持队形，
//   null（加载中/未知）不渲染，>999 显 999+；颜色跟随分段自身前景色（选中段
//   背景变色也要可读），数字用 tabular figures 保证宽度稳定；
// - [UtenSegmentCountForm.actionable]：红色通知徽章，0 与 null 都不渲染，>99 显 99+。

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('中性括号（默认形态）', () {
    testWidgets('默认不传 countForm = 括号数字，不是红徽章', (tester) async {
      await tester.pumpWidget(
        _wrap(const UtenSegmentBadgeLabel(label: '等待下达车间', count: 46)),
      );

      expect(find.text('等待下达车间'), findsOneWidget);
      expect(find.text('(46)'), findsOneWidget);
      expect(find.byType(UtenCountSuffix), findsOneWidget);
      expect(find.byType(UtenNotificationBadge), findsNothing);
      expect(
        const UtenSegmentBadgeLabel(label: 'x').countForm,
        UtenSegmentCountForm.browsing,
      );
    });

    testWidgets('0 显示 (0) 保持整行队形', (tester) async {
      await tester.pumpWidget(
        _wrap(const UtenSegmentBadgeLabel(label: '已下达', count: 0)),
      );

      expect(find.text('已下达'), findsOneWidget);
      expect(find.text('(0)'), findsOneWidget);
    });

    testWidgets('null（加载中/未知）不渲染数字，不伪装成 (0)', (tester) async {
      await tester.pumpWidget(
        _wrap(const UtenSegmentBadgeLabel(label: '历史记录')),
      );

      expect(find.text('历史记录'), findsOneWidget);
      expect(find.byType(UtenCountSuffix), findsNothing);
      expect(find.text('(0)'), findsNothing);
    });

    testWidgets('超过 999 收敛成 999+', (tester) async {
      await tester.pumpWidget(
        _wrap(const UtenSegmentBadgeLabel(label: '生产中', count: 1200)),
      );

      expect(find.text('(999+)'), findsOneWidget);
      expect(find.text('(1200)'), findsNothing);
    });

    testWidgets('数字用等宽字形（tabular figures），位数变化不抖列', (tester) async {
      await tester.pumpWidget(
        _wrap(const UtenSegmentBadgeLabel(label: '进行中', count: 7)),
      );

      final style = tester.widget<Text>(find.text('(7)')).style!;
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('颜色跟随分段前景色：选中态与未选态不同且都不是写死的灰', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: 'a',
                label: UtenSegmentBadgeLabel(label: '待生产', count: 12),
              ),
              ButtonSegment(
                value: 'b',
                label: UtenSegmentBadgeLabel(label: '生产中', count: 12),
              ),
            ],
            selected: const {'a'},
            onSelectionChanged: (_) {},
          ),
        ),
      );

      final scheme = ThemeData(useMaterial3: true).colorScheme;
      Color colorOf(String segment) {
        final label = find.byWidgetPredicate(
          (widget) =>
              widget is UtenSegmentBadgeLabel && widget.label == segment,
        );
        return tester
            .widget<Text>(
              find.descendant(of: label, matching: find.text('(12)')),
            )
            .style!
            .color!;
      }

      final selected = colorOf('待生产');
      final unselected = colorOf('生产中');
      // 选中段背景是 secondaryContainer：中性灰必须换成该段自己的前景色，
      // 否则在变色背景上读不清。两态颜色必然不同，且都不是固定 onSurfaceVariant。
      expect(selected, isNot(unselected));
      expect(selected, isNot(scheme.onSurfaceVariant));
      // 半透明而非全黑：与标签文字拉开层次但仍可读。
      expect(selected.a, lessThan(1.0));
      expect(selected.a, greaterThan(0.5));
    });
  });

  group('红色待办徽章（显式挑）', () {
    testWidgets('正数 → 文字 + 红色圆数字徽章', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const UtenSegmentBadgeLabel(
            label: '采购收货',
            count: 5,
            countForm: UtenSegmentCountForm.actionable,
          ),
        ),
      );

      expect(find.text('采购收货'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('(5)'), findsNothing);
      expect(find.byType(UtenNotificationBadge), findsOneWidget);
    });

    testWidgets('0 整个不渲染（不留红色的 0，也不退化成 (0)）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const UtenSegmentBadgeLabel(
            label: '委外回厂',
            count: 0,
            countForm: UtenSegmentCountForm.actionable,
          ),
        ),
      );

      expect(find.text('委外回厂'), findsOneWidget);
      expect(find.byType(UtenNotificationBadge), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.text('(0)'), findsNothing);
    });

    testWidgets('null（加载中/未知）不显示徽章', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const UtenSegmentBadgeLabel(
            label: '全部待检单',
            countForm: UtenSegmentCountForm.actionable,
          ),
        ),
      );

      expect(find.text('全部待检单'), findsOneWidget);
      expect(find.byType(UtenNotificationBadge), findsNothing);
    });

    testWidgets('超过 99 收敛成 99+', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const UtenSegmentBadgeLabel(
            label: '自制产成品',
            count: 150,
            countForm: UtenSegmentCountForm.actionable,
          ),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
      expect(find.text('150'), findsNothing);
    });
  });

  testWidgets('两种形态可以共存于同一条分段，且切换选中不改变计数', (tester) async {
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            var selected = 'all';
            return SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'all',
                  label: UtenSegmentBadgeLabel(
                    label: '全部待检单',
                    count: 3,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                ),
                ButtonSegment(
                  value: 'fqc',
                  label: UtenSegmentBadgeLabel(label: '自制产成品', count: 0),
                ),
              ],
              selected: {selected},
              onSelectionChanged: (selection) =>
                  setState(() => selected = selection.first),
            );
          },
        ),
      ),
    );

    expect(find.text('3'), findsOneWidget);
    expect(find.text('(0)'), findsOneWidget);
    await tester.tap(find.text('自制产成品'));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('(0)'), findsOneWidget);
  });
}
