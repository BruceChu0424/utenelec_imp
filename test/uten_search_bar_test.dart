import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';

void main() {
  for (final submitOnly in [false, true]) {
    testWidgets(
      'controlled clear shares actual pending query dispatch: submitOnly=$submitOnly',
      (tester) async {
        final controller = TextEditingController(text: '张');
        addTearDown(controller.dispose);
        final requests = <String>[];
        String? pending;
        var lastText = controller.text;
        void search(String value) {
          requests.add(value);
          pending = value;
        }

        controller.addListener(() {
          if (lastText == controller.text) return;
          lastText = controller.text;
          search(controller.text);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UtenSearchBar(
                controller: controller,
                isQueryPending: (text) => pending == text,
                onChanged: submitOnly ? null : search,
                onSubmitted: submitOnly ? search : null,
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pump();
        expect(controller.text, isEmpty);
        expect(requests, ['']);
        await tester.showKeyboard(find.byType(TextField));
        await tester.testTextInput.receiveAction(TextInputAction.search);
        expect(requests, ['']);
        pending = null;
        await tester.showKeyboard(find.byType(TextField));
        await tester.testTextInput.receiveAction(TextInputAction.search);
        expect(requests, ['', '']);
        await tester.pump(const Duration(milliseconds: 400));
        expect(requests, ['', '']);
      },
    );
  }
  testWidgets(
    'Enter applies a pending keyword immediately without a later duplicate',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: UtenSearchBar(onChanged: changes.add)),
        ),
      );
      await tester.enterText(find.byType(TextField), '张');
      await tester.pump(const Duration(milliseconds: 40));
      expect(changes, isEmpty);
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(changes, ['张']);
      await tester.pump(const Duration(milliseconds: 400));
      expect(changes, ['张']);
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(changes, ['张', '张']);
    },
  );

  testWidgets(
    'pending exact-query Enter is suppressed while completed and replacement queries submit',
    (tester) async {
      String? pending;
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenSearchBar(
              isQueryPending: (value) => pending == value,
              onChanged: (value) {
                changes.add(value);
                pending = value;
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '张');
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 400));
      expect(changes, ['张']);
      pending = null;
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(changes, ['张', '张']);
      await tester.enterText(find.byType(TextField), '李');
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(changes, ['张', '张', '李']);
      await tester.pump(const Duration(milliseconds: 400));
      expect(changes, ['张', '张', '李']);
    },
  );

  testWidgets(
    'a collapsed composing range commits once instead of leaving search suspended',
    (tester) async {
      final changes = <String>[];
      final inputs = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenSearchBar(
              onInputChanged: inputs.add,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '张',
          composing: TextRange(start: 0, end: 1),
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(changes, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '张',
          composing: TextRange.collapsed(1),
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 301));
      expect(inputs, ['张']);
      expect(changes, ['张']);
    },
  );

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
  for (final alreadyApplied in [false, true]) {
    testWidgets(
      'external controller clear accepts the same word again after ${alreadyApplied ? 'applied' : 'pending'} search',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final inputs = <String>[], changes = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UtenSearchBar(
                controller: controller,
                debounce: const Duration(milliseconds: 100),
                onInputChanged: inputs.add,
                onChanged: changes.add,
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), '螺丝');
        if (alreadyApplied) {
          await tester.pump(const Duration(milliseconds: 101));
        }
        expect(inputs, ['螺丝']);
        expect(changes, alreadyApplied ? ['螺丝'] : isEmpty);
        controller.clear();
        await tester.pump(const Duration(milliseconds: 150));
        expect(inputs, ['螺丝'], reason: '程序复位不能替宿主重放查询');
        expect(
          changes,
          alreadyApplied ? ['螺丝'] : isEmpty,
          reason: '外部复位必须撤销旧防抖，不能发布旧仓查询',
        );
        await tester.enterText(find.byType(TextField), '螺丝');
        await tester.pump(const Duration(milliseconds: 101));
        expect(inputs, ['螺丝', '螺丝']);
        expect(changes, alreadyApplied ? ['螺丝', '螺丝'] : ['螺丝']);
      },
    );
  }

  testWidgets(
    'external controller clear retires held IME without replaying it',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final inputs = <String>[], changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenSearchBar(
              controller: controller,
              debounce: const Duration(milliseconds: 100),
              onInputChanged: inputs.add,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'li',
          composing: TextRange(start: 0, end: 2),
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(inputs, isEmpty);
      expect(changes, isEmpty);
      controller.clear();
      await tester.pump(const Duration(milliseconds: 150));
      expect(inputs, isEmpty);
      expect(changes, isEmpty);
      await tester.enterText(find.byType(TextField), 'li');
      await tester.pump(const Duration(milliseconds: 101));
      expect(inputs, ['li']);
      expect(changes, ['li']);
    },
  );
}
