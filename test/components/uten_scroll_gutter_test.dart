import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import '../support/audit_screenshot_support.dart';

Widget _app(Widget child) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: auditScreenshotTheme(
    buildLightTheme().copyWith(platform: TargetPlatform.windows),
  ),
  home: Scaffold(body: child),
);

void main() {
  for (final (width, pageMargin) in [
    (360.0, 16.0),
    (1366.0, 16.0),
    (1920.0, 24.0),
    (2560.0, 24.0),
  ]) {
    testWidgets(
      'automatic viewport keeps content outside its thumb lane at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              controller: controller,
              child: const UtenContentContainer(
                selectable: false,
                child: SizedBox(key: Key('content'), height: 2200),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final content = tester.getRect(find.byKey(const Key('content')));
        expect(content.left, closeTo(pageMargin, .01));
        expect(
          content.right,
          closeTo(width - UtenScrollGutter.trackWidth - 24, .01),
        );
        expect(width - UtenScrollGutter.trackWidth - content.right, 24);
        final mouse = await tester.startGesture(
          Offset(width - 5, 20),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, 160));
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(200));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a gutter supports intrinsic table cells and nested page margins',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const UtenContentContainer(
            selectable: false,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: UtenScrollGutter(
                      child: SizedBox(key: Key('cell-content'), height: 96),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final content = tester.getRect(find.byKey(const Key('cell-content')));
      expect(content.left, closeTo(16, .01));
      expect(
        content.right,
        closeTo(800 - 24 - UtenScrollGutter.trackWidth, .01),
      );
      expect(tester.getRect(find.byType(Row)).right - content.right, 16);
      expect(content.height, 96);
      expect(tester.takeException(), isNull);
    },
  );

  for (final trailing in [false, true]) {
    testWidgets(
      'a local lane keeps the leading content edge; trailing=$trailing',
      (tester) async {
        const child = SizedBox.expand(key: Key('local-content'));
        await tester.pumpWidget(
          _app(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 100,
                child: trailing
                    ? const UtenScrollGutter.trailing(child: child)
                    : const UtenScrollGutter(child: child),
              ),
            ),
          ),
        );
        final content = tester.getRect(find.byKey(const Key('local-content')));
        expect(content.left, 0);
        expect(content.right, 184);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [
    const Size(1366, 768),
    const Size(1920, 1080),
    const Size(2560, 1440),
  ]) {
    testWidgets('table headers and cells end before the outer track at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (const bool.fromEnvironment('UTEN_CAPTURE_SCROLL_LAYOUT')) {
        await loadAuditScreenshotFonts(tester);
      }
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: captureKey,
            child: ColoredBox(
              color: UtenColors.background,
              child: UtenContentContainer(
                selectable: false,
                child: MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      width: 300,
                      label: '货品名称',
                      value: (row) => row,
                    ),
                    MasterColumnDef(
                      key: 'code',
                      width: 120,
                      label: '编号',
                      value: (row) => 'C-$row',
                    ),
                  ],
                  items: List.generate(120, (i) => '单联单控开关《白色V5》 ${i + 1}'),
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = tester.getRect(find.byType(UtenTableHeaderSurface));
      final track = tester.getRect(find.byType(UtenContentScrollbar));
      expect(header.right, closeTo(track.left, .01));
      final horizontalViewports = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      for (final viewport in horizontalViewports.evaluate()) {
        final rect =
            (viewport.findRenderObject()! as RenderBox).localToGlobal(
              Offset.zero,
            ) &
            (viewport.findRenderObject()! as RenderBox).size;
        expect(rect.right, lessThanOrEqualTo(track.left + .01));
      }
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('UTEN_CAPTURE_SCROLL_LAYOUT')) {
        await saveAuditScreenshot(
          tester,
          captureKey,
          'scroll-table-${size.width.toInt()}x${size.height.toInt()}',
        );
      }
    });
  }
}
