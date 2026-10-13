import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_count_suffix.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/components/layout/uten_segmented_filter.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

import '../../support/audit_screenshot_support.dart';

const _supplierLabel = '委外供应商及加工任务';
const _lockedLabel = '等待财务审核与权限复核状态';
const _mainKey = Key('style-main');
const _childKey = Key('style-child');
const _searchKey = Key('style-search');

// Component parameters only: these counts do not represent a business query.
class _Fixture extends StatefulWidget {
  const _Fixture({super.key});
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  final search = TextEditingController(text: 'SO-2026-001');
  final searches = <String>[];
  final selections = <String>[];
  var selected = 'source';
  var unlocked = false;
  var childCalls = 0;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('模块分类与搜索', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: UtenFilterRow.rowGap),
          UtenFilterToolbar<String>(
            key: _mainKey,
            autoSelectBadge: false,
            segments: const [
              UtenFilterSegment(
                value: 'source',
                label: '采购',
                count: 120,
                inProgressCount: 140,
                countForm: UtenSegmentCountForm.actionable,
              ),
              UtenFilterSegment(
                value: 'supplier',
                label: _supplierLabel,
                count: 7,
              ),
              UtenFilterSegment(value: 'history', label: '历史', count: 1234),
              UtenFilterSegment(value: 'zero', label: '零记录', count: 0),
              UtenFilterSegment(value: 'unknown', label: '未加载'),
            ],
            selected: {selected},
            onSelectionChanged: (value) => setState(() {
              selections.add(value);
              selected = value;
              unlocked = true;
            }),
            searchKey: _searchKey,
            searchHint: '搜索单号',
            searchController: search,
            onSearchChanged: searches.add,
          ),
          const SizedBox(height: UtenFilterRow.rowGap),
          UtenFilterToolbar<String>(
            key: _childKey,
            autoSelectBadge: false,
            enabled: unlocked,
            selected: const {'review'},
            segments: const [
              UtenFilterSegment(
                value: 'review',
                label: _lockedLabel,
                count: 3,
                countForm: UtenSegmentCountForm.actionable,
              ),
              UtenFilterSegment(value: 'done', label: '已完成', count: 9),
              UtenFilterSegment(
                value: 'running',
                label: '在办',
                count: 14,
                countForm: UtenSegmentCountForm.inProgress,
              ),
            ],
            onSelectionChanged: (_) => childCalls++,
          ),
        ],
      ),
    ),
  );
}

