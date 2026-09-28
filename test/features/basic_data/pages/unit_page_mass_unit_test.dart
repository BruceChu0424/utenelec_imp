// 基本单位「等于哪种重量单位」(V743/ADR-135)：
// - 模型：massUnitCode 随列表/详情解析；「重量单位」展示文字与服务端导出同口径。
// - 页面：列表多一列「重量单位」；详情只在重量维度时列出；编辑弹窗里下拉只在计量维度
//   选「重量」时出现，改离「重量」即隐藏，提交时不再带旧的重量单位。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  group('unit model', () {
    test('massUnitCode 随列表与详情解析', () {
      final item = UnitListItem.fromJson(const {
        'id': 'u-kg',
        'name': 'kg',
        'measurementDimension': 'MASS',
        'massUnitCode': 'KG',
      });
      final detail = UnitDetail.fromJson(const {
        'id': 'u-jin',
        'name': '斤',
        'measurementDimension': 'MASS',
        'massUnitCode': 'JIN',
      });
      expect(item.massUnitCode, 'KG');
      expect(detail.massUnitCode, 'JIN');
      expect(UnitListItem.fromJson(const {'id': 'u-1'}).massUnitCode, isNull);
    });

    test('重量单位展示文字：非重量维度留空，重量维度没选写未指定', () {
      expect(kUnitMassUnitCodes.keys, ['G', 'KG', 'T', 'JIN', 'LB', 'OZ']);
      expect(kUnitMassUnitCodes.values, ['克', '千克', '吨', '斤', '磅', '盎司']);
      expect(unitMassUnitLabel('MASS', 'KG'), '千克');
      expect(unitMassUnitLabel('MASS', 'OZ'), '盎司');
      expect(unitMassUnitLabel('MASS', null), '未指定');
      expect(unitMassUnitLabel('COUNT', 'KG'), '');
      expect(unitMassUnitLabel(null, null), '');
    });
  });

  group('unit page', () {
    testWidgets('列表带「重量单位」列，与服务端导出同口径', (tester) async {
      final units = _FakeUnitRepository(
        detailPayload: const UnitDetail(id: 'u-kg', name: 'kg'),
      );
      await _pumpPage(tester, units);

      final table = tester.widget<MasterDataTableView<UnitListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<UnitListItem>,
        ),
      );
      final column = table.columns.singleWhere((c) => c.key == 'massUnit');
      expect(column.label, '重量单位');
      expect(
        column.value(
          const UnitListItem(
            id: 'u-kg',
            measurementDimension: 'MASS',
            massUnitCode: 'KG',
          ),
        ),
        '千克',
      );
      expect(
        column.value(
          const UnitListItem(id: 'u-box', measurementDimension: 'COUNT'),
        ),
        '',
      );
    });

    testWidgets('重量改成数量：重量单位下拉隐藏，提交不再带旧的重量单位', (tester) async {
      final units = _FakeUnitRepository(
        detailPayload: const UnitDetail(
          id: 'u-kg',
          code: 'DW000017',
          name: 'kg',
          status: '使用',
          measurementDimension: 'MASS',
          massUnitCode: 'KG',
        ),
      );
      await _pumpPage(tester, units);
      await _openEdit(tester);

      expect(_dropdown('等于哪种重量单位'), findsOneWidget);
      expect(
        tester.widget<UtenDropdownField>(_dropdown('等于哪种重量单位')).value,
        'KG',
      );

      await _choose(tester, '计量维度', '数量');
      expect(_dropdown('等于哪种重量单位'), findsNothing);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(units.lastUpdateId, 'u-kg');
      expect(units.lastUpdateBody?[kUnitDimensionField], 'COUNT');
      expect(units.lastUpdateBody?.containsKey(kUnitMassUnitField), isTrue);
      expect(units.lastUpdateBody?[kUnitMassUnitField], isNull);
    });

    testWidgets('选「重量」后出现下拉，可选斤并随保存提交', (tester) async {
      final units = _FakeUnitRepository(
        detailPayload: const UnitDetail(
          id: 'u-jin',
          code: 'DW000019',
          name: '斤',
          status: '使用',
          measurementDimension: 'COUNT',
        ),
      );
      await _pumpPage(tester, units);
      await _openEdit(tester);

      expect(_dropdown('等于哪种重量单位'), findsNothing);
      await _choose(tester, '计量维度', '重量');
      expect(_dropdown('等于哪种重量单位'), findsOneWidget);
      await _choose(tester, '等于哪种重量单位', '斤');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(units.lastUpdateBody?[kUnitDimensionField], 'MASS');
      expect(units.lastUpdateBody?[kUnitMassUnitField], 'JIN');
    });

    testWidgets('详情只在重量维度时列出「等于哪种重量单位」', (tester) async {
      final units = _FakeUnitRepository(
        detailPayload: const UnitDetail(
          id: 'u-g',
          code: 'DW000018',
          name: 'g',
          status: '使用',
          measurementDimension: 'MASS',
          massUnitCode: 'G',
        ),
      );
      await _pumpPage(tester, units);
      await _openDetail(tester);

      expect(find.text('等于哪种重量单位'), findsOneWidget);
      expect(find.text('克'), findsWidgets);
    });

    testWidgets('非重量维度的详情不列重量单位', (tester) async {
      final units = _FakeUnitRepository(
        detailPayload: const UnitDetail(
          id: 'u-box',
          code: 'DW000020',
          name: '箱',
          status: '使用',
          measurementDimension: 'COUNT',
        ),
      );
      await _pumpPage(tester, units);
      await _openDetail(tester);

      expect(find.text('计量维度'), findsWidgets);
      expect(find.text('等于哪种重量单位'), findsNothing);
    });
  });
}

Finder _dropdown(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

/// 点开指定下拉，选中浮层里的选项（浮层在树的末尾，取最后一个同名文字）。
Future<void> _choose(WidgetTester tester, String label, String option) async {
  await tester.tap(_dropdown(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

/// 点列表行 → 详情面板。
Future<void> _openDetail(WidgetTester tester) async {
  final table = tester.widget<MasterDataTableView<UnitListItem>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<UnitListItem>,
    ),
  );
  table.onRowTap!(table.items.single);
  await tester.pumpAndSettle();
}

/// 点列表行 → 详情面板 → 编辑。
Future<void> _openEdit(WidgetTester tester) async {
  await _openDetail(tester);
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(WidgetTester tester, _FakeUnitRepository units) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        unitRepositoryProvider.overrideWithValue(units),
        currentPermissionsProvider.overrideWithValue(<String>{
          Perm.unitView,
          Perm.unitEdit,
          Perm.unitStatus,
        }),
      ],
      child: const MaterialApp(
        home: UnitPage(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeUnitRepository implements UnitRepository {
  _FakeUnitRepository({required this.detailPayload});

  final UnitDetail detailPayload;
  String? lastUpdateId;
  Map<String, dynamic>? lastUpdateBody;

  @override
  Future<PagedResult<UnitListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async => PagedResult(
    items: [
      UnitListItem(
        id: detailPayload.id,
        code: detailPayload.code,
        name: detailPayload.name,
        status: detailPayload.status,
        measurementDimension: detailPayload.measurementDimension,
        massUnitCode: detailPayload.massUnitCode,
      ),
    ],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<UnitFacets> facets() async =>
      const UnitFacets(fields: {}, nullCounts: {});

  @override
  Future<UnitDetail> detail(String id) async => detailPayload;

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    lastUpdateId = id;
    lastUpdateBody = Map<String, dynamic>.of(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
