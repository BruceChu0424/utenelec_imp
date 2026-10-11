import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/widgets/daily_report_add_destination_dialog.dart';

const Key _targetKey = ValueKey('daily-add-destination-target');
const _first = 'HP001 · 同名产品完整名称与第一道装配工序';
const _second = 'HP002 · 同名产品完整名称与第二道装配工序';
const _blocked = 'HP003 · 本行已分给它';
const _targets = [
  UtenDropdownItem(value: 'first-demand', label: _first),
  UtenDropdownItem(value: 'second-demand', label: _second),
  UtenDropdownItem(value: 'blocked-demand', label: _blocked, enabled: false),
];

Finder get _quantity =>
    find.byKey(const ValueKey('daily-add-destination-quantity'));
Finder get _add => find.byKey(const ValueKey('daily-add-destination-confirm'));
Finder get _dialog =>
    find.byKey(const ValueKey('daily-add-destination-dialog'));

String? _quantityError(WidgetTester tester) {
  final field = tester.widget<TextField>(_quantity);
  final decoration = field.decoration! as UtenInputDecoration;
  return (decoration.base.error as UtenFieldMessage?)?.message;
}

Future<void> _open(
  WidgetTester tester, {
  List<UtenDropdownItem> targets = _targets,
  Map<String, String> maximumByDemand = const {
    'first-demand': '10',
    'second-demand': '10',
  },
  String availableQtyText = '10',
  String unitRateText = '1',
  bool replacesSuggestions = false,
  void Function(DailyReportDestinationChoice?)? onResult,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await DailyReportAddDestinationDialog.show(
                context,
                targets: targets,
                maximumByDemand: maximumByDemand,
                availableQtyText: availableQtyText,
                unitRateText: unitRateText,
                unitName: '个',
                replacesSuggestions: replacesSuggestions,
              );
              onResult?.call(result);
            },
            child: const Text('打开添加去向'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开添加去向'));
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String value) async {
  await tester.tap(find.byKey(_targetKey));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(
      ValueKey<(String, Key?, String?)>((
        'uten-dropdown-option',
        _targetKey,
        value,
      )),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'new local choice starts empty and cancellation returns no facts',
    (tester) async {
      final results = <DailyReportDestinationChoice?>[];
      await _open(tester, replacesSuggestions: true, onResult: results.add);
      expect(tester.widget<TextField>(_quantity).controller!.text, isEmpty);
      expect(
        tester.widget<UtenDropdownField>(find.byKey(_targetKey)).value,
        isNull,
      );
      expect(find.textContaining('取消会保留原页面分配'), findsOneWidget);
      expect(tester.widget<TextField>(_quantity).decoration!.suffixText, '个');
      await tester.tap(
        find.byKey(const ValueKey('daily-add-destination-cancel')),
      );
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(_dialog, findsNothing);
    },
  );

  testWidgets('full searchable labels retain different work-order identities', (
    tester,
  ) async {
    DailyReportDestinationChoice? chosen;
    await _open(tester, onResult: (value) => chosen = value);
    await tester.tap(find.byKey(_targetKey));
    await tester.pumpAndSettle();
    expect(find.text(_first), findsOneWidget);
    expect(find.text(_second), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '输入关键字搜索'), 'HP002');
    await tester.pump();
    expect(find.text(_first), findsNothing);
    await tester.tap(
      find.byKey(
        const ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          _targetKey,
          'second-demand',
        )),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(_quantity, '.5');
    await tester.tap(_add);
    await tester.pumpAndSettle();
    expect(chosen?.demandId, 'second-demand');
    expect(chosen?.qtyText, '0.5');
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate disabled targets never become a committed choice', (
    tester,
  ) async {
    final results = <DailyReportDestinationChoice?>[];
    await _open(tester, onResult: results.add);
    await _select(tester, 'blocked-demand');
    expect(
      tester.widget<UtenDropdownField>(find.byKey(_targetKey)).value,
      isNull,
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // Selecting a disabled first search result by keyboard must also be rejected
    // by this local choice guard, independently of the shared menu's behavior.
    final dropdown = tester.widget<UtenDropdownField>(find.byKey(_targetKey));
    dropdown.onChanged('blocked-demand');
    await tester.pump();
    await tester.enterText(_quantity, '1');
    await tester.tap(_add);
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(_dialog, findsOneWidget);
    expect(
      tester.widget<UtenDropdownField>(find.byKey(_targetKey)).errorMessage,
      contains('当前可接收'),
    );
    expect(tester.widget<TextField>(_quantity).controller!.text, '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty invalid and excessive quantities stay open and keep input',
    (tester) async {
      final results = <DailyReportDestinationChoice?>[];
      await _open(
        tester,
        availableQtyText: '5',
        maximumByDemand: const {'first-demand': '4'},
        onResult: results.add,
      );
      await _select(tester, 'first-demand');
      for (final input in ['', '.', '0', '-1', '1.23456', '6', '4.0001']) {
        await tester.enterText(_quantity, input);
        await tester.tap(_add);
        await tester.pumpAndSettle();
        expect(results, isEmpty, reason: input);
        expect(_dialog, findsOneWidget);
        expect(tester.widget<TextField>(_quantity).controller!.text, input);
        expect(_quantityError(tester), isNotNull);
      }
      expect(_quantityError(tester), contains('最多可接收的 4'));
      await tester.enterText(_quantity, '4');
      await tester.tap(_add);
      await tester.pumpAndSettle();
      expect(results.single?.qtyText, '4');
    },
  );

  for (final sample in [
    ('0.0001', '0.4', '换算后的基本量为 0'),
    ('100000000000000', '1', '去向数量超过系统计量范围'),
    ('10000000000000', '10', '换算后的基本量超过系统计量范围'),
    ('1', '1000000000000', '来源单位换算率尚未核对'),
  ]) {
    testWidgets(
      'physical/storage guard retains input ${sample.$1} × ${sample.$2}',
      (tester) async {
        final results = <DailyReportDestinationChoice?>[];
        await _open(
          tester,
          availableQtyText: '99999999999999.9999',
          maximumByDemand: const {'first-demand': '99999999999999.9999'},
          unitRateText: sample.$2,
          onResult: results.add,
        );
        await _select(tester, 'first-demand');
        await tester.enterText(_quantity, sample.$1);
        await tester.tap(_add);
        await tester.pumpAndSettle();
        expect(results, isEmpty);
        expect(_quantityError(tester), contains(sample.$3));
        expect(tester.widget<TextField>(_quantity).controller!.text, sample.$1);
      },
    );
  }

  for (final sample in [('0.0001', '.5'), ('99999999999999.9999', '1')]) {
    testWidgets(
      'exact physical boundary commits unchanged ${sample.$1} × ${sample.$2}',
      (tester) async {
        DailyReportDestinationChoice? chosen;
        await _open(
          tester,
          availableQtyText: '99999999999999.9999',
          maximumByDemand: const {'first-demand': '99999999999999.9999'},
          unitRateText: sample.$2,
          onResult: (value) => chosen = value,
        );
        await _select(tester, 'first-demand');
        await tester.enterText(_quantity, sample.$1);
        await tester.tap(_add);
        await tester.pumpAndSettle();
        expect(chosen?.qtyText, sample.$1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'caller mutation cannot replace the captured target or quantity cap',
    (tester) async {
      final targets = List<UtenDropdownItem>.of(_targets);
      final caps = {'first-demand': '4'};
      final results = <DailyReportDestinationChoice?>[];
      await _open(
        tester,
        targets: targets,
        maximumByDemand: caps,
        onResult: results.add,
      );
      targets.clear();
      caps['first-demand'] = '10';
      await _select(tester, 'first-demand');
      await tester.enterText(_quantity, '5');
      await tester.tap(_add);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(_quantityError(tester), contains('最多可接收的 4'));
      await tester.enterText(_quantity, '4');
      await tester.tap(_add);
      await tester.pumpAndSettle();
      expect(results.single?.demandId, 'first-demand');
      expect(results.single?.qtyText, '4');
    },
  );

  testWidgets(
    'unknown snapshot cap cannot authorize an otherwise valid quantity',
    (tester) async {
      final results = <DailyReportDestinationChoice?>[];
      await _open(tester, maximumByDemand: const {}, onResult: results.add);
      await _select(tester, 'first-demand');
      await tester.enterText(_quantity, '1');
      await tester.tap(_add);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(_quantityError(tester), contains('可接收数量尚未核对'));
    },
  );

  testWidgets('narrow viewport remains scrollable with cancel available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 440));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final results = <DailyReportDestinationChoice?>[];
    await _open(
      tester,
      textScale: 1.4,
      replacesSuggestions: true,
      onResult: results.add,
    );
    expect(_dialog, findsOneWidget);
    expect(MediaQuery.textScalerOf(tester.element(_dialog)).scale(10), 14);
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('daily-add-destination-cancel')),
    );
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
