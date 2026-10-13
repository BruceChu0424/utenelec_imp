import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets(
    'null callback disables interaction, semantics and selected fill',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const UtenSegmentRow<String>(
            segments: [
              ButtonSegment(value: 'all', label: Text('全部活动账户')),
              ButtonSegment(value: 'selected', label: Text('仅选定账户')),
            ],
            selected: {'all'},
          ),
        ),
      );

      final buttons = tester.widgetList<Semantics>(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.button == true,
        ),
      );
      expect(buttons, hasLength(2));
      expect(
        buttons.every((button) => button.properties.enabled == false),
        isTrue,
      );
      final taps = tester.widgetList<InkWell>(find.byType(InkWell));
      expect(taps.every((tap) => tap.onTap == null), isTrue);
      final selectedMaterial = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('全部活动账户'),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Material && widget.type == MaterialType.canvas,
              ),
            )
            .first,
      );
      expect(selectedMaterial.color, Colors.transparent);
    },
  );

  testWidgets('explicitly disabled segment stays disabled beside enabled one', (
    tester,
  ) async {
    var selected = 'all';
    await tester.pumpWidget(
      _app(
        UtenSegmentRow<String>(
          segments: const [
            ButtonSegment(value: 'all', label: Text('全部')),
            ButtonSegment(
              value: 'blocked',
              label: Text('不可操作'),
              enabled: false,
            ),
          ],
          selected: const {'all'},
          onSelectionChanged: (values) => selected = values.single,
        ),
      ),
    );

    await tester.tap(find.text('不可操作'));
    await tester.pump();
    expect(selected, 'all');
    final buttons = tester.widgetList<Semantics>(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.button == true,
      ),
    );
    expect(buttons.map((button) => button.properties.enabled), [true, false]);
  });
}
