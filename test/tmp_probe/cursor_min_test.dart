// ignore_for_file: avoid_print
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('minimal selectionarea cursor', (tester) async {
    String? cursor;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.mouseCursor, (call) async {
      cursor = 'a=${call.arguments}';
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SelectionArea(
            child: Column(children: const [
              Text('AAA'),
              MouseRegion(cursor: SystemMouseCursors.text, child: Text('BBB')),
              Align(alignment: Alignment.centerLeft, child: Text('CCC')),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 99);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    for (final label in ['AAA', 'BBB', 'CCC']) {
      cursor = null;
      await gesture.moveTo(tester.getCenter(find.text(label)));
      await tester.pump();
      print('CURSOR $label=$cursor');
    }
  });
}
