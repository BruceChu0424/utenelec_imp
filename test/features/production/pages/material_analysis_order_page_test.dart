// 准备三桶与主表共用核对页：沿原 BOM 行输入、预览、选择和下达。
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  testWidgets('准备最新：核对页仍使用共享事实轮询并保留已填写数量', (tester) async {
    late Map<String, dynamic> serverData;
    await _pump(
      tester,
      mutate: (data) {
        serverData = data;
        for (final raw in data['flatMaterials'] as List) {
          final line = raw as Map<String, dynamic>;
          if (line['materialLineId'] != 'm-b') continue;
          line.addAll({
            'preparationPoolKey': 'b-pool',
            'preparationSharedAvailableQty': 1000,
            'preparationOwnedAvailableQty': 100,
            'preparationUncoveredBeforeSharedQty': 20,
          });
        }
        return data;
      },
    );
    await _openOrder(tester);
    await _type(tester, 'm-b', '25');
    for (final raw in serverData['flatMaterials'] as List) {
      final line = raw as Map<String, dynamic>;
      if (line['materialLineId'] == 'm-b') {
        line['preparationSharedAvailableQty'] = 900;
      }
    }
    await tester.pump(const Duration(seconds: 45));
    await tester.pumpAndSettle();
    expect(_qty(tester, 'm-b'), '25');
    expect(_table(tester).selectedIds, contains('PREPARATION|m-b'));
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('material-analysis-public-available-m-b'),
        ),
        matching: find.text('875'),
      ),
      findsOneWidget,
    );
  });
  testWidgets('统一核对页与主表共用选择预算，取消后余额恢复且输入保留', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        for (final raw in data['flatMaterials'] as List) {
          final line = raw as Map;
          if (!['m-b', 'm-d'].contains(line['materialLineId'])) continue;
          line.addAll(<String, dynamic>{
            'preparationPoolKey': 'same-pool',
            'preparationSharedAvailableQty': 1000,
            'preparationOwnedAvailableQty': 0,
            'preparationUncoveredBeforeSharedQty': line['requiredQty'],
          });
        }
        return data;
      },
    );
    await _openOrder(tester);
    String available(String id) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(
                  ValueKey('material-analysis-public-available-$id'),
                ),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;
    expect(available('m-b'), '950');
    await _type(tester, 'm-b', '100');
    expect(available('m-d'), '870');
    final table = _table(tester);
    table.onSelectedIdsChanged!(
      {...table.selectedIds}..remove('PREPARATION|m-b'),
    );
    await tester.pumpAndSettle();
    expect(_qty(tester, 'm-b'), '100');
    expect(available('m-d'), '970');
  });
  testWidgets('车间桶打开统一核对页，原树与数量完整且零写入', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    expect(find.text('核对并下单'), findsOneWidget);
    for (final name in ['成品A', '外购件B', '半成品C', '外购件D']) {
      expect(_inPage(name), findsOneWidget);
    }
    expect(_qty(tester, 'root-1'), '10');
    expect(_qty(tester, 'm-b'), '20');
    expect(_qty(tester, 'm-c'), '10');
    expect(_qty(tester, 'm-d'), '30');
    expect(_writes(harness), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('父件改量立即带动子孙默认量，后台预览仍提交原物料身份', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    await tester.enterText(_input('root-1'), '20');
    await tester.pump();
    expect(_qty(tester, 'm-b'), '40');
    expect(_qty(tester, 'm-c'), '20');
    expect(_qty(tester, 'm-d'), '60');
    await _preview(tester);
    final request = harness.writes.lastWhere(
      (r) => r.path.endsWith('/issue-plans/preview'),
    );
    expect((request.data as Map)['typedOutputs'], [
      {'materialLineId': 'root-1', 'qty': 20.0},
    ]);
    expect(_qty(tester, 'm-d'), '60');
    expect(_writes(harness), isEmpty);
  });

  testWidgets('中间件改量只带动本支孙件，父件和兄弟保持原值', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    await _type(tester, 'm-c', '30');
    expect(_qty(tester, 'root-1'), '10');
    expect(_qty(tester, 'm-b'), '20');
    expect(_qty(tester, 'm-c'), '30');
    expect(_qty(tester, 'm-d'), '90');
  });

  testWidgets('父件改大再改回，未手填的子孙数量原路回落', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    await _type(tester, 'root-1', '20');
    await _type(tester, 'root-1', '10');
    expect(_qty(tester, 'm-b'), '20');
    expect(_qty(tester, 'm-c'), '10');
    expect(_qty(tester, 'm-d'), '30');
  });

  testWidgets('父件改量不覆盖子件明确手填，少于需求也保留供员工决定', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    await _type(tester, 'm-b', '25');
    await _type(tester, 'root-1', '30');
    expect(_qty(tester, 'm-b'), '25');
    expect(_qty(tester, 'm-c'), '30');
    expect(_qty(tester, 'm-d'), '90');
  });

  testWidgets('连续退格重新输入父件不会累计放大子件', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    for (final value in ['2', '', '3', '30']) {
      await tester.enterText(_input('root-1'), value);
      await tester.pump();
    }
    await _preview(tester);
    expect(_qty(tester, 'm-b'), '60');
    expect(_qty(tester, 'm-d'), '90');
  });

  testWidgets('比例非法在写根计划之前阻止整批，输入不会丢失', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    await tester.enterText(_rate('m-c'), '-2');
    await tester.tap(
      find.byKey(const Key('material-preparation-order-submit')),
    );
    await tester.pumpAndSettle();
    expect(_writes(harness), isEmpty);
    expect(tester.widget<TextField>(_rate('m-c')).controller!.text, '-2');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('清空父件数量不能静默恢复旧默认值下单', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    await tester.enterText(_input('root-1'), '');
    await _preview(tester);
    await tester.tap(
      find.byKey(const Key('material-preparation-order-submit')),
    );
    await tester.pumpAndSettle();
    expect(_writes(harness), isEmpty);
    expect(_qty(tester, 'root-1'), '');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('父子比例分别保留，预览不会互相覆盖', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    await tester.enterText(_rate('root-1'), '15');
    await tester.enterText(_rate('m-c'), '25');
    await _type(tester, 'root-1', '20');
    expect(tester.widget<TextField>(_rate('root-1')).controller!.text, '15');
    expect(tester.widget<TextField>(_rate('m-c')).controller!.text, '25');
    expect(_rate('m-b'), findsNothing);
  });

  testWidgets('父行可明确撤选，选择与主表一致', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    final table = _table(tester);
    final selected = Set<String>.from(table.selectedIds)
      ..remove('PREPARATION|root-1');
    table.onSelectedIdsChanged!(selected);
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, isNot(contains('PREPARATION|root-1')));
    expect(_table(tester).selectedIds, contains('PREPARATION|m-b'));
  });

  testWidgets('明确撤选子件后再改父件，不强行恢复该子件选择', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    final table = _table(tester);
    table.onSelectedIdsChanged!(
      Set<String>.from(table.selectedIds)..remove('PREPARATION|m-b'),
    );
    await tester.pumpAndSettle();
    await _type(tester, 'root-1', '20');
    expect(_table(tester).selectedIds, isNot(contains('PREPARATION|m-b')));
    expect(_qty(tester, 'm-b'), '40');
  });

  testWidgets('核对页列与主表统一，保留需要可用还缺和追加', (tester) async {
    await _pump(tester);
    await _openOrder(tester);
    final labels = _table(tester).columns.map((c) => c.label);
    expect(
      labels,
      containsAll(['需要数量', '可用数量', '还缺数量', '下单数量', '追加下单', '生产车间', '负责人']),
    );
    expect(labels, isNot(contains('本批要用')));
  });

  testWidgets('只选父件只发根计划，下层未选不隐式提交', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    _table(tester).onSelectedIdsChanged!({'PREPARATION|root-1'});
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(_writes(harness).map((r) => r.path.split('/').last), [
      'issue-plans',
    ]);
  });

  testWidgets('父件与下层统一按依赖顺序提交，相同比例逐行保留', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    await _type(tester, 'root-1', '20');
    await _submit(tester);
    final writes = _writes(harness);
    expect(writes.first.path, endsWith('/issue-plans'));
    expect(
      writes.where((r) => r.path.endsWith('/aggregate-orders/submit')),
      hasLength(2),
    );
    final last = ((writes.last.data as Map)['groups'] as List).single as Map;
    expect(last['materialLineIds'], ['m-d']);
    expect(last['qty'], '60');
  });

  testWidgets('已下达子件使用追加列，未填数量不会重复下单', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      previousOrders: true,
    );
    await _openOrder(tester);
    expect(_input('m-b', append: true), findsOneWidget);
    expect(_qty(tester, 'm-b', append: true), '0');
    _table(tester).onSelectedIdsChanged!({
      'PREPARATION|root-1',
      'PREPARATION|m-b',
    });
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(
      _writes(
        harness,
      ).where((r) => r.path.endsWith('/aggregate-orders/submit')),
      isEmpty,
    );
  });

  testWidgets('已下单子件可单独追加，提交原行和本次增量', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      previousOrders: true,
    );
    await _openOrder(tester);
    await _type(tester, 'm-b', '5', append: true);
    _table(tester).onSelectedIdsChanged!({'PREPARATION|m-b'});
    await tester.pumpAndSettle();
    await _submit(tester);
    final write = _writes(harness).single;
    expect(write.path, endsWith('/aggregate-orders/submit'));
    final input = ((write.data as Map)['groups'] as List).single as Map;
    expect(input['materialLineIds'], ['m-b']);
    expect(input['qty'], '5');
  });

  testWidgets('直接外发委外桶也进入同一核对页，保留我方供料子件', (tester) async {
    await _pump(tester, soleComponentSubcontract: true);
    await _openOrder(tester, route: 'subcontract');
    expect(_inPage('成品A'), findsOneWidget);
    expect(_inPage('外购件B'), findsOneWidget);
    await _type(tester, 'root-1', '20');
    expect(_qty(tester, 'm-b'), '40');
    expect(_rate('root-1'), findsNothing);
  });

  testWidgets('前置自制委外显示可见车间指派，统一走制造责任', (tester) async {
    await _pump(tester, makeFirstSubcontract: true);
    await _openOrder(tester, route: 'subcontract');
    expect(_rate('root-1'), findsOneWidget);
    expect(
      find.byKey(ValueKey('material-analysis-workshop-${_group('root-1')}')),
      findsOneWidget,
    );
    expect(find.text('一车间'), findsWidgets);
  });

  testWidgets('已排满顶层仍可从车间桶追加，增量与历史量分开', (tester) async {
    final harness = await _pump(
      tester,
      topLevelIssued: true,
      childrenAlreadyOrdered: true,
      previousOrders: true,
    );
    await _openOrder(tester, issued: true);
    expect(_qty(tester, 'root-1', append: true), '0');
    await _type(tester, 'root-1', '5', append: true);
    _table(tester).onSelectedIdsChanged!({'PREPARATION|root-1'});
    await tester.pumpAndSettle();
    await _submit(tester);
    final input =
        ((_writes(harness).single.data as Map)['lines'] as List).single as Map;
    expect(input['qty'], 5);
    expect(input['publicSurplusOnly'], isTrue);
  });

  testWidgets('退出核对页不写库，草稿返回原主表仍保留', (tester) async {
    final harness = await _pump(tester);
    await _openOrder(tester);
    await _type(tester, 'm-b', '25');
    await tester.tap(find.byTooltip('返回').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-preparation-order-page')),
      findsNothing,
    );
    expect(_writes(harness), isEmpty);
  });
}

