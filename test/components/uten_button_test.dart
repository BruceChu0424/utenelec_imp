import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

void main() {
  for (final direction in TextDirection.values) {
    for (final loading in [false, true]) {
      testWidgets(
        'normal-width long action keeps horizontal leading with intrinsic sizing loading=$loading $direction',
        (tester) async {
          tester.view.physicalSize = const Size(375, 480);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var presses = 0;
          const label = '确认更正 128 人 256 处员工证件信息并提交';
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: Directionality(
                    textDirection: direction,
                    child: IntrinsicWidth(
                      child: SizedBox(
                        width: 287,
                        child: IntrinsicHeight(
                          child: UtenButton(
                            size: UtenButtonSize.large,
                            icon: Icons.fact_check_outlined,
                            isLoading: loading,
                            onPressed: () => presses++,
                            child: const Text(label),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final text = tester.getRect(find.text(label));
          final leading = tester.getRect(
            loading
                ? find.byType(CircularProgressIndicator)
                : find.byIcon(Icons.fact_check_outlined),
          );
          expect(leading.center.dy, closeTo(text.center.dy, 0.01));
          if (direction == TextDirection.ltr) {
            expect(leading.right, lessThanOrEqualTo(text.left));
          } else {
            expect(text.right, lessThanOrEqualTo(leading.left));
          }
          expect(find.text(label).hitTestable(), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pump();
          expect(presses, loading ? 0 : 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final loading in [false, true]) {
      testWidgets(
        '72px action keeps its label and interaction loading=$loading $brightness',
        (tester) async {
          var presses = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 72,
                    child: UtenButton(
                      size: UtenButtonSize.large,
                      isExpanded: true,
                      isLoading: loading,
                      icon: Icons.check_circle_outline_rounded,
                      onPressed: () => presses++,
                      child: const Text('标记完成'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text('标记完成').hitTestable(), findsOneWidget);
          await tester.tap(find.text('标记完成'));
          await tester.pump();
          expect(presses, loading ? 0 : 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('is keyboard operable and exposes enabled button semantics', (
    tester,
  ) async {
    var presses = 0;
    var longPresses = 0;

    await tester.pumpWidget(
      _testApp(
        UtenButton(
          onPressed: () => presses++,
          onLongPress: () => longPresses++,
          child: const Text('Save'),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(UtenButton)),
      matchesSemantics(
        label: 'Save',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasLongPressAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);

    await tester.longPress(find.byType(UtenButton));
    await tester.pump();
    expect(longPresses, 1);
  });

  testWidgets('keeps disabled and loading fallback behavior accessible', (
    tester,
  ) async {
    var presses = 0;
    var disabledTaps = 0;
    var longPresses = 0;

    Future<void> pumpButton({required bool loading}) {
      return tester.pumpWidget(
        _testApp(
          UtenButton(
            onPressed: () => presses++,
            onDisabledTap: () => disabledTaps++,
            onLongPress: () => longPresses++,
            isLoading: loading,
            child: const Text('Submit'),
          ),
        ),
      );
    }

    await pumpButton(loading: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(UtenButton)),
      matchesSemantics(
        label: 'Submit',
        isButton: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.tap(find.byType(UtenButton));
    await tester.pump();
    expect(disabledTaps, 1);
    expect(presses, 0);

    await tester.longPress(find.byType(UtenButton));
    await tester.pump();
    expect(longPresses, 0);

    await pumpButton(loading: false);
    await tester.tap(find.byType(UtenButton));
    await tester.pump();
    expect(presses, 1);
    expect(disabledTaps, 1);
  });

  testWidgets('meets minimum target sizes and expands when requested', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenButton(
              key: Key('small'),
              size: UtenButtonSize.small,
              onPressed: _noop,
              child: Text('S'),
            ),
            UtenButton(key: Key('medium'), onPressed: _noop, child: Text('M')),
            UtenButton(
              key: Key('large'),
              size: UtenButtonSize.large,
              onPressed: _noop,
              child: Text('L'),
            ),
            SizedBox(
              width: 280,
              child: UtenButton(
                key: Key('expanded'),
                isExpanded: true,
                onPressed: _noop,
                child: Text('Expanded'),
              ),
            ),
          ],
        ),
      ),
    );

    final small = tester.getSize(find.byKey(const Key('small')));
    final medium = tester.getSize(find.byKey(const Key('medium')));
    final large = tester.getSize(find.byKey(const Key('large')));
    final expanded = tester.getSize(find.byKey(const Key('expanded')));

    expect(small.width, greaterThanOrEqualTo(44));
    expect(small.height, greaterThanOrEqualTo(44));
    expect(medium.width, greaterThanOrEqualTo(44));
    expect(medium.height, greaterThanOrEqualTo(44));
    expect(large.width, greaterThanOrEqualTo(48));
    expect(large.height, greaterThanOrEqualTo(48));
    expect(expanded.width, 280);
  });

  testWidgets('uses semantic color pairs for primary, success and danger', (
    tester,
  ) async {
    const primary = Color(0xFF123456);
    const onPrimary = Color(0xFFF1F2F3);
    const error = Color(0xFF8A1122);
    const onError = Color(0xFFFFEECC);
    const colorScheme = ColorScheme.light(
      primary: primary,
      onPrimary: onPrimary,
      error: error,
      onError: onError,
    );

    Future<void> pumpType(UtenButtonType type) {
      return tester.pumpWidget(
        _testApp(
          UtenButton(type: type, onPressed: _noop, child: const Text('Action')),
          theme: ThemeData(colorScheme: colorScheme),
        ),
      );
    }

    await pumpType(UtenButtonType.primary);
    expect(_buttonMaterial(tester).color, primary);
    expect(_buttonTextStyle(tester).color, onPrimary);

    await pumpType(UtenButtonType.success);
    expect(_buttonMaterial(tester).color, UtenColors.deepGreen);
    expect(_buttonTextStyle(tester).color, Colors.white);

    await pumpType(UtenButtonType.danger);
    expect(_buttonMaterial(tester).color, error);
    expect(_buttonTextStyle(tester).color, onError);
  });
}

Widget _testApp(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(body: Center(child: child)),
  );
}

Material _buttonMaterial(WidgetTester tester) {
  return tester.widget<Material>(
    find.descendant(
      of: find.byType(UtenButton),
      matching: find.byType(Material),
    ),
  );
}

TextStyle _buttonTextStyle(WidgetTester tester) {
  return DefaultTextStyle.of(tester.element(find.text('Action'))).style;
}

void _noop() {}
