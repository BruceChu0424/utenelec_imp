import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/master_data_table_rows_controller.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/components/layout/uten_picker_footer_layout.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  testWidgets('confirmation bar in Scaffold leaves the picker body usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var picked = false;
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ListView(
              children: [
                ListTile(
                  title: const Text('可选择记录'),
                  onTap: () => setState(() => picked = true),
                ),
              ],
            ),
            bottomNavigationBar: UtenPickerConfirmBar(
              selectedCount: picked ? 1 : 0,
              onConfirm: () => confirmed = true,
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(UtenPickerConfirmBar)).height,
      lessThan(150),
    );
    expect(find.text('可选择记录').hitTestable(), findsOneWidget);
    await tester.tap(find.text('可选择记录'));
    await tester.pumpAndSettle();
    expect(picked, isTrue);
    expect(confirmed, isFalse);
    await tester.tap(find.text('确定'));
    expect(confirmed, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (width: 960.0, scale: 1.0, platform: TargetPlatform.windows),
    (width: 960.0, scale: 1.5, platform: TargetPlatform.windows),
    (width: 390.0, scale: 1.3, platform: TargetPlatform.android),
  ]) {
    testWidgets(
      'Scaffold picker footer wraps content and leaves body usable: ${scenario.width}/${scenario.scale}',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(scenario.width, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var confirmed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(platform: scenario.platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: const SizedBox.expand(key: Key('picker-body-viewport')),
              bottomNavigationBar: UtenPickerConfirmBar(
                selectedCount: 1,
                selectedLabel: '带有颜色和仓库信息的待确认物料',
                onConfirm: () => confirmed = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final body = tester.getRect(
          find.byKey(const Key('picker-body-viewport')),
        );
        final footer = tester.getRect(find.byType(UtenPickerConfirmBar));
        expect(body.height, greaterThan(350));
        expect(footer.height, lessThan(350));
        expect(body.bottom, closeTo(footer.top, 0.1));
        expect(footer.bottom, closeTo(700, 0.1));
        await tester.tap(find.widgetWithText(UtenButton, '确定'));
        expect(confirmed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short selection summary cannot leave trailing space after actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: UtenPickerConfirmBar(
                selectedCount: 5,
                onClear: () {},
                onConfirm: () {},
                pagination: const SizedBox(width: 280, child: Text('分页')),
              ),
            ),
          ),
        ),
      );
      final confirm = find
          .ancestor(
            of: find.text('确定'),
            matching: find.byWidgetPredicate(
              (widget) => widget is UtenButton || widget is FilledButton,
            ),
          )
          .first;
      expect(tester.getRect(confirm).right, closeTo(944, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all picker actions have visible button shapes and clear is danger',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenPickerConfirmBar(
              selectedCount: 1,
              onClear: () {},
              onConfirm: () {},
            ),
          ),
        ),
      );
      expect(find.widgetWithText(UtenButton, '清空'), findsOneWidget);
      expect(
        tester.widget<UtenButton>(find.widgetWithText(UtenButton, '清空')).type,
        UtenButtonType.danger,
      );
      expect(
        tester.widget<UtenButton>(find.widgetWithText(UtenButton, '取消')).type,
        UtenButtonType.secondary,
      );
      expect(
        tester.widget<UtenButton>(find.widgetWithText(UtenButton, '确定')).type,
        UtenButtonType.primary,
      );
    },
  );

  testWidgets(
    'page field has a full control outline and navigation clamps input',
    (tester) async {
      final controller = MasterDataTableRowsController<int>();
      final requested = <int>[];
      controller.bindPagination(
        Object(),
        () async {},
        false,
        totalPages: 12,
        goToPage: requested.add,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(child: UtenPickerPageControls(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      final outline = find.byKey(const Key('picker-page-input-outline'));
      expect(tester.getSize(outline).height, 28);
      expect(
        tester.getCenter(find.byType(EditableText)).dy,
        closeTo(tester.getCenter(outline).dy, 1),
      );
      expect(
        tester.getCenter(input).dy,
        closeTo(tester.getCenter(find.text('/ 12')).dy, 0.1),
      );
      await tester.enterText(input, '99');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(requested, [12]);
      expect(find.text('12'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch page outline and entered number align with pagination text',
    (tester) async {
      final controller = MasterDataTableRowsController<int>();
      controller.bindPagination(Object(), () async {}, false, totalPages: 2);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(child: UtenPickerPageControls(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final outline = find.byKey(const Key('picker-page-input-outline'));
      expect(tester.getSize(outline).height, 48);
      expect(
        tester.getCenter(outline).dy,
        tester.getCenter(find.text('/ 2')).dy,
      );
      expect(
        tester.getCenter(find.byType(EditableText)).dy,
        closeTo(tester.getCenter(outline).dy, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty selection confirmation remains an explicit caller decision',
    (tester) async {
      var confirmations = 0;
      var allowEmpty = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return UtenPickerConfirmBar(
                  selectedCount: 0,
                  confirmEnabled: allowEmpty,
                  onConfirm: () => confirmations++,
                );
              },
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
            .onPressed,
        isNull,
      );
      rebuild(() => allowEmpty = true);
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      expect(confirmations, 1);
    },
  );

  testWidgets(
    'narrow large-text footer keeps every action in the bottom right',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: UtenPickerConfirmBar(
                selectedCount: 2,
                onClear: () {},
                onConfirm: () {},
                pagination: const Text('第 1 / 12 页'),
              ),
            ),
          ),
        ),
      );
      final confirm = find.widgetWithText(UtenButton, '确定');
      expect(tester.getRect(confirm).right, closeTo(359, 0.1));
      expect(tester.getRect(confirm).bottom, closeTo(796, 0.1));
      expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
      expect(
        find.widgetWithText(UtenButton, '清空').hitTestable(),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(UtenButton, '取消').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'location root remains a valid explicit selection and cancellation discards it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final results = <LocationPickResult<String>?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  results.add(
                    await showUtenPickerSheet<String>(
                      context: context,
                      title: '选择上级',
                      rootLabel: '无父级',
                      childBuilder: (_, pending, select, selectRoot) =>
                          TextButton(
                            onPressed: () => select('parent'),
                            child: const Text('选父级'),
                          ),
                    ),
                  );
                },
                child: const Text('打开位置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开位置'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('无父级'));
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.text('打开位置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('无父级'));
      await tester.pump();
      final confirm = find.widgetWithText(UtenButton, '确定');
      expect(tester.getRect(confirm).right, closeTo(1184, 0.1));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(results.last?.isRoot, isTrue);
      expect(results.last?.node, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
