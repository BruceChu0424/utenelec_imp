import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

const _leadingKey = ValueKey('controlled-width-leading');

Widget _host(ValueNotifier<double?> width, {String? persistenceKey}) =>
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<double?>(
          valueListenable: width,
          builder: (_, value, child) => UtenSplitView(
            controlledLeadingWidth: value,
            persistenceKey: persistenceKey,
            onWidthChanged: (value) => width.value = value,
            leading: const SizedBox.expand(key: _leadingKey),
            trailing: child!,
          ),
          child: const TextField(),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('late preference restoration cannot replace a controlled width', (
    tester,
  ) async {
    SharedPreferences.resetStatic();
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    final loaded = Completer<Map<String, Object>>();
    var reads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getAll' || call.method == 'getAllWithParameters') {
        reads++;
        return loaded.future;
      }
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      SharedPreferences.setMockInitialValues({});
    });
    final width = ValueNotifier<double?>(null);
    addTearDown(width.dispose);
    await tester.pumpWidget(_host(width, persistenceKey: 'controlled-race'));
    expect(reads, 1);
    expect(tester.getSize(find.byKey(_leadingKey)).width, 300);
    width.value = 410;
    await tester.pump();
    loaded.complete({'flutter.uten.splitView.controlled-race': 250.0});
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_leadingKey)).width, 410);
  });

  testWidgets('controlled updates and drag retain child state', (tester) async {
    SharedPreferences.setMockInitialValues({
      'uten.splitView.controlled-initial': 250.0,
    });
    final width = ValueNotifier<double?>(360);
    addTearDown(width.dispose);
    await tester.pumpWidget(_host(width, persistenceKey: 'controlled-initial'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_leadingKey)).width, 360);
    await tester.enterText(find.byType(TextField), '未保存的内容');
    width.value = 400;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_leadingKey)).width, 400);
    expect(find.text('未保存的内容'), findsOneWidget);
    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(width.value, lessThan(400));
    expect(tester.getSize(find.byKey(_leadingKey)).width, width.value);
    expect(find.text('未保存的内容'), findsOneWidget);
  });
}
