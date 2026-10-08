import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

// 搜索框与分段导航条严格同高（真实主题）：
// - 桌面（VisualDensity.compact）与移动（standard）两种密度下都相等；
// - 量的是**描边实际绘制高度**（_BorderContainer 的 CustomPaint 盒高），不是
//   TextField 外盒——InputDecorator 的药丸描边只按内容高绘制、不吃外部
//   minHeight（2026-10-07 SDK input_decorator.dart 源码定位的根因：外盒被
//   stretch 拉高时描边不跟、居中浮在盒里）。同高由两侧共用下限令牌
//   UtenFilterRow.minHeight(40) 保证：分段 minCellHeight 与搜索前后缀图标
//   约束 minHeight 同源，描边恒等于 max(40, 文本内容高)；
// - 清除按钮可见（有输入）时也不得撑高。

/// 搜索框药丸描边的绘制盒（_BorderContainer 只渲染一个 CustomPaint，
/// 其 foregroundPainter 即描边画笔）。
final _pillPaintFinder = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.foregroundPainter != null &&
      w.foregroundPainter.runtimeType.toString() == '_InputBorderPainter',
);

void main() {
  for (final density in [
    ('compact(桌面)', VisualDensity.compact),
    ('standard(移动)', VisualDensity.standard),
  ]) {
    testWidgets('trailing actions do not stretch filters (${density.$1})', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Future<void> pumpToolbar(Widget? trailing) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(visualDensity: density.$2),
            home: Scaffold(
              body: Center(
                child: UtenFilterToolbar<String>(
                  segments: const [
                    UtenFilterSegment(value: 'draft', label: '草稿'),
                    UtenFilterSegment(value: 'progress', label: '进行中'),
                    UtenFilterSegment(value: 'history', label: '历史记录'),
                  ],
                  onSelectionChanged: (_) {},
                  searchHint: '搜索单据号',
                  trailing: trailing,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await pumpToolbar(null);
      final baselineSegmentHeight = tester
          .getSize(find.byType(UtenSegmentRow<String>))
          .height;
      final baselineSearchHeight = tester
          .getSize(find.byType(InputDecorator))
          .height;

      for (final wrapped in [false, true]) {
        final action = wrapped
            ? Wrap(
                key: const Key('toolbar-actions'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < 3; i++)
                    SizedBox(
                      width: 260,
                      child: UtenButton(onPressed: () {}, child: Text('操作 $i')),
                    ),
                ],
              )
            : UtenButton(
                key: const Key('toolbar-actions'),
                onPressed: () {},
                child: const Text('创建新委外单'),
              );
        await pumpToolbar(action);

        final segments = tester.getRect(find.byType(UtenSegmentRow<String>));
        final search = tester.getRect(find.byType(InputDecorator));
        final actions = tester.getRect(
          find.byKey(const Key('toolbar-actions')),
        );
        final toolbar = tester.getRect(find.byType(UtenFilterToolbar<String>));
        expect(segments.height, closeTo(baselineSegmentHeight, 0.5));
        expect(search.height, closeTo(baselineSearchHeight, 0.5));
        expect(segments.height, closeTo(search.height, 0.5));
        expect(segments.center.dy, closeTo(search.center.dy, 0.5));
        expect(actions.center.dy, closeTo(search.center.dy, 0.5));
        expect(segments.left, closeTo(toolbar.left, 0.5));
        expect(actions.right, closeTo(toolbar.right, 0.5));
        expect(actions.bottom, lessThanOrEqualTo(toolbar.bottom));
        // 2026-10-07 用户口径：搜索宽度减半 180。行高不钉 44——分类栏保持
        // 原下限 40，搜索药丸描边与之同源同高。
        expect(search.width, closeTo(180, 0.5));
        if (wrapped) expect(actions.height, greaterThan(segments.height));
      }
    });

    testWidgets('search bar matches segment bar height (${density.$1})', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TextEditingController(text: '关键词');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(visualDensity: density.$2),
          home: Scaffold(
            body: Center(
              child: UtenFilterToolbar<String>(
                segments: const [
                  UtenFilterSegment(value: 'all', label: '全部待检单'),
                  UtenFilterSegment(value: 'a', label: '类型A', count: 3),
                ],
                selected: const {'all'},
                onSelectionChanged: (_) {},
                searchHint: '搜索',
                searchController: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final segmentHeight = tester
          .getSize(find.byType(UtenSegmentRow<String>))
          .height;
      final searchHeight = tester.getSize(find.byType(TextField)).height;
      // 描边实际高度：外盒（stretch 拉齐）与药丸都必须与分段条相等——
      // 外盒不等说明 stretch 没生效，药丸不等说明描边仍按内容高绘制
      //（图标约束下限没抬起来），两种都是回归。
      final pillHeight = tester.getSize(_pillPaintFinder).height;
      expect(
        searchHeight,
        moreOrLessEquals(segmentHeight, epsilon: 0.5),
        reason:
            '${density.$1}密度下搜索框外盒应与分段条同高'
            '（segment=$segmentHeight, search=$searchHeight）',
      );
      expect(
        pillHeight,
        moreOrLessEquals(segmentHeight, epsilon: 0.5),
        reason:
            '${density.$1}密度下搜索框药丸描边应与分段条同高'
            '（segment=$segmentHeight, pill=$pillHeight）',
      );
      // 两侧共用下限 36（2026-10-07 二次口径「两条都小点」：40 → 36，搜索框
      // 竖向内边距同步 10 → 6）：内容不足 36 时描边落到 36，不出现分类栏厚、
      // 药丸矮。
      expect(segmentHeight, greaterThanOrEqualTo(36 - 0.5));
      expect(pillHeight, greaterThanOrEqualTo(36 - 0.5));
      expect(pillHeight, lessThanOrEqualTo(segmentHeight + 0.5));
    });

    testWidgets('empty search pill still matches segment bar (${density.$1})', (
      tester,
    ) async {
      // 空框（无清除按钮）是最矮形态：清除钮自带最小交互尺寸，有输入时可能
      // 比空框高（清除钮已 shrinkWrap 收口）。2026-10-07 用户看到的「搜索栏
      // 矮一截」只在 compact 密度空框复现（未修复实测 pill=33 vs 分段=40），
      // 靠图标约束与分段下限同源修复。
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(visualDensity: density.$2),
          home: Scaffold(
            body: Center(
              child: UtenFilterToolbar<String>(
                segments: const [
                  UtenFilterSegment(value: 'all', label: '全部待检单'),
                  UtenFilterSegment(value: 'a', label: '类型A', count: 3),
                ],
                selected: const {'all'},
                onSelectionChanged: (_) {},
                searchHint: '搜索',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final segmentHeight = tester
          .getSize(find.byType(UtenSegmentRow<String>))
          .height;
      final pillHeight = tester.getSize(_pillPaintFinder).height;
      expect(
        pillHeight,
        moreOrLessEquals(segmentHeight, epsilon: 0.5),
        reason:
            '${density.$1}密度空框下药丸描边应与分段条同高'
            '（segment=$segmentHeight, pill=$pillHeight）',
      );
    });
  }
}
