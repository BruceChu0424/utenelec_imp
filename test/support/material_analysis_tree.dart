import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_tree_expansion_button.dart';

/// Reveals BOM descendants through the same local presentation action as a user.
/// Loading/empty fixtures can opt out when no analysis tree is mounted yet.
Future<void> expandMaterialAnalysisTree(
  WidgetTester tester, {
  bool ifPresent = false,
}) async {
  final toggle = find.byKey(
    const ValueKey('material-analysis-bom-expansion-toggle'),
  );
  if (ifPresent && toggle.evaluate().isEmpty) return;
  expect(toggle, findsOneWidget);
  final button = tester.widget<UtenTreeExpansionButton>(toggle);
  if (button.expanded) return;
  expect(button.isLoading, isFalse);
  expect(button.onExpand, isNotNull);

  // Setup must not leave the folding page header scrolled away. Only reveal
  // the button when it is outside the current viewport, then restore offsets.
  final offsets = <ScrollableState, ({ScrollPosition position, double pixels})>{
    for (final state in tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    ))
      if (state.position.hasPixels)
        state: (position: state.position, pixels: state.position.pixels),
  };
  if (toggle.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
  }
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  expect(tester.widget<UtenTreeExpansionButton>(toggle).expanded, isTrue);

  for (final entry in offsets.entries) {
    final owner = entry.key;
    // Reading ScrollPosition.context.storageContext first would call context
    // on a disposed ScrollableState. Expansion can replace that whole viewport.
    if (!owner.mounted || !identical(owner.position, entry.value.position)) {
      continue;
    }
    final position = entry.value.position;
    if (!position.hasContentDimensions) continue;
    final offset = entry.value.pixels
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((position.pixels - offset).abs() > 0.5) position.jumpTo(offset);
  }
  await tester.pumpAndSettle();
}