String _group(String id) =>
    'NODE|${id == 'root-1' ? 'ag-root' : 'ag-${id.substring(2)}'}|$id';
Finder _input(String id, {bool append = false}) => find.byKey(
  ValueKey(
    'material-analysis-${append ? 'append' : 'order'}-qty-${_group(id)}',
  ),
);
Finder _rate(String id) => find.descendant(
  of: find.byKey(
    ValueKey('material-analysis-overproduction-rate-${_group(id)}'),
  ),
  matching: find.byType(TextField),
);
String _qty(WidgetTester tester, String id, {bool append = false}) =>
    tester.widget<TextField>(_input(id, append: append)).controller!.text;
Finder _inPage(String name) => find.descendant(
  of: find.byKey(const Key('material-preparation-order-page')),
  matching: find.text(name),
);
MasterDataTableView<dynamic> _table(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('material-preparation-order-table')));
List<RequestOptions> _writes(_Harness harness) => harness.writes
    .where(
      (r) =>
          r.path.endsWith('/issue-plans') ||
          r.path.endsWith('/aggregate-orders/submit') ||
          r.path.endsWith('/notify'),
    )
    .toList();
Future<void> _preview(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _type(
  WidgetTester tester,
  String id,
  String value, {
  bool append = false,
}) async {
  await tester.enterText(_input(id, append: append), value);
  await _preview(tester);
}

Future<void> _openOrder(
  WidgetTester tester, {
  String route = 'workshop',
  bool issued = false,
}) async {
  final entry = find.byKey(Key('material-analysis-entry-$route'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
  if (issued) {
    final segment = find.descendant(
      of: find.byKey(const Key('material-analysis-task-state')),
      matching: find.text('进行中'),
    );
    await tester.tap(segment);
    await tester.pumpAndSettle();
  }
  final frozen = find
      .ancestor(
        of: find.text('成品A').first,
        matching: find.byType(UtenFrozenLeadingColumn),
      )
      .first;
  final check = find
      .descendant(of: frozen, matching: find.byType(Checkbox))
      .last;
  tester.widget<Checkbox>(check).onChanged!(true);
  await tester.pumpAndSettle();
  final action = find.byKey(
    Key(
      'material-analysis-bucket-action-${route == 'workshop' ? 'ready' : route}',
    ),
  );
  await tester.tap(action);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('material-preparation-order-page')),
    findsOneWidget,
  );
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('material-preparation-order-submit')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Object? _bumpVersion(Object? data, int writes) {
  if (writes <= 0) return data;
  if (data is Map<String, dynamic> && data['version'] is int) {
    return {
      ...data,
      'version': (data['version'] as int) + writes,
      'fingerprint': 'a' * 63 + '$writes',
    };
  }
  if (data is Map<String, dynamic> && data['analysis'] is Map) {
    return {
      ...data,
      'analysis': _bumpVersion(
        (data['analysis'] as Map).cast<String, dynamic>(),
        writes,
      ),
    };
  }
  return data;
}

class _Harness {
  final List<RequestOptions> writes = [];
}

/// 假后端的「下达预览 / 真实下达之后」快照：按请求里 p1 的本批数量把下层需求
/// 与还需安排量放大（与真实服务端「子件按父件计划产出量展开」同一口径）。
Map<String, dynamic> _scaledAnalysis(
  Map<String, dynamic> analysis,
  RequestOptions request,
) {
  final body = request.data;
  if (body is! Map<String, dynamic>) return analysis;
  final lines = (body['lines'] as List?)?.cast<Map<String, dynamic>>();
  final top = (lines ?? const <Map<String, dynamic>>[]).firstWhere(
    (line) => line['analysisLineId'] == 'p1',
    orElse: () => const <String, dynamic>{},
  );
  // 2026-09-21：层级表上每一行填的数量。服务端按它补齐该节点的计划产出量，
  // 于是中间层改量同样带得动它的子层——本假后端照同一口径算：半成品C 的孙层
  // 外购件D 单件用 3(相对 C)，C 填了多少，D 就是多少 × 3。
  final typed = <String, double>{
    for (final raw in (body['typedOutputs'] as List? ?? const []))
      (raw as Map)['materialLineId'] as String: (raw['qty'] as num).toDouble(),
  };
  final batch = (top['qty'] as num?)?.toDouble() ?? typed['root-1'];
  if (batch == null && typed.isEmpty) return analysis;
  return {
    ...analysis,
    'flatMaterials': [
      for (final raw in (analysis['flatMaterials'] as List))
        () {
          final material = Map<String, dynamic>.from(raw as Map);
          if (material['nodeRole'] == 'ROOT_SUPPLY') return material;
          final perProduct = (material['perProductQty'] as num).toDouble();
          final baseRequired = (material['requiredQty'] as num).toDouble();
          final baseResidual =
              (material['additionalSupplyRecommendedQty'] as num).toDouble();
          // 已有覆盖（现货 / 在途 / 已下达）原样保留，只有需求随本批数量放大。
          final covered = baseRequired - baseResidual;
          final fromTop = batch == null ? baseRequired : batch * perProduct;
          // 与服务端 parentPlannedOutput 同口径：父件的计划产出量是「祖先算出来
          // 的净需求」与「这一层自己填的数量」取大，所以 typedOutputs 只会把
          // 子层带大，不会把它按过期的旧值压小。
          final parentTyped = material['materialLineId'] == 'm-d'
              ? typed['m-c']
              : null;
          final required = parentTyped != null && parentTyped * 3 > fromTop
              ? parentTyped * 3
              : fromTop;
          final residual = (required - covered).clamp(0.0, double.infinity);
          return material
            ..['requiredQty'] = required
            ..['shortageQty'] = residual
            ..['demandSupplyGapQty'] = residual
            ..['additionalSupplyRecommendedQty'] = residual;
        }(),
    ],
  };
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool childrenAlreadyOrdered = false,
  bool previousOrders = false,
  bool topLevelIssued = false,
  bool subcontractChildIssued = false,
  bool soleComponentSubcontract = false,
  bool makeFirstSubcontract = false,
  Map<String, dynamic> Function(Map<String, dynamic>)? mutate,
}) async {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  var persisted = makeFirstSubcontract
      ? _makeFirstSubcontractAnalysis()
      : soleComponentSubcontract
      ? _soleComponentSubcontractAnalysis()
      : _analysis(
          childrenAlreadyOrdered: childrenAlreadyOrdered,
          previousOrders: previousOrders,
          topLevelIssued: topLevelIssued,
          subcontractChildIssued: subcontractChildIssued,
        );
  if (mutate != null) persisted = mutate(persisted);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (request.method != 'GET') harness.writes.add(request);
        final base = persisted;
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/default-workshops' => [
            for (final goods in ['g-a', 'g-c', 'g-s'])
              {
                'goodsId': goods,
                'departmentId': 'dept-1',
                'departmentName': '一车间',
                'responsibleEmployeeId': 'emp-1',
                'responsibleEmployeeName': '张三',
              },
          ],
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          '/production/material-analyses/analysis-1' => base,
          '/production/material-analyses/analysis-1/notify' => base,
          // 下达预览：真实服务端按同一套代码跑一遍再回滚，返回「下达之后」快照。
          '/production/material-analyses/analysis-1/issue-plans/preview' =>
            _scaledAnalysis(base, request),
          '/production/material-analyses/analysis-1/issue-plans' => {
            'analysis': _scaledAnalysis(base, request),
            'plans': [
              {'planId': 'plan-1', 'planNo': 'PP-1', 'status': 'DRAFT'},
            ],
          },
          '/production/material-analyses/analysis-1/aggregate-orders/preview' =>
            _aggregatePreview(base, request.data as Map),
          '/production/material-analyses/analysis-1/aggregate-orders/submit' =>
            _aggregateWrite(base, request.data as Map),
          _ => <Object>[],
        };
        // 真实服务端只有真的写了东西才会重建快照；预览不算写、不换版本。
        final realWrites = harness.writes
            .where((r) => !r.path.endsWith('/preview'))
            .length;
        if (request.method != 'GET' && !request.path.endsWith('/preview')) {
          if (data is Map && data['analysis'] is Map) {
            persisted = Map<String, dynamic>.from(data['analysis'] as Map);
          } else if (data is Map<String, dynamic> &&
              data['analysisId'] != null) {
            persisted = data;
          }
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: _bumpVersion(data, realWrites),
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        purchaseRepositoryProvider.overrideWith(
          (ref, type) => PurchaseRepository(api, type),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionMaterialAnalysisOverSupply,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  harness.writes.clear();
  return harness;
}

Map<String, dynamic> _aggregatePreview(
  Map<String, dynamic> analysis,
  Map<dynamic, dynamic> body,
) => {
  'analysisId': analysis['analysisId'],
  'version': analysis['version'],
  'fingerprint': analysis['fingerprint'],
  'previewFingerprint': 'c' * 64,
  'analysis': analysis,
  'groups': [
    for (final group in (body['groups'] as List).cast<Map<String, dynamic>>())
      {
        'clientGroupKey': group['clientGroupKey'],
        'route': group['route'],
        'goodsId': group['clientGroupKey'],
        'requestedQty': double.parse(group['qty'].toString()),
        'sources': [
          for (final id in group['materialLineIds'] as List)
            {
              'materialLineId': id,
              'allocatedQty': double.parse(
                ((group['sourceRequestedQtyByMaterialLineId'] as Map)[id])
                    .toString(),
              ),
            },
        ],
        'sharedBomChildren': <Object>[],
      },
  ],
};

Map<String, dynamic> _aggregateWrite(
  Map<String, dynamic> analysis,
  Map<dynamic, dynamic> body,
) {
  final next = jsonDecode(jsonEncode(analysis)) as Map<String, dynamic>;
  for (final group in (body['groups'] as List).cast<Map<String, dynamic>>()) {
    for (final id in group['materialLineIds'] as List) {
      final material = (next['flatMaterials'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m['materialLineId'] == id);
      final qty = double.parse(
        ((group['sourceRequestedQtyByMaterialLineId'] as Map)[id]).toString(),
      );
      material['aggregatePreparation'] = {
        'requiredQty': material['requiredQty'],
        'orderedQty': qty,
        'allocatedOrderedQty': qty,
        'planningUncoveredQty': 0,
        'netShortageQty': 0,
        'targetMaterialLineIds': <String>[],
        'actionable': true,
      };
      material['additionalSupplyRecommendedQty'] = 0;
      material['netShortageQty'] = 0;
    }
  }
  return {'analysis': next, 'batches': <Object>[]};
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

/// V581 变体：成品A 改成「只有一个叶子子件」的委外件——树顶走委外下达
/// （notify SUBCONTRACT），那颗子件仍要我方采购出来，所以仍进「跟父件一起办」。
Map<String, dynamic> _soleComponentSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    {
      ...(analysis['products'] as List).first as Map<String, dynamic>,
      'canSchedule': false,
    },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      actionable: true,
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
  ];
  return analysis;
}

/// 有自制子层的顶层委外件（ADR-062 先自制后通知）：成品A 路线为委外，BOM 上
/// 还有我方要备的外购件B。ADR-099 起这类行（含顶层供给行）直接走 issue-plans
/// 的 ARRANGE 段，不再走「整量接管的通知通道」。
Map<String, dynamic> _makeFirstSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    {
      ...(analysis['products'] as List).first as Map<String, dynamic>,
      'canSchedule': false,
    },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      actionable: true,
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
    _material(
      id: 'm-e',
      name: '外购件E',
      goodsId: 'g-e',
      level: 1,
      nodeKey: 'ne',
      perProductQty: 1,
      requiredQty: 10,
      route: 'BUY',
      actionGroupKey: 'ag-e',
    ),
  ];
  return analysis;
}

