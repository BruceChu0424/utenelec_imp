import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/shared/widgets/business_precision_dialog.dart';

const _requirement = BusinessPrecisionRequirement(
  key: 'current-ratios',
  groupKey: 'current-ratios',
  label: '本次报表比率',
  maxScale: 30,
  suggestedScale: 2,
  reason: 'NON_TERMINATING',
);
void main() {
  testWidgets(
    'suggestion is not a selected default and both choices require explicit user input',
    (tester) async {
      BusinessPrecisionChoice? result;
      await _mount(tester, onResult: (choice) => result = choice);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final input = tester.widget<UtenInput>(
        find.byWidgetPredicate((w) => w is UtenInput && w.label == '保留小数位数'),
      );
      expect(input.controller!.text, isEmpty);
      final dropdown = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '处理方式',
        ),
      );
      expect(dropdown.value, isNull);
      expect(_confirm(tester).onPressed, isNull);
      input.controller!.text = '3';
      await tester.pumpAndSettle();
      expect(_confirm(tester).onPressed, isNull);
      await tester.tap(find.text('处理方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接截取，不进位').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认本次精度'));
      await tester.pumpAndSettle();
      expect(result?.scale, 3);
      expect(result?.rounding, 'DOWN');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'invalid scale and identity ABA cannot publish a stale selection',
    (tester) async {
      final validity = ValueNotifier(0);
      addTearDown(validity.dispose);
      BusinessPrecisionChoice? result;
      await _mount(
        tester,
        validity: validity,
        onResult: (choice) => result = choice,
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final input = tester.widget<UtenInput>(
        find.byWidgetPredicate((w) => w is UtenInput && w.label == '保留小数位数'),
      );
      input.controller!.text = '31';
      await tester.pumpAndSettle();
      expect(_confirm(tester).onPressed, isNull);
      validity.value = 1;
      await tester.pumpAndSettle();
      validity.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('本次报表比率'), findsNothing);
      expect(_confirm(tester).onPressed, isNull);
      await tester.tap(find.text('取消，保留原输入'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow enlarged dialog keeps both decisions and cancellation reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, scale: 1.5);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('取消，保留原输入'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消，保留原输入'));
      await tester.pumpAndSettle();
    },
  );
}

UtenButton _confirm(WidgetTester tester) =>
    tester.widget<UtenButton>(find.widgetWithText(UtenButton, '确认本次精度'));
Future<void> _mount(
  WidgetTester tester, {
  double scale = 1,
  ValueNotifier<int>? validity,
  void Function(BusinessPrecisionChoice?)? onResult,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(Dio()))],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => UtenButton(
              onPressed: () async {
                final choice = await showBusinessPrecisionDialog(
                  context,
                  _requirement,
                  validity: validity,
                  expectedValidity: 0,
                );
                onResult?.call(choice);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
