import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_department_tree.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker_models.dart';
import 'package:uten_imp/components/inputs/uten_employee_selection_panel.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';

import '../../support/audit_screenshot_support.dart';

const _company = '示例电器有限公司';
const _salesCenter = '营销管理中心';
const _productionCenter = '生产管理中心';
const _longTeam = '海外业务与长期合作重点客户销售组';
final _captureKey = GlobalKey(debugLabel: 'employee-hierarchy-capture');
bool _fontsLoaded = false;
const _tableKey = Key('uten-employee-picker-candidates');
const _treeKey = Key('uten-employee-picker-departments');

const _sales = UtenEmployeePickerItem(
  id: 'sales-person',
  name: '张明',
  employeeCode: 'TEST001',
  departmentId: 'sales',
  departmentName: '业务部',
  accountStatus: 'active',
  employmentStatus: 'active',
);
const _team = UtenEmployeePickerItem(
  id: 'team-person',
  name: '林晓',
  employeeCode: 'TEST002',
  departmentId: 'overseas',
  departmentName: _longTeam,
  accountStatus: 'locked',
  employmentStatus: 'onLeave',
);
const _other = UtenEmployeePickerItem(
  id: 'production-person',
  name: '陈华',
  employeeCode: 'TEST003',
  departmentId: 'production-sales',
  departmentName: '业务部',
  accountStatus: 'active',
  employmentStatus: 'resigned',
);
const _disabled = UtenEmployeePickerItem(
  id: 'missing-phone',
  name: '刘萍',
  employeeCode: 'TEST004',
  departmentId: 'sales',
  departmentName: '业务部',
  accountStatus: 'notProvisioned',
  employmentStatus: 'probation',
  enabled: false,
  disabledReason: '请先在员工档案中补全手机号',
);
const _external = UtenEmployeePickerItem(
  id: 'external-actor',
  name: '审计访客',
  departmentId: 'audit-external',
  departmentName: '外部审计人员',
);
const _unknown = UtenEmployeePickerItem(id: 'unknown-actor', name: '历史操作人');
const _rows = [_sales, _team, _other, _disabled];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('组织目录保留真实父子路径，剪除无候选分支且同名部门按ID隔离', () {
    final directory = UtenEmployeeDepartmentDirectory(
      organization: _organization(),
      candidates: _rows,
    );
    final company = directory.nodes.singleWhere(
      (node) => node.id == 'department:company',
    );
    expect(company.children.map((node) => node.name), [
      _salesCenter,
      _productionCenter,
    ]);
    expect(company.children.first.children.single.id, 'department:sales');
    expect(
      company.children.first.children.single.children.single.id,
      'department:overseas',
    );
    expect(directory.contains('department:marketing', _sales), isTrue);
    expect(directory.contains('department:marketing', _team), isTrue);
    expect(directory.contains('department:marketing', _other), isFalse);
    expect(directory.contains('department:sales', _other), isFalse);
    expect(
      directory.pathOf(_team),
      '$_company / $_salesCenter / 业务部 / $_longTeam',
    );
    expect(_allNodeIds(directory.nodes), isNot(contains('department:finance')));
  });

  testWidgets('开通账号标题使用员工表格，父级部门同时展示子部门授权员工', (tester) async {
    await _pump(tester);
    expect(find.text('选择开通账号的员工'), findsOneWidget);
    final table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
      find.byKey(_tableKey),
    );
    expect(table.columns.map((column) => column.label), [
      '姓名',
      '工号',
      '部门',
      '账号状态',
      '在职状态',
      '说明',
    ]);
    expect(find.text('财务管理中心'), findsNothing);
    expect(find.text('已开通'), findsNWidgets(2));
    expect(find.text('锁定'), findsOneWidget);
    expect(find.text('未开通'), findsOneWidget);
    expect(find.text('在职'), findsOneWidget);
    expect(find.text('休假'), findsOneWidget);
    expect(find.text('离职'), findsOneWidget);
    expect(find.text('试用'), findsOneWidget);
    await tester.tap(_treeText(_salesCenter));
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {
      'sales-person',
      'team-person',
      'missing-phone',
    });
    expect(
      find.byTooltip('$_company / $_salesCenter / 业务部 / $_longTeam'),
      findsOneWidget,
    );
    await tester.tap(_treeText(_productionCenter));
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {'production-person'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('同名部门分别选择不会串组，搜索父级名称与姓名保留真实祖先', (tester) async {
    final queries = <String?>[];
    await _pump(
      tester,
      loader: (query) async {
        queries.add(query);
        return query == null ? _rows : const [];
      },
    );
    await tester.tap(_treeText(_salesCenter));
    await tester.pumpAndSettle();
    await tester.tap(_treeText(_productionCenter));
    await tester.pumpAndSettle();
    final sameNames = _treeText('业务部');
    expect(sameNames, findsNWidgets(2));
    await tester.tap(sameNames.first);
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {
      'sales-person',
      'team-person',
      'missing-phone',
    });
    await tester.tap(_treeText('业务部').last);
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {'production-person'});

    await tester.enterText(_search(), '$_salesCenter 林晓');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(queries.last, '$_salesCenter 林晓');
    expect(_visibleCandidateIds(tester), {'team-person'});
    expect(_treeText(_company), findsOneWidget);
    expect(_treeText(_salesCenter), findsOneWidget);
    expect(_treeText(_longTeam), findsOneWidget);
    expect(_treeText(_productionCenter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('审计外部及未知部门候选保留在其它候选分组，不能混入公司树', (tester) async {
    await _pump(tester, loader: (_) async => [..._rows, _external, _unknown]);
    expect(_treeText('其它候选'), findsOneWidget);
    await tester.tap(_treeText('其它候选'));
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {'external-actor', 'unknown-actor'});
    expect(_treeText('外部审计人员'), findsOneWidget);
    expect(_treeText('未提供部门'), findsOneWidget);
    await tester.tap(_treeText('未提供部门'));
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {'unknown-actor'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨部门多选与表头全选只选择授权且可用人员，确认前不返回', (tester) async {
    List<UtenEmployeePickerItem>? result;
    await _pump(tester, multiple: true, onConfirm: (items) => result = items);
    await tester.tap(_treeText(_salesCenter));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('master-data-table-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 人'), findsOneWidget);
    await tester.tap(_treeText(_productionCenter));
    await tester.pumpAndSettle();
    await tester.tap(find.text('陈华'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 人'), findsOneWidget);
    await tester.tap(_treeText(_salesCenter));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('master-data-table-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 人'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result?.map((item) => item.id), ['production-person']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组织树加载失败可重试且不会把候选扩成全员', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      treeLoader: () async {
        calls++;
        if (calls == 1) throw StateError('fixture tree unavailable');
        return _organization();
      },
    );
    expect(find.text('部门层级加载失败'), findsOneWidget);
    expect(_visibleCandidateIds(tester), _rows.map((item) => item.id).toSet());
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(_treeText(_company), findsOneWidget);
    expect(find.text('财务管理中心'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏部门筛选的专用候选不请求组织树', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      showDepartmentFilter: false,
      treeLoader: () async {
        calls++;
        return _organization();
      },
    );
    expect(calls, 0);
    expect(find.byKey(_treeKey), findsNothing);
    expect(_visibleCandidateIds(tester), _rows.map((item) => item.id).toSet());
    expect(tester.takeException(), isNull);
  });

  testWidgets('候选范围切换后等待新树时不得用旧祖先名称补回新候选', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ValueNotifier('A');
    addTearDown(scope.dispose);
    final pendingTree = Completer<List<DepartmentNode>>();
    const nextCandidate = UtenEmployeePickerItem(
      id: 'scope-b-person',
      name: '新范围员工',
      employeeCode: 'TEST-B',
      departmentId: 'sales',
      departmentName: '业务部',
    );
    final queries = <(String, String?)>[];
    List<DepartmentNode> scopedTree(String ancestorName) => [
      DepartmentNode(
        id: 'company',
        code: 'TEST-COMPANY',
        name: _company,
        level: '公司',
        children: [
          DepartmentNode(
            id: 'center',
            code: 'TEST-CENTER',
            name: ancestorName,
            level: '管理中心',
            parentId: 'company',
            children: [
              DepartmentNode(
                id: 'sales',
                code: 'TEST-SALES',
                name: '业务部',
                level: '一级部门',
                parentId: 'center',
                children: const [],
              ),
            ],
          ),
        ],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: scope,
            builder: (context, value, child) => UtenEmployeeSelectionPanel(
              candidateScopeKey: value,
              departmentTreeLoader: () => value == 'A'
                  ? Future.value(scopedTree('旧营销中心'))
                  : pendingTree.future,
              loader: (query) async {
                queries.add((value, query));
                if (query != null) return const [];
                return value == 'A' ? const [_sales] : const [nextCandidate];
              },
              onConfirm: (_) {},
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_treeText('旧营销中心'), findsOneWidget);
    expect(_visibleCandidateIds(tester), {'sales-person'});

    scope.value = 'B';
    await tester.pump();
    await tester.pump();
    expect(_visibleCandidateIds(tester), {'scope-b-person'});
    expect(_treeText('旧营销中心'), findsNothing);
    await tester.enterText(_search(), '旧营销中心');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    expect(queries, contains(('B', '旧营销中心')));
    expect(
      find.byKey(_tableKey),
      findsNothing,
      reason: '同一部门ID不能沿用A范围祖先名称补回B范围候选',
    );
    expect(find.text('未找到匹配的人员'), findsOneWidget);

    pendingTree.complete(scopedTree('新营销中心'));
    await tester.pumpAndSettle();
    expect(find.byKey(_tableKey), findsNothing);
    await tester.enterText(_search(), '新营销中心');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(_visibleCandidateIds(tester), {'scope-b-person'});
    expect(
      find.descendant(
        of: find.byKey(_treeKey),
        matching: find.byTooltip('$_company / 新营销中心'),
      ),
      findsOneWidget,
    );
    expect(_treeText('旧营销中心'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in ['light', 'dark', 'narrow', 'compact']) {
    testWidgets('员工组织表格真实中文预览 $scenario', (tester) async {
      if (!_fontsLoaded) {
        await loadAuditScreenshotFonts(tester);
        _fontsLoaded = true;
      }
      await _pump(
        tester,
        size: scenario == 'compact'
            ? const Size(390, 820)
            : const Size(1440, 900),
        dark: scenario == 'dark',
        auditFont: true,
      );
      if (scenario == 'compact') {
        await tester.tap(find.byIcon(Icons.account_tree_rounded));
        await tester.pumpAndSettle();
        await tester.tap(_treeText(_salesCenter));
        await tester.pumpAndSettle();
        expect(find.byKey(_treeKey), findsNothing);
      } else {
        await tester.tap(find.byTooltip('展开$_salesCenter'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('展开业务部').first);
        await tester.pumpAndSettle();
        if (scenario == 'narrow') {
          final naturalWidth = tester.getSize(find.byKey(_treeKey)).width;
          await tester.drag(
            find.byTooltip('拖动调整宽度 · 双击复位'),
            const Offset(-1400, 0),
          );
          await tester.pumpAndSettle();
          final narrowedWidth = tester.getSize(find.byKey(_treeKey)).width;
          expect(narrowedWidth, lessThan(naturalWidth));
          expect(narrowedWidth, inInclusiveRange(160, 240));
          // Expanded controls retain their measured safety width; only labels
          // elide. Search still reserves the shared trailing scrollbar lane.
          expect(
            tester.getSize(_search()).width,
            narrowedWidth - UtenScrollGutter.trackWidth,
          );
          final directoryBounds = tester.getRect(find.byKey(_treeKey));
          for (final control in [
            find.byTooltip('收起$_salesCenter'),
            find.byTooltip('收起业务部').first,
          ]) {
            expect(control.hitTestable(), findsOneWidget);
            final bounds = tester.getRect(control);
            expect(directoryBounds.contains(bounds.center), isTrue);
            expect(bounds.left, greaterThanOrEqualTo(directoryBounds.left));
            expect(bounds.right, lessThanOrEqualTo(directoryBounds.right));
          }
          expect(
            find.byTooltip('$_company / $_salesCenter / 业务部 / $_longTeam'),
            findsNWidgets(2),
          );
          await tester.enterText(_search(), '林晓');
          await tester.pump(const Duration(milliseconds: 301));
          await tester.pumpAndSettle();
          final clear = find.byTooltip('清除搜索');
          expect(clear.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(_search()).contains(tester.getRect(clear).center),
            isTrue,
          );
          await tester.tap(clear);
          await tester.pumpAndSettle();
          expect(tester.getSize(find.byKey(_treeKey)).width, narrowedWidth);
          expect(_treeText('全部部门'), findsOneWidget);
          final allDepartments = _treeText('全部部门');
          expect(tester.widget<Text>(allDepartments).maxLines, 1);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: allDepartments,
              matching: find.byType(RichText),
            ),
          );
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason:
                'the complete label fits its actual font; 60px may be its exact intrinsic width',
          );
        }
      }
      await tester.tap(find.text('张明'));
      await tester.pumpAndSettle();
      expect(find.text('已选择：张明(TEST001)'), findsOneWidget);
      if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'employee-picker-hierarchy-$scenario',
        );
      }
      if (scenario == 'compact') {
        await tester.drag(find.text('TEST001'), const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(find.text('锁定').hitTestable(), findsOneWidget);
        expect(find.text('休假').hitTestable(), findsOneWidget);
        if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'employee-picker-hierarchy-compact-statuses',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pump(
  WidgetTester tester, {
  UtenEmployeePickerLoader? loader,
  Future<List<DepartmentNode>> Function()? treeLoader,
  bool multiple = false,
  bool showDepartmentFilter = true,
  ValueChanged<List<UtenEmployeePickerItem>>? onConfirm,
  Size size = const Size(1200, 900),
  bool dark = false,
  bool auditFont = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var theme = (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
    platform: TargetPlatform.windows,
  );
  if (auditFont) theme = auditScreenshotTheme(theme);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RepaintBoundary(
        key: _captureKey,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Text(
                    '界面验证 · 以下均为测试数据',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: UtenEmployeeSelectionPanel(
                    loader:
                        loader ??
                        (query) async => query == null
                            ? _rows
                            : _rows
                                  .where(
                                    (item) =>
                                        item.name.contains(query) ||
                                        (item.employeeCode?.contains(query) ??
                                            false),
                                  )
                                  .toList(),
                    departmentTreeLoader:
                        treeLoader ?? () async => _organization(),
                    title: '选择开通账号的员工',
                    multiple: multiple,
                    showDepartmentFilter: showDepartmentFilter,
                    onConfirm: onConfirm ?? (_) {},
                    onCancel: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _treeText(String text) =>
    find.descendant(of: find.byKey(_treeKey), matching: find.text(text));
Finder _search() => find.descendant(
  of: find.byKey(const Key('uten-employee-picker-search')),
  matching: find.byType(TextField),
);
Set<String> _visibleCandidateIds(WidgetTester tester) => tester
    .widget<MasterDataTableView<UtenEmployeePickerItem>>(find.byKey(_tableKey))
    .items
    .map((item) => item.id)
    .toSet();
Set<String> _allNodeIds(List<UtenEmployeeDepartmentNode> nodes) => {
  for (final node in nodes) ...{node.id, ..._allNodeIds(node.children)},
};

List<DepartmentNode> _organization() => [
  DepartmentNode(
    id: 'company',
    code: 'TEST-COMPANY',
    name: _company,
    level: '公司',
    children: [
      DepartmentNode(
        id: 'marketing',
        code: 'TEST-MKT',
        name: _salesCenter,
        level: '管理中心',
        parentId: 'company',
        children: [
          DepartmentNode(
            id: 'sales',
            code: 'TEST-SALES',
            name: '业务部',
            level: '一级部门',
            parentId: 'marketing',
            children: [
              DepartmentNode(
                id: 'overseas',
                code: 'TEST-OVERSEAS',
                name: _longTeam,
                level: '二级班组',
                parentId: 'sales',
                children: const [],
              ),
            ],
          ),
        ],
      ),
      DepartmentNode(
        id: 'manufacturing',
        code: 'TEST-MFG',
        name: _productionCenter,
        level: '管理中心',
        parentId: 'company',
        children: [
          DepartmentNode(
            id: 'production-sales',
            code: 'TEST-MFG-SALES',
            name: '业务部',
            level: '一级部门',
            parentId: 'manufacturing',
            children: const [],
          ),
        ],
      ),
      DepartmentNode(
        id: 'finance',
        code: 'TEST-FIN',
        name: '财务管理中心',
        level: '管理中心',
        parentId: 'company',
        children: const [],
      ),
    ],
  ),
];
