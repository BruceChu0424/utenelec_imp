import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/number_unit_field.dart';
import 'package:uten_imp/features/basic_data/widgets/packaging_picker_field.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../support/audit_screenshot_support.dart';

void main() {
  testWidgets('主档空只读文本和选择字段保留框内字段名及格式说明', (tester) async {
    await _pumpForm(
      tester,
      width: 800,
      fields: const [
        MasterFieldDef(
          key: 'lockedCode',
          label: '系统编号',
          readOnly: true,
          hint: '由系统生成',
        ),
        MasterFieldDef(
          key: 'color',
          label: '颜色',
          readOnly: true,
          type: MasterFieldType.select,
          options: [MasterSelectOption(value: 'white', label: '白色')],
        ),
      ],
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.map((field) => field.enabled), everyElement(isFalse));
    expect(fields.map((field) => field.decoration!.hintText), ['系统编号', '颜色']);
    expect(find.byTooltip('由系统生成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('货品普通文本、选择器及数字单位框使用相同高度和字段列宽', (tester) async {
    await _pumpForm(
      tester,
      fields: [
        const MasterFieldDef(key: 'name', label: '货品名称', group: '基础'),
        const MasterFieldDef(
          key: 'source',
          label: '来源',
          type: MasterFieldType.select,
          group: '基础',
          options: [MasterSelectOption(value: 'buy', label: '采购')],
        ),
        MasterFieldDef(
          key: 'pack',
          label: '包装',
          type: MasterFieldType.custom,
          group: '基础',
          customBuilder: (field) => PackagingPickerField(
            initialValue: field.initialValue,
            onChanged: field.onChanged,
            onPick: () async => null,
          ),
        ),
        MasterFieldDef(
          key: 'thickness',
          label: '厚度',
          type: MasterFieldType.custom,
          group: '规格',
          customBuilder: (field) => NumberUnitField(
            label: '厚度',
            numberKey: 'thickness',
            unitKey: 'thicknessUnitId',
            unitValueAsString: true,
            unitOptions: const [MasterSelectOption(value: 'mm', label: '毫米')],
            onChanged: field.onChanged,
          ),
        ),
      ],
      width: 1200,
    );

    final decorators = find.byType(InputDecorator);
    expect(decorators, findsNWidgets(5));
    for (final decorator in decorators.evaluate()) {
      expect((decorator.renderObject! as RenderBox).size.height, 44);
    }
    final ordinaryWidth = tester.getSize(find.byType(TextField).first).width;
    expect(
      tester.getSize(find.byType(PackagingPickerField)).width,
      ordinaryWidth,
    );
    expect(tester.getSize(find.byType(NumberUnitField)).width, ordinaryWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档网格计入列间距，窄容器不把普通字段挤到最小列宽以下', (tester) async {
    await _pumpForm(tester, fields: _plainFields, width: 552);
    final first = tester.getRect(find.byType(TextField).at(0));
    final second = tester.getRect(find.byType(TextField).at(1));
    expect(first.width, 520);
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档网格在系统文字放大后减少列数且保留输入值', (tester) async {
    await _pumpForm(tester, fields: _plainFields, width: 800);
    await tester.enterText(find.byType(TextField).first, '已填写的货品名称');
    await _pumpForm(tester, fields: _plainFields, width: 800, textScale: 2);
    final first = tester.getRect(find.byType(TextField).at(0));
    final second = tester.getRect(find.byType(TextField).at(1));
    expect(first.width, 768);
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(find.text('已填写的货品名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('UTEN_CAPTURE_FORM_CONTROLS')) {
    for (final mobile in [false, true]) {
      testWidgets('capture real goods form ${mobile ? 'mobile' : 'light'}', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(
          mobile ? const Size(390, 1050) : const Size(1440, 1050),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentPermissionsProvider.overrideWithValue({
                Perm.goodsPriceView,
                Perm.goodsPriceEdit,
                Perm.goodsDiscountView,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              colorDictProvider.overrideWith((ref) async => const []),
              unitDictProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: auditScreenshotTheme(
                buildLightTheme().copyWith(
                  platform: mobile
                      ? TargetPlatform.android
                      : TargetPlatform.windows,
                ),
              ),
              home: RepaintBoundary(
                key: boundary,
                child: const UtenControlTheme(
                  child: Scaffold(
                    body: GoodsDetailBody(
                      initialDetail: GoodsDetail(
                        id: 'preview-goods',
                        name: '测试产品',
                        code: 'V50041',
                        status: '使用',
                        sourceType: '自制',
                        writable: true,
                      ),
                      initialCategoryId: null,
                      canCreate: true,
                      canEdit: true,
                      canStatus: true,
                      canBomCreate: false,
                      canBomEdit: false,
                      canBomDelete: false,
                      onToggleStatus: null,
                      onDelete: null,
                      onDataChanged: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          boundary,
          mobile ? 'form-mobile' : 'form-light',
        );
      });
    }
  }
}

const _plainFields = [
  MasterFieldDef(key: 'name', label: '货品名称', group: '基础'),
  MasterFieldDef(key: 'code', label: '编号', group: '基础'),
];

Future<void> _pumpForm(
  WidgetTester tester, {
  required List<MasterFieldDef> fields,
  required double width,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: MediaQuery(
              data: MediaQueryData(
                size: const Size(1200, 900),
                textScaler: TextScaler.linear(textScale),
              ),
              child: UtenControlTheme(child: MasterEditForm(fields: fields)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