/// [previousOrders]：B 已下采购申请 PR-0001（采购还没处理，服务端给
/// growableLineQty）、D 已下 PR-0002 且已在处理（无 growableLineQty）。
/// [topLevelIssued]：成品A 的需求已全部转入计划（剩余 0、不可再按需求排产），
/// 但服务端允许再追加一批纯公共备货产出（canIssueSurplus）。
/// [subcontractChildIssued]：再挂一个「有自制子层的委外件 S」，它已经建过前置
/// 自制任务（锚点 sub-anchor 剩余 0、仍可再下一批公共备货产出）。
Map<String, dynamic> _analysis({
  required bool childrenAlreadyOrdered,
  bool previousOrders = false,
  bool topLevelIssued = false,
  bool subcontractChildIssued = false,
}) => {
  'overproductionDefaults': {'g-a': 0, 'g-c': 0.1, 'g-s': 0},
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'GENERATE_PLAN',
    'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'p1',
      'sourceType': 'STOCK',
      'rootMaterialLineId': 'root-1',
      'salesOrderItemId': 'soi-1',
      'salesOrderNo': 'SO-0001',
      'goodsId': 'g-a',
      'goodsCode': 'A-001',
      'goodsName': '成品A',
      'unitName': '件',
      'requestedQty': 10,
      'remainingQty': topLevelIssued ? 0 : 10,
      'readyNowQty': 0,
      'canSchedule': !topLevelIssued,
      'maxSchedulableQty': topLevelIssued ? 0 : 10,
      'hasProductionMaterialChildren': true,
      if (topLevelIssued) ...{
        'submittedQty': 10,
        'approvedQty': 10,
        'issuedPlanQty': 10,
        'canIssueSurplus': true,
        'scheduleBlockedReason': '当前分析需求已全部转入生产计划',
        'planExecutionStatus': 'IN_PROGRESS',
        'latestPlanId': 'plan-1',
        'planExecutionWorkshopId': 'dept-1',
        'planExecutionWorkshopName': '一车间',
        'planExecutionResponsibleId': 'emp-1',
        'planExecutionResponsibleName': '张三',
        'latestPlanNo': 'PP-1',
        'planExecutionPlannedQty': 10,
        'planExecutionInboundQty': 0,
      },
    },
    if (subcontractChildIssued)
      {
        'analysisLineId': 'sub-anchor',
        'sourceType': 'SUBCONTRACT_MAKE',
        'parentAnalysisLineId': 'p1',
        'goodsId': 'g-s',
        'goodsCode': 'g-s-code',
        'goodsName': '委外件S',
        'unitName': '个',
        'requestedQty': 10,
        'submittedQty': 10,
        'approvedQty': 10,
        'remainingQty': 0,
        'issuedPlanQty': 10,
        'canIssueSurplus': true,
        'canSchedule': false,
        'maxSchedulableQty': 0,
        'scheduleBlockedReason': '当前分析需求已全部转入生产计划',
        'readyNowQty': 0,
        'planExecutionStatus': 'WAITING',
        'latestPlanId': 'plan-s',
        'planExecutionWorkshopId': 'dept-1',
        'planExecutionWorkshopName': '一车间',
        'planExecutionResponsibleId': 'emp-1',
        'planExecutionResponsibleName': '张三',
        'planExecutionPlannedQty': 10,
      },
  ],
  'flatMaterials': [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
      covered: childrenAlreadyOrdered,
      previousOrder: previousOrders
          ? (documentNo: 'PR-0001', qty: 20.0, growable: true)
          : null,
    ),
    _material(
      id: 'm-c',
      name: '半成品C',
      goodsId: 'g-c',
      level: 1,
      nodeKey: 'nc',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      actionGroupKey: 'ag-c',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-d',
      name: '外购件D',
      goodsId: 'g-d',
      level: 2,
      nodeKey: 'nc/nd',
      parentNodeKey: 'nc',
      perProductQty: 3,
      requiredQty: 30,
      route: 'BUY',
      actionGroupKey: 'ag-d',
      covered: childrenAlreadyOrdered,
      previousOrder: previousOrders
          ? (documentNo: 'PR-0002', qty: 30.0, growable: false)
          : null,
    ),
    if (subcontractChildIssued) ...[
      _material(
        id: 'm-s',
        name: '委外件S',
        goodsId: 'g-s',
        level: 1,
        nodeKey: 'ns',
        perProductQty: 1,
        requiredQty: 10,
        route: 'SUBCONTRACT',
        actionGroupKey: 'ag-s',
        covered: true,
        planAnchorAnalysisLineId: 'sub-anchor',
      ),
      // S 的子层：有它 S 才算「要先自制目标件再发外」。
      _material(
        id: 'm-s-child',
        name: '委外子件SC',
        goodsId: 'g-sc',
        level: 2,
        nodeKey: 'ns/nsc',
        parentNodeKey: 'ns',
        perProductQty: 1,
        requiredQty: 10,
        route: 'BUY',
        actionGroupKey: 'ag-sc',
        covered: true,
      ),
    ],
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _material({
  required String id,
  required String name,
  required String goodsId,
  required int level,
  required String nodeKey,
  required double perProductQty,
  required double requiredQty,
  required String route,
  required String actionGroupKey,
  String? parentNodeKey,
  String nodeRole = 'BOM_COMPONENT',
  bool covered = false,
  String? subcontractOutboundForm,
  bool? actionable,
  ({String documentNo, double qty, bool growable})? previousOrder,
  String? planAnchorAnalysisLineId,
}) => {
  'subcontractOutboundForm': subcontractOutboundForm,
  'planAnchorAnalysisLineId': ?planAnchorAnalysisLineId,
  if (previousOrder != null)
    'notifiedTargets': [
      {
        'target': route,
        'actionId': 'act-$id',
        'documentType': 'PURCHASE_REQUEST',
        'documentId': 'doc-$id',
        'documentNo': previousOrder.documentNo,
        'status': 'CREATED',
        'allocatedQty': previousOrder.qty,
        if (previousOrder.growable) 'growableLineQty': previousOrder.qty,
      },
    ],
  'materialLineId': id,
  'analysisLineId': 'p1',
  'nodeRole': nodeRole,
  'nodeKey': nodeKey,
  'parentNodeKey': parentNodeKey,
  'goodsId': goodsId,
  'goodsCode': '$goodsId-code',
  'goodsName': name,
  'unitName': '件',
  'level': level,
  'actionable': actionable ?? level > 0,
  'actionGroupKey': actionGroupKey,
  'materialKey': goodsId,
  'perProductQty': perProductQty,
  'requiredQty': requiredQty,
  'availableQty': covered ? requiredQty : 0,
  'allocatedAvailableQty': covered ? requiredQty : 0,
  'shortageQty': covered ? 0 : requiredQty,
  'demandSupplyGapQty': covered ? 0 : requiredQty,
  'additionalSupplyRecommendedQty': covered ? 0 : requiredQty,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'warehouseBreakdown': <Object>[],
};
