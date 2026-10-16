import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_overview.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('车间总览多词跨可见字段，车间名称优先且同分稳定，状态权限不变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const settings = [
      WmSetting(
        workshopDepartmentId: 'warehouse-exact',
        workshopName: '其他车间',
        status: WmBinStatus.open,
        binWarehouseId: 'bin-a',
        binWarehouseName: '注塑',
        sourceWarehouseName: '原料仓',
      ),
      WmSetting(
        workshopDepartmentId: 'near-first',
        workshopName: '注塑一车间',
        status: WmBinStatus.open,
        binWarehouseId: 'bin-b',
        binWarehouseName: '内料仓B',
        sourceWarehouseName: '原料仓',
      ),
      WmSetting(
        workshopDepartmentId: 'near-second',
        workshopName: '注塑二车间',
        status: WmBinStatus.notOpen,
        sourceWarehouseName: '原料仓',
      ),
      WmSetting(
        workshopDepartmentId: 'name-exact',
        workshopName: '注塑',
        status: WmBinStatus.open,
        binWarehouseId: 'bin-c',
        binWarehouseName: '内料仓C',
        sourceWarehouseName: '原料仓',
      ),
      WmSetting(
        workshopDepartmentId: 'literal',
        workshopName: '注塑10%_车间',
        status: WmBinStatus.open,
        binWarehouseId: 'bin-d',
        sourceWarehouseName: '成品仓',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WorkshopMaterialOverview(
              settings: settings,
              canViewStock: true,
              canSetup: false,
              onOpen: (_) {},
              onChanged: () async {},
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<WmSetting> table() =>
        tester.widget(find.byKey(const Key('wm-overview-table')));
    List<String> ids() =>
        table().items.map((s) => s.workshopDepartmentId).toList();
    Future<void> search(String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    expect(table().selectable, isFalse);
    await search('注塑');
    expect(ids(), [
      'name-exact',
      'near-first',
      'near-second',
      'literal',
      'warehouse-exact',
    ]);
    await search('原料仓\t注塑');
    expect(ids(), ['warehouse-exact', 'near-first', 'name-exact']);
    final toolbar = tester.widget<UtenFilterToolbar<String>>(
      find.byType(UtenFilterToolbar<String>),
    );
    toolbar.onSelectionChanged!(WmBinStatus.notOpen);
    await tester.pumpAndSettle();
    expect(ids(), isEmpty); // unopened source warehouse is not visible
    toolbar.onSelectionChanged!('all');
    await tester.pumpAndSettle();
    await search('10%_');
    expect(ids(), ['literal']);
    await search('');
    expect(ids(), settings.map((s) => s.workshopDepartmentId));
    expect(table().selectable, isFalse);
    expect(tester.takeException(), isNull);
  });
}
