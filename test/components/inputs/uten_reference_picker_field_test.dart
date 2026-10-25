import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';

Widget _host(
  TextEditingController controller, {
  required Future<List<String>> Function(String) load,
  ValueChanged<String>? selected,
  Future<void> Function(String)? open,
  bool bottom = false,
  bool dark = false,
  double scale = 1,
  Object? scope,
  bool Function()? isCurrent,
}) => MaterialApp(
  theme: dark ? ThemeData.dark() : ThemeData.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: bottom ? Alignment.bottomCenter : Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 360,
          child: UtenReferencePickerField<String>(
            controller: controller,
            label: '模具',
            hint: '模具',
            loadSuggestions: load,
            labelOf: (v) => v,
            onSelected: selected ?? (_) {},
            onInputChanged: (_) {},
            onOpenPicker: open ?? (_) async {},
            suggestionScope: scope,
            isCurrent: isCurrent,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'a boundary transition fences an already visible candidate before rebuild',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var epoch = 0;
      var picks = 0;
      await tester.pumpWidget(
        _host(
          controller,
          load: (_) async => ['旧身份候选'],
          selected: (_) => picks++,
          scope: 0,
          isCurrent: () => epoch == 0,
        ),
      );
      await tester.enterText(find.byType(TextField), '候选');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      final staleTap = tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: find.text('旧身份候选'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!;
      epoch +=
          2; // Revoked and restored before the next frame is still a new epoch.
      staleTap();
      expect(picks, 0);
      await tester.pumpWidget(
        _host(
          controller,
          load: (_) async => ['新身份候选'],
          scope: epoch,
          selected: (_) => picks++,
          isCurrent: () => true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧身份候选'), findsNothing);
      expect(picks, 0);
    },
  );

  testWidgets('late results cannot cross a replaced business scope', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final pending = Completer<List<String>>();
    await tester.pumpWidget(
      _host(controller, scope: 'old-parent', load: (_) => pending.future),
    );
    await tester.enterText(find.byType(TextField), '开关');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpWidget(
      _host(controller, scope: 'new-parent', load: (_) async => ['新组件']),
    );
    pending.complete(['旧父级组件']);
    await tester.pumpAndSettle();
    expect(find.text('旧父级组件'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composition waits for committed text and typing never selects a record',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final queries = <String>[];
      String? picked;
      await tester.pumpWidget(
        _host(
          controller,
          load: (q) async {
            queries.add(q);
            return ['5M开关模具'];
          },
          selected: (v) => picked = v,
        ),
      );
      await tester.tap(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'kai',
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(queries, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '开关'),
      );
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(queries, ['开关']);
      expect(picked, isNull);
      await tester.tap(find.text('5M开关模具'));
      await tester.pumpAndSettle();
      expect(picked, '5M开关模具');
      expect(controller.text, '5M开关模具');
      expect(find.text('展开分类和筛选'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new edits immediately discard pending old candidates', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final old = Completer<List<String>>();
    final fresh = Completer<List<String>>();
    await tester.pumpWidget(
      _host(controller, load: (q) => q == '旧' ? old.future : fresh.future),
    );
    await tester.enterText(find.byType(TextField), '旧');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.enterText(find.byType(TextField), '新');
    old.complete(['旧候选']);
    await tester.pump();
    expect(find.text('旧候选'), findsNothing);
    await tester.pump(const Duration(milliseconds: 301));
    fresh.complete(['新候选']);
    await tester.pumpAndSettle();
    expect(find.text('新候选'), findsOneWidget);
  });

  testWidgets('picker button carries the pending query and cancels debounce', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final requests = <String>[];
    String? query;
    await tester.pumpWidget(
      _host(
        controller,
        load: (q) async {
          requests.add(q);
          return [];
        },
        open: (q) async {
          query = q;
          controller.text = '已选择模具';
        },
      ),
    );
    await tester.enterText(find.byType(TextField), '5M');
    await tester.tap(find.byKey(const ValueKey('uten-reference-open-picker')));
    await tester.pumpAndSettle();
    expect(query, '5M');
    expect(requests, isEmpty);
    expect(controller.text, '已选择模具');
  });

  testWidgets(
    'above-field candidates stay inside a compact dark enlarged viewport',
    (tester) async {
      tester.view.physicalSize = const Size(420, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      String? picked;
      await tester.pumpWidget(
        _host(
          controller,
          bottom: true,
          dark: true,
          scale: 1.6,
          load: (_) async => ['第一模具', '第二模具'],
          selected: (v) => picked = v,
        ),
      );
      await tester.enterText(find.byType(TextField), '模具');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      final candidate = tester.getRect(find.text('第一模具'));
      expect(candidate.top, greaterThanOrEqualTo(0));
      expect(
        candidate.bottom,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, '第二模具');
      expect(tester.takeException(), isNull);
    },
  );
}
