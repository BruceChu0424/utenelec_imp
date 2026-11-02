import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_modal_bottom_sheet.dart';

void main() {
  testWidgets(
    'nested-page modal sheets cover shell navigation and expose Save',
    (tester) async {
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showUtenModalBottomSheet<void>(
                        context: context,
                        builder: (sheet) => SizedBox(
                          height: 240,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: TextButton(
                              onPressed: () {
                                saves++;
                                Navigator.pop(sheet);
                              },
                              child: const Text('保存测试'),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('打开表单'),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 70,
                  child: TextButton(
                    onPressed: () {},
                    child: const Text('底部导航'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('打开表单'));
      await tester.pumpAndSettle();
      expect(find.text('保存测试').hitTestable(), findsOneWidget);
      expect(find.text('底部导航').hitTestable(), findsNothing);
      await tester.tap(find.text('保存测试'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.text('底部导航').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
