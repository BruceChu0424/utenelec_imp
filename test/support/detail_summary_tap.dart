import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';

Finder detailSummaryField(String label, {Finder? summary}) {
  final field = find.byWidgetPredicate(
    (widget) => widget is UtenSummaryField && widget.label == label,
    skipOffstage: false,
  );
  return summary == null
      ? field
      : find.descendant(of: summary, matching: field, skipOffstage: false);
}

Future<void> setDetailSummaryExpanded(
  WidgetTester tester, {
  Finder? summary,
  bool expanded = true,
}) async {
  final card =
      summary ?? find.byType(UtenDetailSummaryCard, skipOffstage: false);
  expect(card, findsOneWidget);
  final toggle = find.descendant(
    of: card,
    matching: find.byKey(
      const ValueKey('detail-summary-toggle'),
      skipOffstage: false,
    ),
    skipOffstage: false,
  );
  expect(toggle, findsOneWidget);
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  final semantics = find
      .ancestor(
        of: toggle,
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.expanded != null,
          skipOffstage: false,
        ),
      )
      .first;
  if (tester.widget<Semantics>(semantics).properties.expanded == expanded) {
    return;
  }
  expect(toggle.hitTestable(), findsOneWidget);
  await tester.tap(toggle.hitTestable());
  await tester.pumpAndSettle();
  expect(tester.widget<Semantics>(semantics).properties.expanded, expanded);
}

Future<UtenSummaryField> expectVisibleDetailSummaryField(
  WidgetTester tester,
  String label,
  String value, {
  Finder? summary,
}) async {
  final field = detailSummaryField(label, summary: summary);
  expect(field, findsOneWidget);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  final widget = tester.widget<UtenSummaryField>(field);
  expect(widget.value, value, reason: '完整原值与币种必须保留');
  for (final text in [label, value]) {
    final rendered = find.descendant(
      of: field,
      matching: find.text(text, skipOffstage: false),
      skipOffstage: false,
    );
    expect(rendered, findsOneWidget);
    await tester.ensureVisible(rendered);
    await tester.pumpAndSettle();
    expect(rendered.hitTestable(), findsOneWidget);
  }
  return widget;
}
