import 'dart:ui' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';

/// Inspect the actual stable cell frame rather than an incidental Container or
/// SizedBox/decoration combination. Width budgets and pointer bounds use this.
Finder tableCellFrame(Finder descendant) => find
    .ancestor(of: descendant, matching: find.byType(UtenTableCellFrame))
    .first;

double tableCellWidth(WidgetTester tester, Finder descendant) =>
    tester.getSize(tableCellFrame(descendant)).width;

Color tableCellBackgroundColor(WidgetTester tester, Finder descendant) {
  final color = tester
      .widget<UtenTableCellFrame>(tableCellFrame(descendant))
      .backgroundColor;
  expect(color, isNotNull, reason: 'Read the actual semantic cell surface.');
  return color!;
}
