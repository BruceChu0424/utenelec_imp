import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('table fields preserve command targets $platform $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(800, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = TextEditingController(text: '12.3456');
        addTearDown(controller.dispose);
        var invoked = 0;
        final floor = platform == TargetPlatform.windows ? 32.0 : 48.0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: UtenTableCellInputTheme(
                child: Builder(
                  builder: (context) {
                    final style = ButtonStyle(
                      minimumSize: WidgetStatePropertyAll(Size(32, floor)),
                      padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                    return Column(
                      children: [
                        SizedBox(
                          width: 300,
                          child: TextField(
                            key: const Key('table-field'),
                            controller: controller,
                          ),
                        ),
                        TextButton(
                          key: const Key('text-command'),
                          style: style,
                          onPressed: () => invoked++,
                          child: const Text('Undo'),
                        ),
                        FilledButton(
                          key: const Key('filled-command'),
                          style: style,
                          onPressed: () => invoked++,
                          child: const Text('Undo'),
                        ),
                        OutlinedButton(
                          key: const Key('outlined-command'),
                          style: style,
                          onPressed: () => invoked++,
                          child: const Text('Undo'),
                        ),
                        ElevatedButton(
                          key: const Key('elevated-command'),
                          style: style,
                          onPressed: () => invoked++,
                          child: const Text('Undo'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('table-field'))).height,
          greaterThanOrEqualTo(floor),
        );
        for (final kind in ['text', 'filled', 'outlined', 'elevated']) {
          final action = find.byKey(Key('$kind-command'));
          expect(tester.getSize(action).height, greaterThanOrEqualTo(floor));
          expect(action.hitTestable(), findsOneWidget);
          await tester.tap(action);
        }
        await tester.pumpAndSettle();
        expect(invoked, 4);
        expect(controller.text, '12.3456');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
