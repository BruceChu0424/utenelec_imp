import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';

void main() {
  testWidgets('clear emits once and cancels a pending debounced search', (
    tester,
  ) async {
    final changes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenSearchBar(
            debounce: const Duration(milliseconds: 100),
            onChanged: changes.add,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'query');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(changes, const ['']);
    expect(find.text('query'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(changes, const ['']);
  });

  testWidgets(
    'input callback is immediate while search callback is debounced',
    (tester) async {
      final inputs = <String>[];
      final searches = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenSearchBar(
              debounce: const Duration(milliseconds: 100),
              onInputChanged: inputs.add,
              onChanged: searches.add,
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'new');
      await tester.pump();
      expect(inputs, const ['new']);
      expect(searches, isEmpty);

      await tester.pump(const Duration(milliseconds: 100));
      expect(searches, const ['new']);
    },
  );

  testWidgets('uncontrolled text follows a changed initial value', (
    tester,
  ) async {
    var value = 'first';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return UtenSearchBar(initialValue: value);
            },
          ),
        ),
      ),
    );
    expect(find.text('first'), findsOneWidget);

    rebuild(() => value = 'second');
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });

  // 2026-10-09 输入法组合保护：拼音组合中（composing 非空）不派发任何回调，
  // 停顿超过防抖窗口也不发；选字上屏后才按正常防抖派发一次。
  testWidgets('IME composition holds callbacks until the text is committed', (
    tester,
  ) async {
    final inputs = <String>[];
    final searches = <String>[];
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenSearchBar(
            controller: controller,
            debounce: const Duration(milliseconds: 100),
            onInputChanged: inputs.add,
            onChanged: searches.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    // 拼音 "l"（组合中）→ 不派发。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'l', composing: TextRange(start: 0, end: 1)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(inputs, isEmpty);
    expect(searches, isEmpty);

    // 拼音补到 "li"（仍组合中），停顿远超防抖 → 仍不派发。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'li',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(inputs, isEmpty);
    expect(searches, isEmpty);

    // 选字上屏「李」：文本变化走 onChanged 路径 → 防抖后派发一次。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '李',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(inputs, const ['李']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(searches, const ['李']);
  });

  // 组合原样上屏（回车提交拼音/失焦提交）：文本不变、onChanged 不触发，
  // 由 controller 监听补发——否则这半截拼音永远不会被检索。
  testWidgets('raw IME commit without text change still dispatches', (
    tester,
  ) async {
    final inputs = <String>[];
    final searches = <String>[];
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenSearchBar(
            controller: controller,
            debounce: const Duration(milliseconds: 100),
            onInputChanged: inputs.add,
            onChanged: searches.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'li',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(inputs, isEmpty);

    // 回车把拼音原样上屏：composing 清空、文本仍为 "li"。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'li',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(inputs, const ['li']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(searches, const ['li']);
  });

  // 组合中点清除：挂起的组合文本不派发，清除即回到全量。
  testWidgets('clear during composition cancels the held text', (tester) async {
    final searches = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenSearchBar(
            debounce: const Duration(milliseconds: 100),
            onChanged: searches.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'li',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(searches, const ['']);
    await tester.pump(const Duration(milliseconds: 200));
    expect(searches, const ['']);
    expect(find.text('li'), findsNothing);
  });
}