final _borderPainter = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      widget.foregroundPainter?.runtimeType.toString() == '_InputBorderPainter',
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  const directory = String.fromEnvironment('UTEN_CATEGORY_STYLE_VISUAL_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await box.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final target = Directory(directory)..createSync(recursive: true);
    File(
      '${target.path}/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final dark in [false, true]) {
    for (final scenario in [
      ('desktop', const Size(1280, 900), 1.0, 1.0, TargetPlatform.windows),
      (
        'desktop-system2',
        const Size(2000, 1200),
        1.0,
        2.0,
        TargetPlatform.windows,
      ),
      ('390', const Size(390, 900), 1.0, 1.0, TargetPlatform.android),
      ('320', const Size(320, 900), 1.0, 1.0, TargetPlatform.android),
      ('390-85', const Size(390, 900), 0.85, 1.0, TargetPlatform.android),
      (
        '320-200-system2',
        const Size(320, 1100),
        2.0,
        2.0,
        TargetPlatform.android,
      ),
    ]) {
      testWidgets(
        'category/search rectangle ${dark ? 'dark' : 'light'} ${scenario.$1}',
        (tester) async {
          await loadAuditScreenshotFonts(tester);
          tester.view.physicalSize = scenario.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture = GlobalKey<_FixtureState>();
          final boundary = GlobalKey();
          final baseTheme = auditScreenshotTheme(
            dark ? buildDarkTheme() : buildLightTheme(),
          ).copyWith(platform: scenario.$5);
          final theme = baseTheme.copyWith(
            // A generic input role may have a 40px floor. Search must override
            // it internally, including the actual painted border.
            inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
              constraints: const BoxConstraints(minHeight: 40),
            ),
          );
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scenario.$4)),
                  child: UtenDisplayZoomBox(
                    fontFactor: scenario.$3,
                    child: UtenControlTheme(child: child!),
                  ),
                ),
                home: Scaffold(body: _Fixture(key: fixture)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final state = fixture.currentState!;
          final main = find.byKey(_mainKey);
          final child = find.byKey(_childKey);
          final search = find.byKey(_searchKey);
          expect(
            tester.widget<UtenSearchBar>(search).controller,
            same(state.search),
          );
          final textField = find.descendant(
            of: search,
            matching: find.byType(TextField),
          );
          final decoration = tester.widget<TextField>(textField).decoration!;
          expect(
            (decoration.enabledBorder! as OutlineInputBorder).borderRadius,
            UtenFilterRow.borderRadius,
          );
          expect(
            (decoration.focusedBorder! as OutlineInputBorder).borderRadius,
            UtenFilterRow.borderRadius,
          );
          expect(decoration.contentPadding, UtenFilterRow.contentPadding);
          expect(
            tester
                .widget<UtenNotificationBadge>(
                  find.descendant(
                    of: main,
                    matching: find.byType(UtenNotificationBadge),
                  ),
                )
                .count,
            120,
          );
          expect(
            tester
                .widget<UtenInProgressBadge>(
                  find.descendant(
                    of: main,
                    matching: find.byType(UtenInProgressBadge),
                  ),
                )
                .count,
            140,
          );
          final categoryRow = find.descendant(
            of: main,
            matching: find.byType(UtenSegmentRow<String>),
          );
          final rowMaterials = find.descendant(
            of: categoryRow,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.shape is RoundedRectangleBorder,
            ),
          );
          expect(rowMaterials, findsOneWidget);
          expect(
            (tester.widget<Material>(rowMaterials).shape!
                    as RoundedRectangleBorder)
                .borderRadius,
            UtenFilterRow.borderRadius,
          );
          if (scenario.$5 == TargetPlatform.windows) {
            final row = find.descendant(
              of: main,
              matching: find.byType(UtenSegmentRow<String>),
            );
            final paintedBorder = find.descendant(
              of: search,
              matching: _borderPainter,
            );
            final outline = tester.getSize(rowMaterials).height;
            final painted = tester.getSize(paintedBorder).height;
            expect(outline, closeTo(painted, 0.01));
            expect(tester.getSize(row).height, closeTo(painted, 0.01));
            if (scenario.$4 == 1) expect(painted, closeTo(36, 0.01));
            final short = find.descendant(of: main, matching: find.text('采购'));
            final long = find.descendant(
              of: main,
              matching: find.text(_supplierLabel),
            );
            Finder cell(Finder label) =>
                find.ancestor(of: label, matching: find.byType(InkWell)).first;
            expect(
              tester.getSize(cell(long)).width,
              greaterThan(tester.getSize(cell(short)).width),
            );
          }
          final name = '${dark ? 'dark' : 'light'}-${scenario.$1}';
          await _capture(tester, boundary, '$name-initial');

          await _reveal(tester, child);
          final childButtons = tester.widgetList<Semantics>(
            find.descendant(
              of: child,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.button == true,
              ),
            ),
          );
          expect(childButtons, isNotEmpty);
          expect(
            childButtons.every((button) => button.properties.enabled == false),
            isTrue,
          );
          await tester.tap(
            find.descendant(of: child, matching: find.text(_lockedLabel)),
          );
          await tester.pumpAndSettle();
          expect(state.childCalls, 0);

          final arrows = find.descendant(
            of: main,
            matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
          );
          if (tester.any(arrows)) {
            await _reveal(tester, arrows);
            await tester.tap(arrows);
            await tester.pumpAndSettle();
            final dialog = find.byWidgetPredicate((widget) => widget is Dialog);
            final panelScroll = find.descendant(
              of: find.descendant(of: dialog, matching: find.byType(ListView)),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            );
            for (final expected in [
              ('采购', 120, 140),
              (_supplierLabel, 7, null),
              ('历史', 1234, null),
              ('零记录', 0, null),
              ('未加载', null, null),
            ]) {
              final label = find.descendant(
                of: dialog,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is UtenSegmentBadgeLabel &&
                      widget.label == expected.$1,
                ),
              );
              await tester.scrollUntilVisible(
                label,
                80,
                scrollable: panelScroll,
              );
              await tester.pumpAndSettle();
              final rendered = tester.widget<UtenSegmentBadgeLabel>(label);
              expect(rendered.count, expected.$2);
              expect(rendered.inProgressCount, expected.$3);
            }
            final supplier = find.descendant(
              of: dialog,
              matching: find.text(_supplierLabel, skipOffstage: false),
            );
            await tester.scrollUntilVisible(
              supplier,
              -80,
              scrollable: panelScroll,
            );
            await tester.pumpAndSettle();
            await _reveal(tester, supplier);
            await _capture(tester, boundary, '$name-panel');
            expect(supplier.hitTestable(), findsOneWidget);
            await tester.tap(supplier);
          } else {
            await _reveal(
              tester,
              find.descendant(of: main, matching: find.text(_supplierLabel)),
            );
            await tester.tap(
              find.descendant(of: main, matching: find.text(_supplierLabel)),
            );
          }
          await tester.pumpAndSettle();
          expect(state.selections, ['supplier']);
          expect(state.selected, 'supplier');
          expect(state.unlocked, isTrue);
          final badges = tester.widgetList<UtenSegmentBadgeLabel>(
            find.descendant(
              of: main,
              matching: find.byType(UtenSegmentBadgeLabel),
            ),
          );
          // The source objects retain exact values even when compact labels are onstage.
          final params = tester
              .widget<UtenFilterToolbar<String>>(main)
              .segments;
          expect(
            params.singleWhere((segment) => segment.value == 'source').count,
            120,
          );
          expect(
            params
                .singleWhere((segment) => segment.value == 'source')
                .inProgressCount,
            140,
          );
          expect(
            params.singleWhere((segment) => segment.value == 'history').count,
            1234,
          );
          if (badges.isNotEmpty) {
            final suffix = find.descendant(
              of: main,
              matching: find.byWidgetPredicate(
                (widget) => widget is UtenCountSuffix && widget.count == 7,
              ),
            );
            final count = tester.widget<UtenCountSuffix>(suffix);
            expect(count.color, theme.colorScheme.onSecondaryContainer);
            final ratio =
                (count.color!.computeLuminance() >
                    theme.colorScheme.secondaryContainer.computeLuminance()
                ? (count.color!.computeLuminance() + 0.05) /
                      (theme.colorScheme.secondaryContainer.computeLuminance() +
                          0.05)
                : (theme.colorScheme.secondaryContainer.computeLuminance() +
                          0.05) /
                      (count.color!.computeLuminance() + 0.05));
            expect(ratio, greaterThanOrEqualTo(4.5));
            expect(
              find.descendant(of: main, matching: find.text('(0)')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: main, matching: find.text('(999+)')),
              findsOneWidget,
            );
          }

          final clear = find.descendant(
            of: search,
            matching: find.widgetWithIcon(IconButton, Icons.close_rounded),
          );
          await _reveal(tester, clear);
          expect(clear.hitTestable(), findsOneWidget);
          final clearRect = tester.getRect(clear);
          final goal = scenario.$5 == TargetPlatform.android ? 48.0 : 36.0;
          expect(clearRect.width, greaterThanOrEqualTo(goal - 0.01));
          expect(clearRect.height, greaterThanOrEqualTo(goal - 0.01));
          await tester.tap(clear);
          await tester.pumpAndSettle();
          expect(state.search.text, isEmpty);
          expect(state.searches, ['']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'segmented filter keeps raw single-label counts without a new cap',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenSegmentedFilter<String>(
              segments: const [
                UtenSegment(value: 'one', label: '待检', count: 1234),
                UtenSegment(value: 'two', label: '完成', count: 0),
              ],
              selected: 'one',
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('待检 (1234)'), findsOneWidget);
      expect(find.text('完成 (0)'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('待检 (1234)')).style!.fontFeatures,
        const [FontFeature.tabularFigures()],
      );
    },
  );
}
