import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/utils/currency_display.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_field_edit_policy.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/providers/currency_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_currency_field.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/widgets/currency_text.dart';

const _currencies = [
  CurrencyListItem(id: 'cny', name: '人民币', code: '001'),
  CurrencyListItem(id: 'usd', name: '美元', code: '002'),
  CurrencyListItem(id: 'hkd', name: '港币', code: '003'),
];
const _detail = GoodsDetail(
  id: 'goods',
  name: '测试货品',
  sourceType: '自制',
  unitId: 'unit',
  status: '使用',
  writable: true,
  price: 12.34,
  priceDisplayText: '12.34000000001',
  currencyId: 'cny',
  currencyName: '人民币',
  currencyCode: '001',
);

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    if (Platform.environment['UTEN_CURRENCY_CAPTURE'] == '1') {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Dart and C# consume the same currency identity and color-role cases',
    () {
      final fixture =
          jsonDecode(
                File('contracts/currency-display/v1.json').readAsStringSync(),
              )
              as Map;
      for (final raw in fixture['cases'] as List) {
        final row = (raw as Map).cast<String, Object?>();
        expect(
          financeCurrencyDisplayLabel(
            name: row['name'] as String?,
            code: row['code'] as String?,
          ),
          row['label'],
        );
        expect(
          currencyColorRole(
            name: row['name'] as String?,
            code: row['code'] as String?,
          ),
          row['role'],
        );
      }
      expect(GoodsListItem.fromJson({'id': 'old'}).currencyId, isNull);
      expect(GoodsDetail.fromJson({'id': 'old'}).currencyName, isNull);
      expect(
        GoodsFieldEditPolicy.canEditField('currencyId', {Perm.goodsEdit}),
        isFalse,
      );
      expect(
        GoodsFieldEditPolicy.canEditField('currencyId', {Perm.goodsPriceView}),
        isFalse,
      );
      expect(
        GoodsFieldEditPolicy.canEditField('currencyId', {Perm.goodsPriceEdit}),
        isTrue,
      );
    },
  );

  testWidgets(
    'known currencies remain distinct and readable on normal and selected surfaces',
    (tester) async {
      for (final dark in [false, true]) {
        late BuildContext colorContext;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: Builder(
              builder: (context) {
                colorContext = context;
                return const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final colors = [
          for (final code in [
            'CNY',
            'USD',
            'HKD',
            'EUR',
            'JPY',
            'GBP',
            'SGD',
            'AUD',
            'CAD',
            'KRW',
            'RUB',
            'CHF',
          ])
            currencyTextColor(colorContext, code: code),
        ];
        expect(colors.toSet(), hasLength(colors.length));
        for (final color in colors) {
          for (final background
              in dark
                  ? [UtenColors.slate900, UtenColors.tableSelectedRowDark]
                  : [Colors.white, UtenColors.tableSelectedRow]) {
            final a = color.computeLuminance(),
                b = background.computeLuminance();
            expect(
              ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      }
    },
  );

  for (final permissions in [
    {Perm.goodsView},
    {Perm.goodsView, Perm.goodsPriceView},
    {Perm.goodsView, Perm.goodsPriceEdit},
  ]) {
    testWidgets('goods detail currency follows price visibility $permissions', (
      tester,
    ) async {
      await _pumpDetail(tester, permissions);
      final visible =
          permissions.contains(Perm.goodsPriceView) ||
          permissions.contains(Perm.goodsPriceEdit);
      expect(find.text('价格'), visible ? findsOneWidget : findsNothing);
      expect(find.text('币种'), visible ? findsOneWidget : findsNothing);
      expect(find.text('人民币'), visible ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'view-only price currency stays readable and locked during general goods editing',
    (tester) async {
      await _pumpDetail(tester, {Perm.goodsEdit, Perm.goodsPriceView});
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
      expect(form.readOnlyKeys, containsAll(['price', 'currencyId']));
      expect(find.text('人民币'), findsOneWidget);
      expect(find.text('cny'), findsNothing);
      expect(find.byKey(const ValueKey('goods-currency-field')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit currency selection preserves price and submits UUID; clear explicitly submits null',
    (tester) async {
      await _pumpDetail(tester, {Perm.goodsEdit, Perm.goodsPriceEdit});
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('goods-currency-field'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text('美元').last);
      await tester.pumpAndSettle();
      final form = tester.state<MasterEditFormState>(
        find.byType(MasterEditForm),
      );
      final body = form.buildBody();
      expect(body, isNotNull, reason: form.controller.error);
      expect(body!['currencyId'], 'usd');
      expect(form.buildBody()!['price'], '12.34000000001');
      final selectedText = tester.widget<Text>(
        find.descendant(of: field, matching: find.text('美元')).first,
      );
      expect(selectedText.style?.color, UtenColors.currencyUsd);
      await _capture(tester, 'goods-currency-edit-desktop');
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text('不选').last);
      await tester.pumpAndSettle();
      expect(form.buildBody()!.containsKey('currencyId'), isTrue);
      expect(form.buildBody()!['currencyId'], isNull);
      expect(form.buildBody()!['price'], '12.34000000001');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow goods details and edit form retain readable currency at larger text size',
    (tester) async {
      await _pumpDetail(
        tester,
        {Perm.goodsEdit, Perm.goodsPriceEdit},
        size: const Size(390, 900),
        textScale: 1.4,
      );
      await tester.ensureVisible(find.text('人民币'));
      await tester.pumpAndSettle();
      await _capture(tester, 'goods-currency-detail-narrow');
      // This floating action is already visible. ensureVisible would also
      // scroll its horizontal TabBarView to the next business tab.
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('goods-currency-field'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text('港币').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .state<MasterEditFormState>(find.byType(MasterEditForm))
            .controller
            .customValues['currencyId'],
        'hkd',
      );
      await _capture(tester, 'goods-currency-edit-narrow');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'create form includes currency only with price permission and uses the same editor',
    (tester) async {
      for (final canEditPrice in [false, true]) {
        await _pumpDetail(tester, {
          Perm.goodsCreate,
          if (canEditPrice) Perm.goodsPriceEdit,
        }, create: true);
        final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
        expect(
          form.fields.any((field) => field.key == 'currencyId'),
          canEditPrice,
        );
        expect(form.fields.any((field) => field.key == 'price'), canEditPrice);
        if (canEditPrice) {
          final state = tester.state<MasterEditFormState>(
            find.byType(MasterEditForm),
          );
          state.controller.controllers['name']!.text = '新货品';
          state.controller.setSelect('unitId', 'unit');
          state.controller.setSelect('sourceType', '自制');
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('goods-currency-field'));
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
          await tester.tap(find.text('港币').last);
          await tester.pumpAndSettle();
          expect(state.buildBody()!['currencyId'], 'hkd');
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'currency lookup failure retries without losing the selected historical value',
    (tester) async {
      var calls = 0;
      String? value = 'usd';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currencyDictProvider.overrideWith((ref) async {
              if (++calls == 1) throw StateError('lookup failed');
              return _currencies;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => GoodsCurrencyField(
                  value: value,
                  currentName: '美元',
                  currentCode: 'USD',
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新加载币种'));
      await tester.pumpAndSettle();
      expect(find.text('美元'), findsOneWidget);
      expect(value, 'usd');
      expect(calls, 2);
    },
  );

  testWidgets(
    'inactive historical currency remains readable but cannot be selected again',
    (tester) async {
      String? value = 'hkd';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currencyDictProvider.overrideWith(
              (ref) async => const [
                CurrencyListItem(id: 'cny', name: '人民币', status: '使用'),
                CurrencyListItem(id: 'hkd', name: '港币', status: '禁用'),
              ],
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => GoodsCurrencyField(
                  value: value,
                  currentName: '港币',
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('港币'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('goods-currency-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('人民币').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('goods-currency-field')));
      await tester.pumpAndSettle();
      expect(find.text('港币'), findsNothing);
      expect(value, 'cny');
    },
  );
}

Future<void> _pumpDetail(
  WidgetTester tester,
  Set<String> permissions, {
  bool create = false,
  Size size = const Size(1500, 1500),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith(
          (ref) async => const [UnitListItem(id: 'unit', name: '个')],
        ),
        currencyDictProvider.overrideWith((ref) async => _currencies),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('currency-test-surface'),
          child: Scaffold(
            body: GoodsDetailBody(
              initialDetail: create ? null : _detail,
              initialCategoryId: null,
              canCreate: create,
              canEdit: !create,
              canStatus: false,
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
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UTEN_CURRENCY_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('currency-test-surface')),
  );
  await tester.runAsync(() async {
    final screenshot = await boundary.toImage();
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    final destination = File(
      'output/goods-currency-selection-20261103/$name.png',
    );
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(png!.buffer.asUint8List());
    screenshot.dispose();
  });
}
