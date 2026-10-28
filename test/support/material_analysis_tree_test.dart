import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_tree_expansion_button.dart';

import 'material_analysis_tree.dart';

class _TreeViewport extends StatefulWidget {
  const _TreeViewport({super.key, this.replaceOnExpand = false});
  final bool replaceOnExpand;

  @override
  State<_TreeViewport> createState() => _TreeViewportState();
}

class _TreeViewportState extends State<_TreeViewport> {
  final original = ScrollController(initialScrollOffset: 50);
  final replacement = ScrollController(initialScrollOffset: 120);
  var expanded = false;
  ScrollController get active =>
      expanded && widget.replaceOnExpand ? replacement : original;

  @override
  Widget build(BuildContext context) => ListView(
    key: ValueKey(expanded && widget.replaceOnExpand),
    controller: active,
    children: [
      const SizedBox(height: 200),
      UtenTreeExpansionButton(
        key: const ValueKey('material-analysis-bom-expansion-toggle'),
        expanded: expanded,
        onExpand: () {
          active.jumpTo(180);
          setState(() => expanded = true);
        },
        onCollapse: () => setState(() => expanded = false),
      ),
      const SizedBox(height: 1000),
    ],
  );

  @override
  void dispose() {
    original.dispose();
    replacement.dispose();
    super.dispose();
  }
}

void main() {
  for (final replace in [false, true]) {
    testWidgets(
      'tree helper: expansion preserves only the live viewport replace=$replace',
      (tester) async {
        final key = GlobalKey<_TreeViewportState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 400,
                child: _TreeViewport(key: key, replaceOnExpand: replace),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initialPosition = key.currentState!.active.position;
        expect(initialPosition.pixels, 50);
        await expandMaterialAnalysisTree(tester);
        expect(key.currentState!.expanded, isTrue);
        final currentPosition = key.currentState!.active.position;
        expect(currentPosition.pixels, replace ? 120 : 50);
        if (replace) {
          expect(currentPosition, isNot(same(initialPosition)));
        } else {
          expect(currentPosition, same(initialPosition));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('tree helper: an expanded tree is not collapsed again', (
    tester,
  ) async {
    var collapses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenTreeExpansionButton(
            key: const ValueKey('material-analysis-bom-expansion-toggle'),
            expanded: true,
            onExpand: () {},
            onCollapse: () => collapses++,
          ),
        ),
      ),
    );
    await expandMaterialAnalysisTree(tester);
    expect(collapses, 0);
  });

  testWidgets('tree helper: absent loading and empty trees stay untouched', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await expandMaterialAnalysisTree(tester, ifPresent: true);
    expect(tester.takeException(), isNull);
  });
}
