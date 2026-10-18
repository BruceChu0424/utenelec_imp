import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    List<LocationPickResult<String>?> results, {
    LocationPickResult<String>? initialSelection,
    bool showRootOption = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await showUtenPickerSheet<String>(
                  context: context,
                  title: '选择父级',
                  rootLabel: '顶级',
                  initialSelection: initialSelection,
                  showRootOption: showRootOption,
                  cancelLabel: '放弃',
                  confirmLabel: '应用',
                  childBuilder: (_, pending, select, selectRoot) => Column(
                    children: [
                      Text(pending?.node ?? '无父级', key: const Key('pending')),
                      TextButton(
                        onPressed: () => select('新父级'),
                        child: const Text('选择新父级'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('打开位置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开位置'));
    await tester.pumpAndSettle();
  }

  testWidgets('位置选择共用确认栏，初值和改选只有应用后返回', (tester) async {
    final results = <LocationPickResult<String>?>[];
    await open(tester, results, initialSelection: (node: '原父级', isRoot: false));
    expect(find.byType(UtenPickerConfirmBar), findsOneWidget);
    expect(find.text('原父级'), findsOneWidget);
    await tester.tap(find.text('选择新父级'));
    await tester.pump();
    expect(find.text('新父级'), findsOneWidget);
    expect(results, isEmpty);
    await tester.tap(find.widgetWithText(UtenButton, '放弃'));
    await tester.pumpAndSettle();
    expect(results, [null]);

    await tester.tap(find.text('打开位置'));
    await tester.pumpAndSettle();
    expect(find.text('原父级'), findsOneWidget);
    await tester.tap(find.text('选择新父级'));
    await tester.pump();
    await tester.tap(find.widgetWithText(UtenButton, '应用'));
    await tester.pumpAndSettle();
    expect(results.last, (node: '新父级', isRoot: false));
  });

  testWidgets('禁止顶级时旧顶级初值不能确认，仍可改选有效父级', (tester) async {
    final results = <LocationPickResult<String>?>[];
    await open(
      tester,
      results,
      initialSelection: (node: null, isRoot: true),
      showRootOption: false,
    );
    expect(find.text('顶级'), findsNothing);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '应用'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('选择新父级'));
    await tester.pump();
    expect(results, isEmpty);
    await tester.tap(find.widgetWithText(UtenButton, '应用'));
    await tester.pumpAndSettle();
    expect(results.single, (node: '新父级', isRoot: false));
  });

  for (final dismiss in ['关闭', '遮罩']) {
    testWidgets('位置改选后$dismiss放弃暂存', (tester) async {
      final results = <LocationPickResult<String>?>[];
      await open(tester, results);
      await tester.tap(find.text('选择新父级'));
      await tester.pump();
      if (dismiss == '关闭') {
        await tester.tap(find.byTooltip('放弃'));
      } else {
        await tester.tapAt(const Offset(20, 400));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  }
}
