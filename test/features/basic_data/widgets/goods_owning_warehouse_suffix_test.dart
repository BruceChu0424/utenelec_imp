import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_suffix_icons.dart';
import 'package:uten_imp/components/inputs/uten_picker_icon_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Warehouses extends MasterNameService {
  _Warehouses() : super(ApiClient(Dio()));

  int loads = 0;
  Completer<void>? gate;

  @override
  Future<void> ensureWarehousesLoaded() async {
    loads++;
    await gate?.future;
  }

  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
    WarehouseDictEntry(
      id: 'finished',
      name: '成品仓',
      parentId: 'main',
      status: '使用',
      selectableForNew: true,
    ),
  ];
}

void main() {
  testWidgets('所属仓库紧凑图标组保留加载禁用、选择UUID与清除行为', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final names = _Warehouses();
    addTearDown(names.dispose);
    addTearDown(() {
      final pending = names.gate;
      if (pending != null && !pending.isCompleted) pending.complete();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {Perm.goodsEdit}),
          isSuperAdminProvider.overrideWithValue(false),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith(
            (ref) async => const [UnitListItem(id: 'piece', name: '个')],
          ),
          masterNameServiceProvider.overrideWithValue(names),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GoodsDetailBody(
              initialDetail: GoodsDetail(
                id: 'goods-suffix',
                name: '货品',
                status: '使用',
                sourceType: '自制',
                unitId: 'piece',
                unitName: '个',
                writable: true,
                owningWarehouseId: 'finished',
                owningWarehouseName: '旧仓库显示名',
              ),
              initialCategoryId: 'category-1',
              canCreate: false,
              canEdit: true,
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
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('goods-owning-warehouse'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    Finder action(String tooltip) => find.descendant(
      of: field,
      matching: find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      ),
    );
    final clear = action('清除');
    final picker = action('选择仓库');
    final customPicker = find.descendant(
      of: field,
      matching: find.byType(UtenPickerIconButton),
    );
    expect(
      find.ancestor(
        of: customPicker,
        matching: find.byType(UtenFieldSuffixIcon),
      ),
      findsWidgets,
    );
    expect(tester.getSize(clear).width, closeTo(32, .01));
    expect(tester.getSize(picker).width, closeTo(32, .01));
    expect(
      (tester.getCenter(clear).dy - tester.getCenter(picker).dy).abs(),
      lessThan(.01),
    );
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, '旧仓库显示名');
    expect(names.loads, 0);

    final gate = names.gate = Completer<void>();
    await tester.tap(picker);
    await tester.pump(const Duration(milliseconds: 100));
    expect(names.loads, 1);
    expect(tester.widget<IconButton>(clear).onPressed, isNull);
    expect(tester.widget<IconButton>(picker).onPressed, isNull);
    expect(tester.widget<UtenPickerIconButton>(customPicker).isLoading, isTrue);
    expect(tester.widget<TextField>(field).onTap, isNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('选择所属仓库'), findsOneWidget);
    final child = find.byKey(const Key('warehouse-picker-entry-finished'));
    if (child.evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
      await tester.pumpAndSettle();
    }
    await tester.tap(child);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '主仓-成品仓');
    final form = tester.state<MasterEditFormState>(find.byType(MasterEditForm));
    final selectedBody = form.buildBody();
    expect(
      selectedBody,
      isNotNull,
      reason: '${form.controller.errorFieldKey}: ${form.controller.error}',
    );
    expect(selectedBody!['owningWarehouseId'], 'finished');
    expect(tester.widget<IconButton>(clear).onPressed, isNotNull);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(form.buildBody()!['owningWarehouseId'], isNull);
    expect(clear, findsNothing);
    expect(picker, findsOneWidget);
    expect(names.loads, 1);
    expect(find.text('选择所属仓库'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
