import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';

typedef _Row = ({String id, String name, String status});

void main() {
  testWidgets(
    'inactive edit previews fit the same full value before activating an input',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = MasterInlineEditController<_Row>();
      addTearDown(controller.dispose);
      const name = '高级灰(CD-19127)';
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => MasterDataTableView<_Row>(
                columns: controller.columns(
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '颜色名称',
                      width: 200,
                      value: (row) => row.name,
                    ),
                  ],
                  idOf: (row) => row.id,
                  fields: {
                    'name': MasterInlineField(
                      key: 'name',
                      read: (row) => row.name,
                    ),
                  },
                ),
                items: const [(id: 'one', name: name, status: '使用')],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(name),
                matching: find.byType(RichText),
              ),
            )
            .didExceedMaxLines,
        isFalse,
      );
      final beforeWidth = tester.getSize(find.text(name)).width;
      controller.begin();
      await tester.pumpAndSettle();
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'The full value must fit before the lazy editor is activated',
      );
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(name),
                matching: find.byType(RichText),
              ),
            )
            .didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('inline-one-name'))).width,
        greaterThanOrEqualTo(beforeWidth + 20),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short edit values fit content and activation keeps shared row height',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Builder(
              builder: (context) => MasterDataTableView<_Row>(
                columns: controller.columns(
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '名称',
                      width: 240,
                      value: (row) => row.name,
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 240,
                      value: (row) => row.status,
                    ),
                  ],
                  idOf: (row) => row.id,
                  fields: {
                    'name': MasterInlineField(
                      key: 'name',
                      read: (row) => row.name,
                    ),
                    'status': MasterInlineField(
                      key: 'status',
                      read: (row) => row.status,
                      type: MasterFieldType.select,
                      options: kMasterStatusOptions,
                    ),
                  },
                ),
                items: const [(id: 'one', name: '短名', status: '使用')],
                selectable: true,
                idOf: (row) => row.id,
                rowWidgetKeyOf: (_) => const ValueKey('compact-row'),
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nameCell = find.byKey(const ValueKey('inline-one-name'));
      final beforeWidth = tester.getSize(nameCell).width;
      final rowHeight = tester
          .getSize(find.byKey(const ValueKey('compact-row')))
          .height;
      expect(
        beforeWidth,
        lessThan(140),
        reason: 'Short fields must not inherit the old 140px editor minimum',
      );
      await tester.tap(find.byKey(const ValueKey('inline-activate-one-name')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('compact-row'))).height,
        closeTo(rowHeight, .01),
      );
      expect(tester.getSize(find.byType(TextField)).height, closeTo(32, .01));
      expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 1);
      final decorator = find.descendant(
        of: find.byType(TextField),
        matching: find.byType(InputDecorator),
      );
      expect(
        tester
            .widget<InputDecorator>(decorator)
            .decoration
            .floatingLabelBehavior,
        FloatingLabelBehavior.never,
      );
      await tester.tap(
        find.byKey(const ValueKey('inline-activate-one-status')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(UtenDropdownField)).height,
        closeTo(32, .01),
      );
      await tester.enterText(find.byType(TextField), '按实际输入内容自动增长的名称，始终只占一行');
      await tester.pumpAndSettle();
      expect(tester.getSize(nameCell).width, greaterThan(beforeWidth));
      expect(
        tester.getSize(find.byKey(const ValueKey('compact-row'))).height,
        closeTo(rowHeight, .01),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
