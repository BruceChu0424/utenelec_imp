import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_inline_edit_cell.dart';

void main() {
  testWidgets('reverting during an in-flight update retains the latest input', (
    tester,
  ) async {
    final first = Completer<void>();
    final calls = <String>[];
    final controller = BomLiveEditController(
      value: '1',
      isCurrent: () => true,
      onStateChanged: () {},
      apply: (value) async {
        calls.add(value);
        if (calls.length == 1) await first.future;
      },
    );
    addTearDown(controller.dispose);
    controller.text.text = '2';
    controller.change('2');
    await tester.pump(const Duration(milliseconds: 251));
    expect(calls, ['2']);
    controller.text.text = '1';
    controller.change('1');
    controller.synchronize('2');
    expect(controller.text.text, '1');
    first.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, ['2', '1']);
    expect(controller.pending, false);
    expect(controller.accepted, '1');
  });
}
