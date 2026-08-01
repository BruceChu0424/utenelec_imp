import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_segmented_filter.dart';

void main() {
  testWidgets('shows counts, selection semantics, and 44dp touch targets', (
    tester,
  ) async {
    var selected = 'all';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return UtenSegmentedFilter<String>(
                segments: const [
                  UtenSegment(value: 'all', label: 'All', count: 12),
                  UtenSegment(value: 'pending', label: 'Pending', count: 3),
                ],
                selected: selected,
                onChanged: (value) => setState(() => selected = value),
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('All (12)'), findsOneWidget);
    expect(find.text('Pending (3)'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('All (12)')),
      matchesSemantics(
        label: 'All (12)',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    for (final label in ['All (12)', 'Pending (3)']) {
      final target = find.ancestor(
        of: find.text(label),
        matching: find.byType(AnimatedContainer),
      );
      final size = tester.getSize(target);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }

    await tester.tap(find.text('Pending (3)'));
    await tester.pumpAndSettle();

    expect(selected, 'pending');
    expect(
      tester.getSemantics(find.text('Pending (3)')),
      matchesSemantics(
        label: 'Pending (3)',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
  });
}
