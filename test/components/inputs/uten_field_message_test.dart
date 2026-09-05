import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';

void main() {
  const longMessage = '本位币调账额必须与原币差额保持同一方向，请重新核对后再提交。';

  testWidgets('shows disclosure only when the rendered message overflows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(width: 320, child: const UtenFieldMessage.autofill('短提示')),
    );

    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);

    await tester.pumpWidget(
      _host(width: 160, child: const UtenFieldMessage.error(longMessage)),
    );
    await tester.pump();

    final help = find.byIcon(Icons.help_outline_rounded);
    expect(help, findsOneWidget);
    final helpButton = find.ancestor(
      of: help,
      matching: find.byType(IconButton),
    );
    final helpSize = tester.getSize(helpButton);
    expect(helpSize.width, greaterThanOrEqualTo(44));
    expect(helpSize.height, greaterThanOrEqualTo(44));

    final visibleText = tester.widget<Text>(find.text(longMessage).first);
    expect(visibleText.maxLines, 1);
    expect(visibleText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('full text is available by hover, tap and keyboard focus', (
    tester,
  ) async {
    Future<void> pumpMessage() => tester.pumpWidget(
      _host(width: 160, child: const UtenFieldMessage.error(longMessage)),
    );

    await pumpMessage();
    final help = find.byIcon(Icons.help_outline_rounded);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(help));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(longMessage), findsNWidgets(2));

    await mouse.moveTo(const Offset(800, 800));
    await tester.pumpAndSettle();
    await pumpMessage();
    await tester.tap(help);
    await tester.pump();
    expect(find.text(longMessage), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpMessage();
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.help_outline_rounded),
        matching: find.byType(IconButton),
      ),
    );
    button.focusNode!.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(find.text(longMessage), findsNWidgets(2));
  });

  testWidgets('error exposes the full live-region message to semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(width: 160, child: const UtenFieldMessage.error(longMessage)),
    );

    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == longMessage &&
            widget.properties.liveRegion == true,
      ),
    );
    expect(semantics.properties.liveRegion, isTrue);
  });

  testWidgets('large text stays bounded and discoverable in dark mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Center(
              child: SizedBox(
                width: 180,
                child: UtenFieldMessage.error(longMessage),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    final visibleText = tester.widget<Text>(find.text(longMessage).first);
    expect(visibleText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('UtenInput uses the shared message for validator errors', (
    tester,
  ) async {
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(
      _host(
        width: 220,
        child: Form(
          key: formKey,
          child: UtenInput(
            label: '金额',
            info: '请输入账户原币金额',
            validator: (_) => longMessage,
          ),
        ),
      ),
    );

    // 字段说明收进标签旁 ⓘ（悬停提示），不再常驻框下。
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byTooltip('请输入账户原币金额'), findsOneWidget);
    expect(find.text('请输入账户原币金额'), findsNothing);

    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldMessage &&
            widget.kind == UtenFieldMessageKind.error &&
            widget.message == longMessage,
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
  });
}

Widget _host({required double width, required Widget child}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}
