import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

void main() {
  test('列表和详情分别读取客户货品名称与客户型号，不替代内部名称或英文名称', () {
    final json = <String, dynamic>{
      'id': 'customer-labelled-goods',
      'name': '内部货品名称',
      'clientGoodsName': '客户文件货品名称',
      'nameEn': 'English goods name',
      'model': 'INTERNAL-MODEL',
      'cNumber': 'CUSTOMER-MODEL',
    };
    final list = GoodsListItem.fromJson(json);
    final detail = GoodsDetail.fromJson(json);
    expect(list.name, '内部货品名称');
    expect(list.clientGoodsName, '客户文件货品名称');
    expect(list.nameEn, 'English goods name');
    expect(list.model, 'INTERNAL-MODEL');
    expect(list.cNumber, 'CUSTOMER-MODEL');
    expect(detail.name, list.name);
    expect(detail.clientGoodsName, list.clientGoodsName);
    expect(detail.nameEn, list.nameEn);
    expect(detail.model, list.model);
    expect(detail.cNumber, list.cNumber);
  });

  test('旧响应缺少客户货品名称时保持空值，兼容旧 cnumber 字段', () {
    final legacy = <String, dynamic>{
      'id': 'legacy-goods',
      'name': '旧货品',
      'nameEn': 'Legacy English name',
      'cnumber': 'OLD-CUSTOMER-MODEL',
    };
    expect(GoodsListItem.fromJson(legacy).clientGoodsName, isNull);
    expect(GoodsDetail.fromJson(legacy).clientGoodsName, isNull);
    expect(GoodsListItem.fromJson(legacy).cNumber, 'OLD-CUSTOMER-MODEL');
    expect(GoodsDetail.fromJson(legacy).cNumber, 'OLD-CUSTOMER-MODEL');
    final empty = <String, dynamic>{'id': 'unlabelled-goods'};
    expect(GoodsListItem.fromJson(empty).clientGoodsName, isNull);
    expect(GoodsListItem.fromJson(empty).cNumber, isNull);
    expect(GoodsDetail.fromJson(empty).clientGoodsName, isNull);
    expect(GoodsDetail.fromJson(empty).cNumber, isNull);
  });

  testWidgets('查看与编辑的客户字段紧邻对应字段，修改和清空各自独立提交', (tester) async {
    await _pumpGoods(tester, detail: _labelledGoods);
    final grids = tester.widgetList<UtenFormGrid>(find.byType(UtenFormGrid));
    _expectGridField(grids.elementAt(0), 0, '货品名称');
    _expectGridField(grids.elementAt(0), 1, '客户货品名称');
    _expectGridField(grids.elementAt(1), 0, '型号');
    _expectGridField(grids.elementAt(1), 1, '客户型号');
    expect(find.text('客户文件货品名称'), findsOneWidget);
    expect(find.text('CUSTOMER-MODEL'), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    _expectCustomerFieldOrder(form);
    final state = tester.state<MasterEditFormState>(
      find.byType(MasterEditForm),
    );
    expect(state.controller.controllers['clientGoodsName']!.text, '客户文件货品名称');
    expect(state.controller.controllers['cNumber']!.text, 'CUSTOMER-MODEL');

    await tester.enterText(_field(state, 'clientGoodsName'), '客户改后的名称');
    var body = _buildBody(state);
    expect(body['clientGoodsName'], '客户改后的名称');
    expect(body['cNumber'], 'CUSTOMER-MODEL');
    expect(body['name'], '内部货品名称');
    expect(body['nameEn'], 'English goods name');
    expect(body['model'], 'INTERNAL-MODEL');

    await tester.enterText(_field(state, 'cNumber'), 'CUSTOMER-MODEL-2');
    body = _buildBody(state);
    expect(body['cNumber'], 'CUSTOMER-MODEL-2');
    expect(body['clientGoodsName'], '客户改后的名称');
    expect(body['model'], 'INTERNAL-MODEL');

    await tester.enterText(_field(state, 'clientGoodsName'), '');
    await tester.enterText(_field(state, 'cNumber'), '');
    body = _buildBody(state);
    expect(body, containsPair('clientGoodsName', null));
    expect(body, containsPair('cNumber', null));
    expect(body['name'], '内部货品名称');
    expect(body['nameEn'], 'English goods name');
    expect(body['model'], 'INTERNAL-MODEL');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增货品可填写两个客户字段，提交保持各字段独立', (tester) async {
    await _pumpGoods(tester);
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    _expectCustomerFieldOrder(form);
    final state = tester.state<MasterEditFormState>(
      find.byType(MasterEditForm),
    );
    expect(state.controller.controllers['clientGoodsName']!.text, isEmpty);
    expect(state.controller.controllers['cNumber']!.text, isEmpty);
    await tester.enterText(_field(state, 'name'), '新增内部名称');
    await tester.enterText(_field(state, 'clientGoodsName'), '新增客户名称');
    await tester.enterText(_field(state, 'model'), 'NEW-INTERNAL-MODEL');
    await tester.enterText(_field(state, 'cNumber'), 'NEW-CUSTOMER-MODEL');
    state.controller.setSelect('sourceType', '自制');
    state.controller.setSelect('unitId', 'unit-pcs');
    final body = _buildBody(state);
    expect(body['name'], '新增内部名称');
    expect(body['clientGoodsName'], '新增客户名称');
    expect(body['model'], 'NEW-INTERNAL-MODEL');
    expect(body['cNumber'], 'NEW-CUSTOMER-MODEL');
    expect(body['nameEn'], isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有货品基础编辑权限时客户名称与客户型号不可编辑也不提交', (tester) async {
    await _pumpGoods(
      tester,
      detail: _labelledGoods,
      permissions: const {Perm.goodsView, Perm.goodsEdit},
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    final state = tester.state<MasterEditFormState>(
      find.byType(MasterEditForm),
    );
    for (final key in ['clientGoodsName', 'cNumber', 'nameEn']) {
      expect(form.readOnlyKeys, contains(key));
      expect(tester.widget<TextField>(_field(state, key)).enabled, isFalse);
      state.controller.controllers[key]!.text = '过期表单中的未授权修改';
    }
    final body = state.buildBody(skipKeys: form.readOnlyKeys ?? const {});
    expect(body, isNotNull);
    for (final key in ['clientGoodsName', 'cNumber', 'nameEn']) {
      expect(body, isNot(contains(key)));
    }
    expect(body!['name'], '内部货品名称');
    expect(body['model'], 'INTERNAL-MODEL');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字暗色下客户字段纵向排列，切换编辑保留内容', (tester) async {
    await _pumpGoods(
      tester,
      detail: _labelledGoods,
      size: const Size(390, 844),
      textScale: 1.8,
      brightness: Brightness.dark,
    );
    final viewGrid = tester.widget<UtenFormGrid>(
      find.byType(UtenFormGrid).first,
    );
    final nameRect = tester.getRect(find.byWidget(viewGrid.children[0]));
    final clientNameRect = tester.getRect(find.byWidget(viewGrid.children[1]));
    expect(clientNameRect.top, greaterThanOrEqualTo(nameRect.bottom));
    expect(clientNameRect.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final state = tester.state<MasterEditFormState>(
      find.byType(MasterEditForm),
    );
    final nameField = tester.getRect(_field(state, 'name'));
    final clientField = tester.getRect(_field(state, 'clientGoodsName'));
    expect(clientField.top, greaterThanOrEqualTo(nameField.bottom));
    expect(clientField.right, lessThanOrEqualTo(390));
    expect(state.controller.controllers['clientGoodsName']!.text, '客户文件货品名称');
    expect(state.controller.controllers['cNumber']!.text, 'CUSTOMER-MODEL');
    expect(
      Theme.of(tester.element(_field(state, 'clientGoodsName'))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  test('新增客户名称列插回名称后，保留用户已保存列的相对顺序和宽度', () {
    final controller = PlatformTableController<GoodsListItem>();
    addTearDown(controller.dispose);
    const declared = [
      'name',
      'clientGoodsName',
      'nameEn',
      'hasBom',
      'code',
      'model',
      'cNumber',
      'spec',
    ];
    const saved = [
      'spec',
      'model',
      'code',
      'name',
      'nameEn',
      'hasBom',
      'cNumber',
    ];
    controller.layout = const PlatformTableLayout(
      order: saved,
      hidden: {'spec'},
      widths: {'name': 245, 'cNumber': 170},
    );
    final result = controller.localLayout(
      declared,
      defaultHidden: {},
      insertNewColumnsAtDeclaredPosition: true,
    );
    expect(result.order.where((key) => key != 'clientGoodsName'), saved);
    expect(result.order[result.order.indexOf('name') + 1], 'clientGoodsName');
    expect(result.hidden, {'spec'});
    expect(result.widths, {'name': 245, 'cNumber': 170});

    controller.layout = const PlatformTableLayout();
    expect(controller.localLayout(declared, defaultHidden: {}).order, declared);
  });
}

const _labelledGoods = GoodsDetail(
  id: 'customer-labelled-goods',
  name: '内部货品名称',
  clientGoodsName: '客户文件货品名称',
  nameEn: 'English goods name',
  model: 'INTERNAL-MODEL',
  cNumber: 'CUSTOMER-MODEL',
  status: '使用',
  sourceType: '自制',
  unitId: 'unit-pcs',
  unitName: '个',
  writable: true,
);

Future<void> _pumpGoods(
  WidgetTester tester, {
  GoodsDetail? detail,
  Size size = const Size(1440, 1100),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Set<String> permissions = const {
    Perm.goodsView,
    Perm.goodsCreate,
    Perm.goodsEdit,
    Perm.goodsSalesEdit,
  },
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith(
          (ref) async => const [UnitListItem(id: 'unit-pcs', name: '个')],
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: detail,
            initialCategoryId: null,
            canCreate: true,
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
}

Finder _field(MasterEditFormState state, String key) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      identical(widget.controller, state.controller.controllers[key]),
);

Map<String, dynamic> _buildBody(MasterEditFormState state) {
  final body = state.buildBody();
  expect(body, isNotNull, reason: state.controller.error);
  return body!;
}

void _expectCustomerFieldOrder(MasterEditForm form) {
  final keys = form.fields.map((field) => field.key).toList();
  expect(keys[keys.indexOf('name') + 1], 'clientGoodsName');
  expect(keys[keys.indexOf('model') + 1], 'cNumber');
  for (final key in ['clientGoodsName', 'cNumber']) {
    final field = form.fields.singleWhere((field) => field.key == key);
    expect(field.type, MasterFieldType.text);
    expect(field.readOnly, isFalse);
    expect(field.required, isFalse);
  }
}

void _expectGridField(UtenFormGrid grid, int index, String label) {
  expect(
    find.descendant(
      of: find.byWidget(grid.children[index]),
      matching: find.text(label),
    ),
    findsOneWidget,
  );
}
