import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/shared/widgets/business_precision_dialog.dart';

const _required = BusinessPrecisionRequirement(
  key: 'synthetic-test-ratio',
  groupKey: 'synthetic-test-ratio',
  label: '本次原报表比率',
  maxScale: 30,
  reason: 'NON_TERMINATING',
);

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _mount(
  WidgetTester tester,
  Future<void> Function(BuildContext) action,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () => unawaited(action(context)),
              child: const Text('执行原动作'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('执行原动作'));
  await _frames(tester);
}

Future<void> _pickDown(WidgetTester tester) async {
  final input = find.byWidgetPredicate(
    (w) => w is UtenInput && w.label == '保留小数位数',
  );
  await tester.enterText(
    find.descendant(of: input, matching: find.byType(TextField)),
    '3',
  );
  await tester.tap(find.text('处理方式'));
  await _frames(tester);
  await tester.tap(find.text('直接截取，不进位').last);
  await _frames(tester);
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);
  tearDown(UtenBusyOverlay.debugResetYield);

  testWidgets(
    'pending run yields to the real precision dialog, nested work stays visible, then original resumes',
    (tester) async {
      final continuation = Completer<void>();
      BusinessPrecisionChoice? selected;
      var finished = false;
      await _mount(tester, (context) async {
        await UtenBusyOverlay.run(
          context,
          title: '原请求执行中',
          action: () async {
            selected = await showBusinessPrecisionDialog(context, _required);
            await continuation.future;
          },
        );
        finished = true;
      });
      expect(find.byType(BusinessPrecisionDialog), findsOneWidget);
      expect(find.text('原请求执行中'), findsNothing);
      final nested = Completer<void>();
      final nestedTask = UtenBusyOverlay.run(
        tester.element(find.byType(BusinessPrecisionDialog)),
        title: '弹窗内的新核对',
        action: () => nested.future,
      );
      await _frames(tester);
      expect(find.text('弹窗内的新核对'), findsOneWidget);
      expect(find.text('原请求执行中'), findsNothing);
      nested.complete();
      await _frames(tester);
      await nestedTask;
      await _pickDown(tester);
      await tester.tap(find.text('确认本次精度'));
      await _frames(tester);
      expect(selected?.scale, 3);
      expect(selected?.rounding, 'DOWN');
      expect(find.text('原请求执行中'), findsOneWidget);
      expect(finished, isFalse);
      continuation.complete();
      await tester.pumpAndSettle();
      expect(finished, isTrue);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real precision cancellation stays reachable and never dispatches a continuation',
    (tester) async {
      var writes = 0, finished = false;
      await _mount(tester, (context) async {
        await UtenBusyOverlay.run(
          context,
          title: '待确认的原动作',
          action: () async {
            final selected = await showBusinessPrecisionDialog(
              context,
              _required,
            );
            if (selected != null) writes++;
          },
        );
        finished = true;
      });
      expect(find.text('待确认的原动作'), findsNothing);
      await tester.tap(find.text('取消，保留原输入'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(finished, isTrue);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope ABA invalidates a prior visible choice and never publishes a late selection',
    (tester) async {
      final validity = ValueNotifier(1);
      addTearDown(validity.dispose);
      var writes = 0;
      await _mount(tester, (context) async {
        await UtenBusyOverlay.run(
          context,
          title: '原身份请求',
          action: () async {
            final selected = await showBusinessPrecisionDialog(
              context,
              _required,
              validity: validity,
              expectedValidity: 1,
            );
            if (selected != null) writes++;
          },
        );
      });
      await _pickDown(tester);
      validity.value = 2;
      await _frames(tester);
      validity.value = 1;
      await _frames(tester);
      final confirm = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '确认本次精度'),
      );
      expect(confirm.onPressed, isNull);
      await tester.tap(find.text('取消，保留原输入'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
