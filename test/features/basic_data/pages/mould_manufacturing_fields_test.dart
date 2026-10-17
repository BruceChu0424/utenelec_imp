import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/providers/mould_workshop_tree.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('模具旧年月回显，按月份选择后提交 mstatus 和制造商，重开保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Moulds();
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({
            Perm.mouldView,
            Perm.mouldCategoryView,
            Perm.mouldEdit,
            Perm.mouldCreate,
          }),
          mouldCategoryRepositoryProvider.overrideWithValue(_Categories()),
          mouldRepositoryProvider.overrideWithValue(repository),
          mouldWorkshopTreeProvider.overrideWith(
            (ref) async => const MouldWorkshopTree(tree: [], prodDeptId: null),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MouldCategoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史模具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧模具名称'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('旧模具名称'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(UtenMonthField),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '2008年7月',
    );
    await tester.ensureVisible(find.byType(UtenMonthField));
    await tester.tap(find.byTooltip('选择制造年月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9月'));
    await tester.pumpAndSettle();
    final monthInput = find.descendant(
      of: find.byType(UtenMonthField),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(monthInput).controller!.text, '2008-09');
    final manufacturer = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '模具制造商',
    );
    await tester.enterText(manufacturer, '测试制造商');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.saved?['mstatus'], '2008-09');
    expect(repository.saved?['manufacturer'], '测试制造商');
    expect(repository.saved, isNot(contains('mfgMonth')));
    await tester.tap(find.text('旧模具名称'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('旧模具名称'));
    await tester.pumpAndSettle();
    expect(find.text('测试制造商').last, findsOneWidget);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(monthInput).controller!.text, '2008-09');
    expect(tester.widget<TextField>(manufacturer).controller!.text, '测试制造商');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加模具'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(MasterEditForm),
            matching: find.byType(TextField),
          )
          .first,
      '新增模具名称',
    );
    await tester.ensureVisible(find.byType(UtenMonthField));
    await tester.enterText(monthInput, '1999年12月');
    await tester.enterText(manufacturer, '新增制造商');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.created?['name'], '新增模具名称');
    expect(repository.created?['mstatus'], '1999-12');
    expect(repository.created?['manufacturer'], '新增制造商');
    expect(repository.created, isNot(contains('mfgMonth')));
    expect(tester.takeException(), isNull);
  });

  test('旧版 mfgMonth 草稿恢复到正式 mstatus 字段', () {
    final controller = MasterEditFormController(
      fields: [
        MasterFieldDef(
          key: 'mstatus',
          label: '制造年月',
          type: MasterFieldType.custom,
          legacyDraftKeys: const ['mfgMonth'],
          customBuilder: (_) => const SizedBox(),
        ),
      ],
    );
    addTearDown(controller.dispose);
    controller.restoreDraft({
      'custom': {'mfgMonth': '2008-09'},
    });
    expect(controller.buildBody(), {'mstatus': '2008-09'});
    controller.setCustom('mstatus', '2009-03');
    expect(controller.recoveredCustomInitialValue('mstatus'), '2009-03');
  });
}

class _Categories implements MouldCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'cat',
      code: 'MF1',
      name: '历史模具',
      level: 0,
      children: const [],
    ),
  ];
  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      const ProductCategoryDetail(
        id: 'cat',
        code: 'MF1',
        name: '历史模具',
        level: 0,
        path: '/MF1/',
        childCount: 0,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Moulds implements MouldRepository {
  Map<String, dynamic>? saved;
  Map<String, dynamic>? created;
  MouldDetail get record => MouldDetail(
    id: 'mould',
    categoryId: 'cat',
    categoryName: '历史模具',
    code: 'MJ001',
    name: '旧模具名称',
    status: '使用',
    mstatus: saved?['mstatus'] as String? ?? '2008年7月',
    manufacturer: saved?['manufacturer'] as String?,
  );
  @override
  Future<PagedResult<MouldListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async => PagedResult(
    items: [
      MouldListItem(
        id: record.id,
        name: record.name,
        code: record.code,
        status: record.status,
        mstatus: record.mstatus,
        manufacturer: record.manufacturer,
      ),
    ],
    page: 1,
    size: 20,
    total: 1,
    totalPages: 1,
  );
  @override
  Future<MouldFacets> facets(String categoryId) async =>
      const MouldFacets(fields: {}, nullCounts: {});
  @override
  Future<MouldDetail> detail(String id) async => record;
  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    saved = Map.of(body);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    created = Map.of(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
