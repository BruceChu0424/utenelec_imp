import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

Widget _app(
  Widget child, {
  TargetPlatform platform = TargetPlatform.windows,
  double textScale = 1,
}) => MaterialApp(
  theme: buildLightTheme().copyWith(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(1000, 800),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets(
    'compact goods controls navigate and sync external reading page',
    (tester) async {
      final calls = <int>[];
      Widget pager(int page) => _app(
        UtenPagination(
          currentPage: page,
          totalPages: 4,
          onPageChanged: calls.add,
          inputOutlineKey: const Key('compact-page-outline'),
        ),
      );
      await tester.pumpWidget(pager(1));
      expect(find.text('上一页'), findsNothing);
      expect(find.text('下一页'), findsNothing);
      expect(find.text('/ 4'), findsOneWidget);
      final previous = find.byKey(const ValueKey('master-table-page-previous'));
      final next = find.byKey(const ValueKey('master-table-page-next'));
      expect(tester.widget<IconButton>(previous).onPressed, isNull);
      expect(tester.getSize(next), const Size(32, 32));
      expect(
        tester.getSize(find.byKey(const Key('compact-page-outline'))).height,
        28,
      );
      await tester.tap(next);
      expect(calls, [2]);
      await tester.pumpWidget(pager(4));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '4',
      );
      expect(tester.widget<IconButton>(next).onPressed, isNull);
      await tester.tap(previous);
      expect(calls, [2, 3]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('page entry rejects invalid input and clamps both boundaries', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(
      _app(
        UtenPagination(
          currentPage: 2,
          totalPages: 12,
          onPageChanged: calls.add,
        ),
      ),
    );
    final input = find.byType(TextField);
    Future<void> submit(String text) async {
      await tester.enterText(input, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    await submit('not a page');
    expect(calls, isEmpty);
    expect(tester.widget<TextField>(input).controller!.text, '2');
    await submit('99');
    expect(calls, [12]);
    expect(tester.widget<TextField>(input).controller!.text, '12');
    await submit('0');
    expect(calls, [12, 1]);
    expect(tester.widget<TextField>(input).controller!.text, '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cursor horizon limits jumps while total remains unknown', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(
      _app(
        UtenPagination(
          currentPage: 3,
          totalPages: null,
          maxPage: 4,
          onPageChanged: calls.add,
        ),
      ),
    );
    expect(find.text('/ ?'), findsOneWidget);
    expect(find.text('/ 4'), findsNothing);
    await tester.enterText(find.byType(TextField), '1000000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(calls, [4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy navigation disables arrows and keyboard entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        UtenPagination(
          currentPage: 2,
          totalPages: 4,
          busy: true,
          onPageChanged: (_) => fail('busy page navigation'),
          onPrevious: () => fail('busy previous callback'),
          onNext: () => fail('busy next callback'),
        ),
      ),
    );
    for (final arrow in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(arrow.onPressed, isNull);
    }
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('unsubmitted draft restores actual page on focus loss', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        UtenPagination(currentPage: 3, totalPages: 4, onPageChanged: (_) {}),
      ),
    );
    final input = find.byType(TextField);
    await tester.enterText(input, '99');
    tester.widget<TextField>(input).focusNode!.unfocus();
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '3');
  });

  for (final width in [160.0, 80.0]) {
    testWidgets('touch targets and counter survive narrow width $width', (
      tester,
    ) async {
      final calls = <int>[];
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: width,
            child: UtenPagination(
              currentPage: 1,
              totalPages: 1000000,
              onPageChanged: calls.add,
            ),
          ),
          platform: TargetPlatform.android,
          textScale: 2,
        ),
      );
      final next = find.byKey(const ValueKey('master-table-page-next'));
      expect(find.text('1 / 1000000'), findsOneWidget);
      expect(tester.getSize(next), const Size(48, 48));
      await tester.tap(next);
      expect(calls, [2]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('page entry expands for digits and large text without clipping', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        UtenPagination(
          currentPage: 1,
          totalPages: 1000000,
          onPageChanged: (_) {},
        ),
        textScale: 2,
      ),
    );
    final input = find.byType(TextField);
    final initial = tester.getSize(input);
    await tester.enterText(input, '1000000');
    await tester.pump();
    expect(tester.getSize(input).width, greaterThan(initial.width));
    expect(tester.getSize(input).height, greaterThanOrEqualTo(42));
    expect(tester.takeException(), isNull);
  });
}
