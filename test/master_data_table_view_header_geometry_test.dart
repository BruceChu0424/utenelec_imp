import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final declaredInfo in [false, true]) {
      testWidgets(
        'header guidance and menu fit after resize: $platform declared=$declaredInfo',
        (tester) async {
          tester.view.physicalSize = const Size(900, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLightTheme().copyWith(platform: platform),
              builder: (_, child) =>
                  UtenDisplayZoomBox(fontFactor: 0.85, child: child!),
              home: Scaffold(
                body: MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef<String>(
                      key: 'number',
                      label: '号',
                      width: 48,
                      sortable: true,
                      info: declaredInfo ? '真实列说明' : null,
                      value: (row) => row,
                    ),
                  ],
                  items: const ['1'],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  totalPages: 2,
                  onPageChange: (_) {},
                  onSortChange: declaredInfo ? (_, _) {} : null,
                  showFullscreenToggle: false,
                  showColumnChooser: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final header = find
              .ancestor(
                of: find.text('号'),
                matching: find.byWidgetPredicate((widget) {
                  if (widget is! Container) return false;
                  final box = widget.constraints;
                  return box != null &&
                      box.maxWidth.isFinite &&
                      box.minWidth == box.maxWidth;
                }),
              )
              .first;
          final grip = find.descendant(
            of: header,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is GestureDetector &&
                  widget.onHorizontalDragUpdate != null &&
                  widget.onHorizontalDragStart == null,
            ),
          );
          expect(grip, findsOneWidget);
          await tester.dragFrom(
            tester.getCenter(grip) - const Offset(2, 0),
            const Offset(-400, 0),
          );
          await tester.pumpAndSettle();
          final hint = find.descendant(
            of: header,
            matching: find.byType(UtenColumnHintIcon),
          );
          final menu = find.descendant(
            of: header,
            matching: find.byIcon(Icons.arrow_drop_down_rounded),
          );
          expect(hint, findsOneWidget);
          expect(menu, findsOneWidget);
          final bounds = tester.getRect(header);
          for (final target in [hint, menu]) {
            final rect = tester.getRect(target);
            expect(rect.left, greaterThanOrEqualTo(bounds.left));
            expect(rect.right, lessThanOrEqualTo(bounds.right));
            expect(target.hitTestable(), findsOneWidget);
          }
          if (platform == TargetPlatform.android) {
            final rect = tester.getRect(hint);
            expect(rect.width, greaterThanOrEqualTo(47.9));
            expect(rect.height, greaterThanOrEqualTo(47.9));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
