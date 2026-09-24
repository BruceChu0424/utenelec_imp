import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

// 搜索框与分段导航条严格同高（真实主题）：
// - 桌面（VisualDensity.compact）与移动（standard）两种密度下都相等——
//   密度对两侧的折减不一致，UtenFilterToolbar 用 IntrinsicHeight+stretch
//   结构保证同高，而不是各自算高度；
// - 清除按钮可见（有输入）时也不得撑高——M3 默认给 prefix/suffix 图标
//   各 48×48 最小约束，是搜索框比分段条高的根因，UtenSearchBar 已显式收紧。

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
          .getSize(find.byType(SegmentedButton<String>))
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

        final segments = tester.getRect(find.byType(SegmentedButton<String>));
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
        expect(search.width, closeTo(360, 0.5));
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
          .getSize(find.byType(SegmentedButton<String>))
          .height;
      final searchHeight = tester.getSize(find.byType(TextField)).height;
      expect(
        searchHeight,
        moreOrLessEquals(segmentHeight, epsilon: 0.5),
        reason:
            '${density.$1}密度下搜索框应与分段条同高'
            '（segment=$segmentHeight, search=$searchHeight）',
      );
    });
  }
}
