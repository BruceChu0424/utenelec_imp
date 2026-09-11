import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_count_suffix.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';

// UtenFilterToolbar 的分段计数形态契约（docs/00-项目准则/14-徽章与计数口径.md）：
// 默认中性括号 `(N)`（新调用方不会凭空造出假警报），红徽章必须显式挑；
// 窄屏 + 大字号下分段行横向滚动，不换行也不溢出。

Widget _wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  ),
);

UtenFilterToolbar<String> _toolbar() => UtenFilterToolbar<String>(
  segmentsKey: const Key('count-form-segments'),
  segments: const [
    UtenFilterSegment(value: 'pending', label: '等待下达车间', count: 46),
    UtenFilterSegment(value: 'issued', label: '已下达', count: 0),
    UtenFilterSegment(
      value: 'blocked',
      label: '需处理',
      count: 3,
      countForm: UtenSegmentCountForm.actionable,
    ),
    UtenFilterSegment(value: 'history', label: '历史记录'),
  ],
  selected: const {'pending'},
  onSelectionChanged: (_) {},
);

void main() {
  testWidgets('默认形态是中性括号，红徽章只出现在显式挑了 actionable 的分段', (tester) async {
    await tester.pumpWidget(_wrap(_toolbar()));

    // 浏览型：括号数字，0 也保留 `(0)` 保持队形。
    expect(find.text('(46)'), findsOneWidget);
    expect(find.text('(0)'), findsOneWidget);
    expect(find.byType(UtenCountSuffix), findsNWidgets(2));
    // 待办型：红徽章，数字不带括号。
    expect(find.byType(UtenNotificationBadge), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('(3)'), findsNothing);
    // 不传 count 的分段两种形态都不渲染数字。
    expect(find.text('历史记录'), findsOneWidget);
  });

  testWidgets('countForm 原样透传给 UtenSegmentBadgeLabel', (tester) async {
    await tester.pumpWidget(_wrap(_toolbar()));

    UtenSegmentBadgeLabel labelOf(String text) =>
        tester.widget<UtenSegmentBadgeLabel>(
          find.byWidgetPredicate(
            (widget) => widget is UtenSegmentBadgeLabel && widget.label == text,
          ),
        );

    expect(labelOf('等待下达车间').countForm, UtenSegmentCountForm.browsing);
    expect(labelOf('需处理').countForm, UtenSegmentCountForm.actionable);
  });

  testWidgets('375px + 1.5 倍字号：分段行横滚不换行也不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(_toolbar(), textScale: 1.5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 窄屏（< compactBreakpoint）走横向滚动分支，分段挤不下时滑动而不是折行。
    final scroller = find.ancestor(
      of: find.byKey(const Key('count-form-segments')),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroller, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(scroller).scrollDirection,
      Axis.horizontal,
    );
    // 括号数字与标签仍是单行（maxLines=1，不因大字号折成两行）。
    expect(tester.widget<Text>(find.text('(46)')).maxLines, 1);
    // 分段行整体只占一行：最后一段与第一段的垂直位置一致。
    final first = tester.getRect(find.text('等待下达车间'));
    final last = tester.getRect(find.text('历史记录'));
    expect(first.center.dy, closeTo(last.center.dy, 1.0));
  });

  testWidgets('括号数字与标签共用基线', (tester) async {
    await tester.pumpWidget(_wrap(_toolbar()));

    final label = tester.getRect(find.text('等待下达车间'));
    final count = tester.getRect(find.text('(46)'));
    // 字号不同（bodySmall vs 按钮标签）但底部对齐在同一基线附近，
    // 不是上下居中导致的「数字往上飘」。
    expect(count.bottom, closeTo(label.bottom, 2.0));
    expect(count.left, greaterThan(label.right));
  });
}
