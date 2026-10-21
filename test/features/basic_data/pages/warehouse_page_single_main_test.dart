// 仓库资料页(ADR-145 单主仓)：
// - 仓库目录与货品目录共用层级行和增改删组件；用途筛选保留命中仓与主仓；
// - 编辑子仓：上级仓库只读、固定显示主仓名；内料仓标记只读；保存时不上送上级仓库与内料仓标记
//   (上级由服务端补成主仓)，仓库用途按 'true'/'false' 上送；
// - 主仓的仓库用途只读(主仓不能是不良品仓)；
// - 车间内料仓(ADR-147)只由「车间内料仓」开通和撤销：详情只读，没有编辑/停用/删除。
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_keeper_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _grants = StateProvider<Set<String>>((ref) => {});

const _allPermissions = {
  Perm.warehouseView,
  Perm.warehouseCreate,
  Perm.warehouseEdit,
  Perm.warehouseStatus,
  Perm.warehouseDelete,
};

const _main = WarehouseListItem(id: 'main', code: '001', name: '仓库(14年版)');
const _hardware = WarehouseListItem(
  id: 'c01',
  code: 'C01',
  name: '五金仓库',
  parentId: 'main',
  parentName: '仓库(14年版)',
  selectableForNew: true,
);
const _bin = WarehouseListItem(
  id: 'bin',
  code: 'LS-WS_ZHUANG',
  name: '装配第一车间内料仓',
  parentId: 'main',
  parentName: '仓库(14年版)',
  lineSide: true,
);
const _defective = WarehouseListItem(
  id: 'c0401',
  code: 'C0401',
  name: '成品不良品仓',
  parentId: 'main',
  parentName: '仓库(14年版)',
  defective: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('新增仓库可填写备注并提交正式字段', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseCreate},
    );
    await tester.tap(find.text('添加仓库'));
    await tester.pumpAndSettle();
    await tester.enterText(_input('仓库名称'), '新增备注仓库');
    await tester.enterText(_input('备注'), '新建仓库备注');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(warehouses.creates.single['name'], '新增备注仓库');
    expect(warehouses.creates.single['remark'], '新建仓库备注');
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库目录用途可筛选，主仓置顶保留子仓层级', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      facetPayload: const WarehouseFacets(
        fields: {
          'defective': [
            MasterFacetBucket(value: 'false', count: 9, label: '良品仓'),
            MasterFacetBucket(value: 'true', count: 2, label: '不良品仓'),
          ],
        },
        nullCounts: {},
      ),
    );
    await _pump(tester, warehouses, permissions: {Perm.warehouseView});

    final use = tester.widget<UtenDropdownField>(
      find.byKey(const Key('warehouse-directory-use-filter')),
    );
    expect(use.label, '仓库用途');
    expect(use.items.map((item) => item.label), containsAll(['良品仓', '不良品仓']));
    final tree = find.byKey(const Key('warehouse-directory-tree'));
    expect(
      tester
          .getTopLeft(
            find.descendant(of: tree, matching: find.text(_main.name!)),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.descendant(of: tree, matching: find.text(_hardware.name!)),
            )
            .dy,
      ),
    );
    use.onChanged('true');
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: tree, matching: find.text(_defective.name!)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tree, matching: find.text(_hardware.name!)),
      findsNothing,
    );
  });

  testWidgets('子仓编辑沿用共享模式，只提交实际改动和原值，不发送层级身份', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      details: {
        'c01': const WarehouseDetail(
          id: 'c01',
          code: 'C01',
          name: '五金仓库',
          status: '使用',
          parentId: 'main',
          remark: '五金配件保管区',
          selectableForNew: true,
        ),
      },
    );
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _defective.name!);
    await tester.tap(find.byKey(const ValueKey('warehouse-node-edit-c01')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byType(MasterInlineRecordEditor<WarehouseDetail>),
      findsOneWidget,
    );
    expect(find.text('仓库(14年版)'), findsWidgets);
    for (final field in ['code', 'parentName', 'isLineSide', 'status']) {
      expect(find.byKey(ValueKey('inline-activate-c01-$field')), findsNothing);
    }
    await _editText(tester, 'c01', 'remark', '重新规划的保管区');
    await _editChoice(tester, 'c01', 'defective', 'true');
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(warehouses.inlineWrites.single, {
      'path': '/master/inline-edit/warehouses/c01',
      'body': {
        'expected': {'remark': '五金配件保管区', 'defective': false},
        'changes': {'remark': '重新规划的保管区', 'defective': true},
      },
    });
    expect(warehouses.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('车间内料仓只读：详情说明由车间内料仓管理，没有编辑、停用、删除', (tester) async {
    final warehouses = _FakeWarehouseRepository(
      details: {
        'bin': const WarehouseDetail(
          id: 'bin',
          code: 'LS-WS_ZHUANG',
          name: '装配第一车间内料仓',
          status: '使用',
          parentId: 'main',
          lineSide: true,
        ),
      },
    );
    await _pump(
      tester,
      warehouses,
      permissions: {
        Perm.warehouseView,
        Perm.warehouseCreate,
        Perm.warehouseEdit,
        Perm.warehouseStatus,
        Perm.warehouseDelete,
      },
    );
    await _selectWarehouse(tester, _bin.name!);
    expect(find.textContaining('是, 由「车间内料仓」开通和管理 (这里只读)'), findsOneWidget);
    for (final action in ['add', 'edit', 'delete']) {
      expect(find.byKey(ValueKey('warehouse-node-$action-bin')), findsNothing);
    }
    await _rightClickWarehouse(tester, _bin.name!);
    expect(find.text('新增同级仓库'), findsNothing);
    expect(find.text('编辑仓库'), findsNothing);
    expect(find.text('停用'), findsNothing);
    expect(find.text('删除仓库'), findsNothing);
    expect(find.text('设置负责人'), findsOneWidget);
    await tester.tap(find.text('设置负责人'));
    await tester.pumpAndSettle();
    expect(find.textContaining('装配第一车间内料仓'), findsWidgets);
    expect(find.byKey(const Key('warehouse-keeper-picker')), findsOneWidget);
    expect(warehouses.updates, isEmpty);
  });

  testWidgets('主仓编辑仍保护状态和用途，只保存可编辑字段', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(tester, warehouses, permissions: _allPermissions);
    await _selectWarehouse(tester, _main.name!);
    await tester.tap(find.byKey(const ValueKey('warehouse-node-edit-main')));
    await tester.pumpAndSettle();
    for (final field in [
      'code',
      'status',
      'defective',
      'parentName',
      'isLineSide',
    ]) {
      expect(find.byKey(ValueKey('inline-activate-main-$field')), findsNothing);
    }
    await _editText(tester, 'main', 'name', '统一主仓');
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(warehouses.inlineWrites.single, {
      'path': '/master/inline-edit/warehouses/main',
      'body': {
        'expected': {'name': '仓库(14年版)'},
        'changes': {'name': '统一主仓'},
      },
    });
    expect(tester.takeException(), isNull);
  });

  for (final warehouse in [_main, _hardware]) {
    testWidgets('${warehouse.name}行内新增始终固定主仓，不创建第三层', (tester) async {
      final warehouses = _FakeWarehouseRepository();
      await _pump(tester, warehouses, permissions: _allPermissions);
      final add = find.byKey(ValueKey('warehouse-node-add-${warehouse.id}'));
      expect(add.hitTestable(), findsOneWidget);
      expect(
        tester.widget<IconButton>(add).tooltip,
        warehouse.isMain ? '新增子仓库' : '新增同级仓库',
      );
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('新增仓库'), findsOneWidget);
      final parent = tester.widget<TextField>(_field('上级仓库'));
      expect(parent.enabled, isFalse);
      expect(parent.controller!.text, _main.name);
      await tester.enterText(
        find.ancestor(
          of: find.text('仓库名称 *', findRichText: true),
          matching: find.byType(TextField),
        ),
        '新包装仓',
      );
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      final body = warehouses.creates.single;
      expect(body['name'], '新包装仓');
      expect(body.containsKey('parentId'), isFalse);
      expect(body.containsKey('parentName'), isFalse);
      expect(body.containsKey('isLineSide'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未选中的子仓行内删除确认和请求使用该行仓库', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(tester, warehouses, permissions: _allPermissions);
    await _selectWarehouse(tester, _bin.name!);
    await tester.tap(find.byKey(const ValueKey('warehouse-node-delete-c01')));
    await tester.pumpAndSettle();
    expect(find.text('确定删除「五金仓库」吗？'), findsOneWidget);
    expect(find.text('确定删除「装配第一车间内料仓」吗？'), findsNothing);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(warehouses.deletedIds, ['c01']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主仓无删除按钮且行菜单不提供停用或删除', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(tester, warehouses, permissions: _allPermissions);
    expect(
      find.byKey(const ValueKey('warehouse-node-add-main')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('warehouse-node-edit-main')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('warehouse-node-delete-main')),
      findsNothing,
    );
    await _rightClickWarehouse(tester, _main.name!);
    expect(find.text('编辑仓库'), findsOneWidget);
    expect(find.text('设置负责人'), findsOneWidget);
    expect(find.text('停用'), findsNothing);
    expect(find.text('删除仓库'), findsNothing);
    expect(warehouses.deletedIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('权限撤销后移除行按钮，旧回调与迟到详情不能打开编辑或删除', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    final container = await _pump(
      tester,
      warehouses,
      permissions: _allPermissions,
    );
    VoidCallback callback(String action) => tester
        .widget<IconButton>(find.byKey(ValueKey('warehouse-node-$action-c01')))
        .onPressed!;
    final oldAdd = callback('add');
    final oldDelete = callback('delete');
    final pending = Completer<WarehouseDetail>();
    warehouses.pendingDetails['c01'] = pending;
    await tester.tap(find.byKey(const ValueKey('warehouse-node-edit-c01')));
    await tester.pump();
    container.read(_grants.notifier).state = {Perm.warehouseView};
    await tester.pump();
    pending.complete(_warehouseDetail(_hardware));
    await tester.pumpAndSettle();
    for (final warehouse in [_main, _hardware, _defective, _bin]) {
      for (final action in ['add', 'edit', 'delete']) {
        expect(
          find.byKey(ValueKey('warehouse-node-$action-${warehouse.id}')),
          findsNothing,
        );
      }
    }
    expect(find.byKey(const Key('warehouse-add')), findsNothing);
    oldAdd();
    await tester.pumpAndSettle();
    oldDelete();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await _rightClickWarehouse(tester, _hardware.name!);
    expect(find.text('编辑仓库'), findsNothing);
    expect(find.text('删除仓库'), findsNothing);
    expect(find.text('设置负责人'), findsNothing);
    expect(warehouses.creates, isEmpty);
    expect(warehouses.updates, isEmpty);
    expect(warehouses.deletedIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一编辑模式切换多个仓库保留草稿并逐仓提交各自原值', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _hardware.name!);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _editText(tester, 'c01', 'remark', '五金新备注');
    await _selectWarehouse(tester, _defective.name!);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('保存 1 行修改'), findsOneWidget);
    await _editText(tester, 'c0401', 'location', '隔离区 B');
    expect(find.text('保存 2 行修改'), findsOneWidget);
    await tester.tap(find.text('保存 2 行修改'));
    await tester.pumpAndSettle();
    expect(warehouses.inlineWrites, [
      {
        'path': '/master/inline-edit/warehouses/c01',
        'body': {
          'expected': {'remark': null},
          'changes': {'remark': '五金新备注'},
        },
      },
      {
        'path': '/master/inline-edit/warehouses/c0401',
        'body': {
          'expected': {'location': null},
          'changes': {'location': '隔离区 B'},
        },
      },
    ]);
    expect(warehouses.details['c01']!.remark, '五金新备注');
    expect(warehouses.details['c0401']!.location, '隔离区 B');
    expect(find.text('保存 0 行修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消编辑和刷新共用未保存确认，继续编辑保留草稿而放弃不写资料', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _hardware.name!);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _editText(tester, 'c01', 'name', '暂存名称');
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('保存 1 行修改'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '暂存名称',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(
      find.byType(MasterInlineRecordEditor<WarehouseDetail>),
      findsNothing,
    );
    expect(find.text('编辑模式'), findsOneWidget);
    expect(warehouses.inlineWrites, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原值冲突保留编辑内容和未保存计数，重试仍使用同一原值', (tester) async {
    final warehouses = _FakeWarehouseRepository()
      ..inlineFailure = ApiException(
        'CONFLICT',
        '资料已被其他人修改，请刷新后重试',
        httpStatus: 409,
      );
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _hardware.name!);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _editText(tester, 'c01', 'name', '五金货架仓');
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(find.text('资料已被其他人修改，请刷新后重试'), findsOneWidget);
    expect(find.text('保存 1 行修改'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '五金货架仓',
      ),
      findsOneWidget,
    );
    warehouses.inlineFailure = null;
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(warehouses.inlineWrites, hasLength(2));
    expect(warehouses.inlineWrites.first, warehouses.inlineWrites.last);
    expect((warehouses.inlineWrites.last['body'] as Map)['expected'], {
      'name': '五金仓库',
    });
    expect(find.text('保存 0 行修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑权限撤销清除草稿并使已捕获的保存回调失效', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    final container = await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _hardware.name!);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _editText(tester, 'c01', 'name', '权限撤销前草稿');
    final button = tester.widget<UtenButton>(
      find.ancestor(
        of: find.text('保存 1 行修改'),
        matching: find.byType(UtenButton),
      ),
    );
    container.read(_grants.notifier).state = {Perm.warehouseView};
    await tester.pumpAndSettle();
    expect(
      find.byType(MasterInlineRecordEditor<WarehouseDetail>),
      findsNothing,
    );
    expect(find.text('取消编辑'), findsNothing);
    await button.onPressed!();
    await tester.pumpAndSettle();
    expect(warehouses.inlineWrites, isEmpty);
    expect(find.textContaining('权限撤销前草稿'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('核算选择不可清空，异常空值草稿按必填验证拦截而不写成false', (tester) async {
    final warehouses = _FakeWarehouseRepository();
    await _pump(
      tester,
      warehouses,
      permissions: {Perm.warehouseView, Perm.warehouseEdit},
    );
    await _selectWarehouse(tester, _hardware.name!);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    final record = tester.widget<MasterInlineRecordEditor<WarehouseDetail>>(
      find.byType(MasterInlineRecordEditor<WarehouseDetail>),
    );
    final field = record.fields['accountable']!;
    expect(field.required, isTrue);
    final activation = find.byKey(
      const ValueKey('inline-activate-c01-accountable'),
    );
    await tester.ensureVisible(activation);
    await tester.pumpAndSettle();
    await tester.tap(activation);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenDropdownField>(
            find.descendant(
              of: find.byKey(const ValueKey('inline-c01-accountable')),
              matching: find.byType(UtenDropdownField),
            ),
          )
          .allowClear,
      isFalse,
    );
    record.controller.rememberBaseline('c01', record.row);
    record.controller.setValue('c01', field, null, originalValue: true);
    await tester.pump();
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(find.text('必填项不能为空 / Required value is missing'), findsOneWidget);
    expect(warehouses.inlineWrites, isEmpty);
    expect(warehouses.details['c01']?.accountable ?? true, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _editText(
  WidgetTester tester,
  String id,
  String field,
  String value,
) async {
  final activation = find.byKey(ValueKey('inline-activate-$id-$field'));
  await tester.ensureVisible(activation);
  await tester.pumpAndSettle();
  await tester.tap(activation);
  await tester.pumpAndSettle();
  final input = find.descendant(
    of: find.byKey(ValueKey('inline-$id-$field')),
    matching: find.byType(TextField),
  );
  await tester.enterText(input, value);
  await tester.pump();
}

Future<void> _editChoice(
  WidgetTester tester,
  String id,
  String field,
  String value,
) async {
  final activation = find.byKey(ValueKey('inline-activate-$id-$field'));
  await tester.ensureVisible(activation);
  await tester.pumpAndSettle();
  await tester.tap(activation);
  await tester.pumpAndSettle();
  final dropdown = tester.widget<UtenDropdownField>(
    find.descendant(
      of: find.byKey(ValueKey('inline-$id-$field')),
      matching: find.byType(UtenDropdownField),
    ),
  );
  expect(dropdown.allowClear, isFalse);
  dropdown.onChanged(value);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _rightClickWarehouse(WidgetTester tester, String name) async {
  final row = find.descendant(
    of: find.byKey(const Key('warehouse-directory-tree')),
    matching: find.text(name),
  );
  final gesture = await tester.startGesture(
    tester.getCenter(row),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _selectWarehouse(WidgetTester tester, String name) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('warehouse-directory-tree')),
      matching: find.text(name),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _input(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextField));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeWarehouseRepository warehouses, {
  required Set<String> permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_DictApi(warehouses)),
        authenticatedScopeProvider.overrideWithValue(null),
        sharedPreferencesProvider.overrideWithValue(preferences),
        warehouseRepositoryProvider.overrideWithValue(warehouses),
        warehouseKeeperRepositoryProvider.overrideWithValue(
          _FakeKeeperRepository(),
        ),
        masterNameServiceProvider.overrideWithValue(
          MasterNameService(_DictApi()),
        ),
        _grants.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        home: WarehousePage(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(WarehousePage)));
}

WarehouseDetail _warehouseDetail(WarehouseListItem warehouse) =>
    WarehouseDetail(
      id: warehouse.id,
      code: warehouse.code,
      name: warehouse.name,
      parentId: warehouse.parentId,
      lineSide: warehouse.lineSide,
      defective: warehouse.defective,
      selectableForNew: warehouse.selectableForNew,
      status: '使用',
      remark: warehouse.remark,
    );

class _FakeWarehouseRepository implements WarehouseRepository {
  _FakeWarehouseRepository({
    this.facetPayload,
    Map<String, WarehouseDetail> details = const {},
  }) : details = Map.of(details);

  final WarehouseFacets? facetPayload;
  final Map<String, WarehouseDetail> details;
  Map<String, String?>? lastFilters;
  final updates = <Map<String, dynamic>>[];
  final inlineWrites = <Map<String, dynamic>>[];
  ApiException? inlineFailure;

  void applyInline(String id, Map<String, dynamic> changes) {
    final original =
        details[id] ??
        _warehouseDetail(
          const [
            _main,
            _hardware,
            _defective,
            _bin,
          ].singleWhere((row) => row.id == id),
        );
    details[id] = WarehouseDetail(
      id: id,
      code: original.code,
      name: changes.containsKey('name')
          ? changes['name'] as String?
          : original.name,
      location: changes.containsKey('location')
          ? changes['location'] as String?
          : original.location,
      remark: changes.containsKey('remark')
          ? changes['remark'] as String?
          : original.remark,
      accountable: changes['accountable'] as bool? ?? original.accountable,
      defective: changes['defective'] as bool? ?? original.defective,
      status: changes['status'] as String? ?? original.status,
      parentId: original.parentId,
      lineSide: original.lineSide,
      selectableForNew: original.selectableForNew,
      workshopDepartmentId: original.workshopDepartmentId,
      workshopDepartmentName: original.workshopDepartmentName,
    );
  }

  final updatedIds = <String>[];
  final creates = <Map<String, dynamic>>[];
  final deletedIds = <String>[];
  final pendingDetails = <String, Completer<WarehouseDetail>>{};

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    lastFilters = Map<String, String?>.from(filters);
    return PagedResult(
      items: const [_main, _hardware, _defective],
      page: page,
      size: size,
      total: 3,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseFacets> facets() async =>
      facetPayload ?? const WarehouseFacets(fields: {}, nullCounts: {});

  @override
  Future<List<WarehouseWorkshopOption>> workshops() async => const [];

  @override
  Future<List<WarehouseListItem>> dict() async => const [
    _main,
    _hardware,
    _defective,
    _bin,
  ];

  @override
  Future<WarehouseDetail> detail(String id) async =>
      await pendingDetails[id]?.future ??
      details[id] ??
      _warehouseDetail(
        const [
          _main,
          _hardware,
          _defective,
          _bin,
        ].singleWhere((w) => w.id == id),
      );

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    updatedIds.add(id);
    updates.add(Map<String, dynamic>.from(body));
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    creates.add(Map<String, dynamic>.from(body));
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeeperRepository implements WarehouseKeeperRepository {
  @override
  Future<List<WarehouseKeeperAssignment>> assignments() async => const [];

  @override
  Future<List<WarehouseKeeper>> keepers(String warehouseId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 仓库字典：主仓 + 子仓(服务端算好的 selectableForNew)。
class _DictApi implements ApiClient {
  _DictApi([this.warehouses]);
  final _FakeWarehouseRepository? warehouses;

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    final repository = warehouses!;
    final payload = Map<String, dynamic>.from(body! as Map);
    repository.inlineWrites.add({'path': path, 'body': payload});
    if (repository.inlineFailure case final failure?) throw failure;
    repository.applyInline(
      path.split('/').last,
      Map<String, dynamic>.from(payload['changes'] as Map),
    );
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return [
        {'id': 'main', 'name': '仓库(14年版)', 'code': '001'},
        {
          'id': 'c01',
          'name': '五金仓库',
          'code': 'C01',
          'parentId': 'main',
          'selectableForNew': true,
        },
      ];
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
