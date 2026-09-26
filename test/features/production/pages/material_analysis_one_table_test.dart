// ADR-102「一张表」：把分桶详情页与「父件 + 下层一起下单」弹窗的能力搬进主
// 物料表之后，这张表上新增的行为由本文件守着。
//
// 守的是**口径**不是像素：哪一行能填数、填的是「下单数量」还是「追加下单」、
// 哪一行的办理按钮该灰、没确认路线时表现成什么样。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _permissions = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisRoute,
  Perm.productionMaterialAnalysisNotify,
  Perm.productionMaterialAnalysisCrossReallocate,
};

/// 已下达的行要追加(还需安排为 0 却再下)属超量, 勾选 / 提交都要超量权限
/// (服务端 allowedActions 也要带 OVER_SUPPLY, 见 _pump 的 overSupply)。
const _overSupplyPermissions = {
  ..._permissions,
  Perm.productionMaterialAnalysisOverSupply,
};

/// 提交单元身份：`NODE|<actionGroupKey>|<materialLineId>`。
String _groupKey(String line) => 'NODE|a-$line|$line';

String _qtyText(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Finder _orderQty(String line) =>
    find.byKey(ValueKey('material-analysis-order-qty-${_groupKey(line)}'));
Finder _appendQty(String line) =>
    find.byKey(ValueKey('material-analysis-append-qty-${_groupKey(line)}'));
Finder _sourceRequired(String rowKey) =>
    find.byKey(ValueKey('material-analysis-source-required-$rowKey'));
String _sourceRequiredText(WidgetTester tester, String rowKey) =>
    tester.widget<Text>(_sourceRequired(rowKey)).data!;
Finder _transferButton(String line) => find.byKey(
  ValueKey('material-analysis-handle-transfer-${_groupKey(line)}'),
);
Finder _issueButton(String line) =>
    find.byKey(ValueKey('material-analysis-handle-issue-${_groupKey(line)}'));

bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<InkWell>(finder).onTap != null;

/// 这一行的勾选框此刻勾没勾(行必须有勾选框, 没有就直接失败)。
///
/// 横滚时行首勾选框会有一份「钉在视口左缘」的冻结副本(UtenFrozenLeadingColumn
/// 复用同一个 selectionCell，设计如此)：加了「可用数量」列后测试里第一次出现
/// 横向滚动，同一行能找到两份 Checkbox——值必然一致，逐份断言而不是强求唯一。
bool _rowChecked(WidgetTester tester, String line) {
  final boxes = find
      .descendant(
        of: find.byKey(ValueKey('material-table-row-$line')),
        matching: find.byType(Checkbox),
      )
      .evaluate();
  expect(boxes, isNotEmpty, reason: '行 $line 没有勾选框');
  return boxes.every((box) => (box.widget as Checkbox).value == true);
}

/// 物料行首列的勾选框(顶层产品行的 key 是 material-bom-product-<产品行 id>)。
/// 取最后一份：横滚出现冻结副本时原件已滚出视口，钉在左缘的副本才是可点的。
Finder _rowCheckbox(String line) => find
    .descendant(
      of: find.byKey(ValueKey('material-table-row-$line')),
      matching: find.byType(Checkbox),
    )
    .last;

/// 敲键后停手 200ms 那次整页刷新(勾选框 / 底部按钮 / 底色都在那一拍才变)。
/// pumpAndSettle 只等有帧要画, 不等定时器, 所以要明确推过 200ms; 悬浮的批量
/// 按钮组随后还要一两帧才落位, 再 settle 一次。
Future<void> _settleRebuild(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

/// 去抖 300ms 后服务端那趟预览回来并装上(同样是定时器驱动, 要明确推时间)。
Future<void> _settlePreview(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder _productCheckbox(String product) => find
    .descendant(
      of: find.byKey(ValueKey('material-bom-product-$product')),
      matching: find.byType(Checkbox),
    )
    .last;

/// 勾上一行：直接拨勾选框的 onChanged——吸顶表头与视口高度会让个别行的勾选框在
/// 测试里点不着，而这里要验的是勾选之后的编排，不是点击命中。
/// 横滚时同一行有两份 Checkbox(冻结副本，见 [_rowCheckbox])，取最后一份。
Future<void> _check(WidgetTester tester, Finder checkbox) async {
  if (tester.widget<Checkbox>(checkbox.last).value == true) return;
  await _toggle(tester, checkbox);
}

Future<void> _toggle(WidgetTester tester, Finder checkbox) async {
  tester.widget<Checkbox>(checkbox.last).onChanged!(true);
  // 拨完先出一帧：勾选框的回调捕获的是各自构建时的选中集，连拨两下不出帧，
  // 第二下会拿旧集合把第一下撤掉——那是测试写法的坑，不是页面的。
  await tester.pump();
}

bool _nodeSelected(WidgetTester tester, String line) => tester
    .widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    )
    .selectedIds
    .contains(_groupKey(line));

Future<void> _onlyRoot(WidgetTester tester) async {
  await _check(tester, _productCheckbox('product-1'));
  final ids = tester
      .widget<MasterDataTableView<dynamic>>(
        find.byKey(const Key('material-analysis-material-table')),
      )
      .selectedIds
      .toList();
  for (final key in ids.where((key) => key.startsWith('NODE|'))) {
    final line = key.split('|').last;
    if (line == 'm-root') continue;
    final finder = _rowCheckbox(line);
    if (finder.evaluate().isNotEmpty &&
        tester.widget<Checkbox>(finder).value == true) {
      await _toggle(tester, finder);
    }
  }
}

/// 「下单(N)」→ 确认框里点「下达」，等编排跑完；期间发出的请求记在 [requests]。
Future<void> _submitSelected(WidgetTester tester) async {
  requests.clear();
  await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
  );
  // 假后端可能按 delayMs 延迟应答, 期间没有动画帧, pumpAndSettle 会提前返回;
  // 先把假时钟推够几段的量, 再等落定。
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// 编排里真正落库的那些请求(采购/委外 notify、车间 issue-plans)，按发出顺序。
List<({String method, String path, Map<String, dynamic>? body})> _submits() => [
  for (final request in requests)
    if (request.path.endsWith('/notify') ||
        request.path.endsWith('/issue-plans'))
      request,
];

/// 某段 notify 请求里某个操作组送出的数量。
double? _qtyOf(
  ({String method, String path, Map<String, dynamic>? body}) request,
  String actionGroupKey,
) {
  for (final raw in (request.body?['quantities'] as List? ?? const [])) {
    final quantity = raw as Map;
    if (quantity['actionGroupKey'] == actionGroupKey) {
      return (quantity['qty'] as num).toDouble();
    }
  }
  return null;
}

/// 已下达行「下单数量」格的锁定提示：累计已下单多少。
Finder _issuedTooltip(String qty) => find.byWidgetPredicate(
  (widget) =>
      widget is Tooltip && widget.message?.startsWith('累计已下单 $qty。') == true,
);

/// 数量框此刻是不是被 RequiredCellFrame 描了红边(它把红边交给最近那层 Theme 的
/// inputDecorationTheme 来画)。
bool _framedRed(WidgetTester tester, Finder field) {
  final theme = tester.widget<Theme>(
    find.ancestor(of: field, matching: find.byType(Theme)).first,
  );
  final border = theme.data.inputDecorationTheme.enabledBorder;
  return border is OutlineInputBorder &&
      border.borderSide.color == theme.data.colorScheme.error;
}

void main() {
  testWidgets('需要数量保留显式零，旧响应缺基线时不拿动态备料量冒充', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _fixtureMaterial(data, 'm-2')
          ..['sourceRequiredQty'] = 0
          ..['requiredQty'] = 2500;
        _fixtureMaterial(data, 'm-3')
          ..remove('sourceRequiredQty')
          ..['requiredQty'] = 3000;
        return data;
      },
    );
    expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '0');
    expect(_sourceRequiredText(tester, 'MATERIAL|m-3'), '—');
  });

  testWidgets('纯来源产品用原始请求量，已排满的自制锚点仍显示来源物料基线', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _withIssuedMakeRow(data);
        final product = (data['products'] as List).first as Map;
        product
          ..['rootMaterialLineId'] = null
          ..['requestedQty'] = 1000
          ..['remainingQty'] = 0;
        (data['flatMaterials'] as List).removeWhere(
          (raw) => (raw as Map)['materialLineId'] == 'm-root',
        );
        _fixtureMaterial(data, 'm-7')['sourceRequiredQty'] = 300;
        return data;
      },
    );
    expect(_sourceRequiredText(tester, 'PRODUCT|product-1'), '1000');
    expect(_sourceRequiredText(tester, 'MATERIAL|m-7'), '300');
    expect(_sourceRequired('PRODUCT|anchor-7'), findsNothing);
  });

  testWidgets('按物料汇总累加各路径原始需要量，不累加放大的实际备料量', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final original = _fixtureMaterial(data, 'm-2')
          ..['sourceRequiredQty'] = 300
          ..['requiredQty'] = 6000;
        (data['flatMaterials'] as List).add({
          ...original,
          'materialLineId': 'm-2-copy',
          'nodeKey': 'n-m-2-copy',
          'actionGroupKey': 'a-m-2-copy',
          'sourceRequiredQty': 500,
          'requiredQty': 9000,
        });
        return data;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    expect(_sourceRequiredText(tester, 'AGGREGATE|g-m-2|本色|unit-1'), '800');
  });

  testWidgets('顶层缺指派仍可显式全选子树，部分选择再次点父级补全', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        data['flatMaterials'] = [
          for (final line in ['m-root', 'm-6', 'm-2'])
            _fixtureMaterial(data, line),
        ];
        return data;
      },
    );
    final parent = _productCheckbox('product-1');
    expect(tester.widget<Checkbox>(parent).onChanged, isNotNull);
    await _check(tester, parent);
    expect(tester.widget<Checkbox>(parent).value, isTrue);
    await tester.ensureVisible(
      find.byKey(const ValueKey('material-table-row-m-6')),
    );
    await tester.pumpAndSettle();
    expect(_rowChecked(tester, 'm-6'), isTrue);
    expect(_rowChecked(tester, 'm-2'), isTrue);
    await _toggle(tester, _rowCheckbox('m-2'));
    expect(tester.widget<Checkbox>(parent).value, isNull);
    await tester.enterText(_orderQty('m-root'), '1500');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-2'), isFalse, reason: '自动数量联动保留显式取消');
    await _check(tester, parent);
    expect(_rowChecked(tester, 'm-2'), isTrue, reason: '新的父级显式全选覆盖旧取消');
    expect(tester.widget<Checkbox>(parent).value, isTrue);
    await _toggle(tester, parent);
    expect(_rowChecked(tester, 'm-6'), isFalse);
    expect(_rowChecked(tester, 'm-2'), isFalse);
  });

  testWidgets('同料三路径已下达汇总显示3000且物理缺口不变，来源展开只读', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        final source = _fixtureMaterial(data, 'm-6');
        data['flatMaterials'] = [
          _fixtureMaterial(data, 'm-root'),
          for (var index = 0; index < 3; index++)
            {
              ...source,
              'materialLineId': 'same-make-$index',
              'nodeKey': 'same-node-$index',
              'actionGroupKey': 'same-action-$index',
              'planAnchorAnalysisLineId': 'same-anchor-$index',
              'requiredQty': 1000,
              'sourceRequiredQty': 1000,
              'shortageQty': 1000,
              'additionalSupplyRecommendedQty': 0,
            },
        ];
        (data['products'] as List).addAll([
          for (var index = 0; index < 3; index++)
            {
              'analysisLineId': 'same-anchor-$index',
              'sourceType': 'MAKE_COMPONENT',
              'parentAnalysisLineId': 'product-1',
              'goodsId': source['goodsId'],
              'requestedQty': 1000,
              'approvedQty': 1000,
              'issuedPlanQty': 1000,
              'remainingQty': 0,
              'canSchedule': false,
              'canIssueSurplus': true,
            },
        ]);
        return data;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    const aggregate = 'g-m-6|本色|unit-1';
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('material-aggregate-order-$aggregate')),
          )
          .data,
      '3000',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('material-aggregate-qty-$aggregate')),
          )
          .controller!
          .text,
      '0',
    );
    await tester.tap(
      find.byKey(const ValueKey('material-table-toggle-AGGREGATE|$aggregate')),
    );
    await tester.pumpAndSettle();
    final sourceRow = find.byKey(
      const ValueKey('material-table-row-same-make-0'),
    );
    expect(sourceRow, findsOneWidget);
    expect(
      find.descendant(of: sourceRow, matching: find.byType(Checkbox)),
      findsNothing,
    );
    expect(
      find.descendant(of: sourceRow, matching: find.byType(TextField)),
      findsNothing,
    );
  });

  testWidgets('已下单的汇总物料行：下单数量锁成🔒累计已下单，不再是无锁裸文本(2026-09-25)', (tester) async {
    await _pump(tester);
    // m-3 已有下游申请（allocated 800）：切到「按物料汇总」视图，这一物料的
    // 下单数量必须是锁定样式（锁图标 + 累计已下单），裸文本会被读成「没锁
    // 住、还能改」（2026-09-25 用户实机误读）。
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final orderText = find.byKey(
      const ValueKey('material-aggregate-order-g-m-3|本色|unit-1'),
    );
    expect(orderText, findsOneWidget);
    expect(
      find.byIcon(Icons.lock_outline_rounded),
      findsWidgets,
      reason: '已下单的汇总行下单数量必须带锁图标',
    );
  });

  testWidgets('提交返回和重新打开的快照备料量增长时，原始需要数量保持不变', (tester) async {
    Map<String, dynamic>? persisted;
    await _pump(
      tester,
      afterWrite: (data) {
        _fixtureMaterial(data, 'm-2')['requiredQty'] = 2500;
        persisted = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        return data;
      },
    );
    expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '1000');
    await _check(tester, _rowCheckbox('m-2'));
    await _submitSelected(tester);
    expect(persisted, isNotNull);
    expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '1000');
    await _pump(tester, mutate: (_) => persisted!);
    expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '1000');
  });

  testWidgets('汇总3100公开公共100，切产品锁住参与来源，撤销恢复原数', (tester) async {
    await _pump(
      tester,
      overSupply: true,
      permissions: _overSupplyPermissions,
      mutate: _threeSharedBuySources,
      aggregatePreview: _sharedAggregatePreview,
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
    );
    await tester.enterText(field, '3100');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    // 2026-09-25 用户口径：下单数量格下面不再显示任何提示（含公共备货分解）。
    expect(find.textContaining('公共备货'), findsNothing);
    expect(find.text('待核对来源分配'), findsNothing);
    final sent = requests
        .lastWhere(
          (request) => request.path.endsWith('/aggregate-orders/preview'),
        )
        .body!;
    expect(_records(sent['groups']).single['qty'], '3100');
    expect(
      (_records(sent['groups']).single['materialLineIds'] as List).toSet(),
      {'shared-0', 'shared-1', 'shared-2'},
    );
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    expect(_orderQty('shared-0'), findsNothing, reason: '汇总来源不能再用旧输入重复改量');
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(_submits(), isEmpty, reason: '旧按产品管道不能重复下汇总草稿来源');
    await tester.tap(find.byKey(const Key('material-aggregate-cancel-drafts')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤销草稿'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_qtyText(tester, _orderQty('shared-0')), '1000');
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '3000');
  });

  testWidgets('汇总冲突刷新删除一个来源时保留3100总量并可撤销，不因身份缺失崩页', (tester) async {
    late Map<String, dynamic> live;
    await _pump(
      tester,
      overSupply: true,
      permissions: _overSupplyPermissions,
      mutate: (data) => live = _threeSharedBuySources(data),
      aggregatePreview: _sharedAggregatePreview,
      failOn: const {'/aggregate-orders/submit': 409},
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
    );
    await tester.enterText(field, '3100');
    await _settlePreview(tester);
    (live['flatMaterials'] as List).removeWhere(
      (raw) => (raw as Map)['materialLineId'] == 'shared-2',
    );
    live['version'] = 4;
    live['fingerprint'] = 'concurrent-refresh';
    await _submitSelected(tester);
    expect(tester.widget<TextField>(field).controller!.text, '3100');
    // 来源被删后草稿仍保留全部三个来源：提示小字已按 2026-09-25 口径退役，
    // 改从下一趟预览请求断言来源集合没丢。
    expect(find.textContaining('本次保留'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('material-aggregate-cancel-drafts')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤销草稿'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '2000');
  });

  testWidgets('汇总下单一次3100且失败重试不丢总量或换幂等键', (tester) async {
    final failures = <String, int>{'/aggregate-orders/submit': 503};
    await _pump(
      tester,
      overSupply: true,
      permissions: _overSupplyPermissions,
      mutate: _threeSharedBuySources,
      aggregatePreview: _sharedAggregatePreview,
      aggregateSubmit: _sharedAggregateSubmit,
      failOn: failures,
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
    );
    await tester.enterText(field, '3100');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final first = requests
        .singleWhere(
          (request) => request.path.endsWith('/aggregate-orders/submit'),
        )
        .body!;
    expect(_records(first['groups']).single['qty'], '3100');
    expect(first['previewFingerprint'], 'c' * 64);
    expect(tester.widget<TextField>(field).controller!.text, '3100');
    failures.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    final writes = requests
        .where((request) => request.path.endsWith('/aggregate-orders/submit'))
        .toList();
    expect(writes, hasLength(2));
    expect(writes.last.body, first);
    expect(_submits(), isEmpty);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('material-aggregate-order-g-m-2|本色|unit-1'),
            ),
          )
          .data,
      '3100',
    );
  });

  testWidgets('按产品视图全选下单：跨产品同料自动改走汇总通道合并，顶层照常逐产品', (tester) async {
    await _pump(
      tester,
      overSupply: true,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return _threeSharedBuySources(data);
      },
      defaultWorkshops: _workshopDefaultsFor(const [
        'parent-0',
        'parent-1',
        'parent-2',
      ]),
      aggregatePreview: _sharedAggregatePreview,
      aggregateSubmit: _sharedAggregateSubmit,
    );
    // 默认按产品视图全选：3 个顶层产品 + 各自一条同料采购行(同货品/颜色/单位/BUY)。
    for (var i = 0; i < 3; i++) {
      await _check(tester, _productCheckbox('product-$i'));
    }
    await tester.pumpAndSettle();
    requests.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    // 主确认框要说明同料将合并，不再各下各的。
    expect(find.textContaining('1 种物料在多个产品'), findsOneWidget);
    expect(find.textContaining('本次跳过'), findsNothing);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    // 一次确认全部下达(用户口径 2026-09-25「直接弹一次是否确认」)：汇总段不再
    // 逐轮弹自己的确认框——主确认框之后不应再出现任何 AlertDialog。
    expect(find.byType(AlertDialog), findsNothing);

    // 顶层照常走按产品通道：一次 issue-plans 带 3 条顶层 planDrafts。
    final plans = _submits()
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(plans, hasLength(1));
    final lines = plans.single.body?['lines'] as List;
    expect(
      lines.map((line) => (line as Map)['analysisLineId']),
      unorderedEquals(['product-0', 'product-1', 'product-2']),
    );
    // 同料采购行不再逐行走 notify。
    expect(
      _submits().where((request) => request.path.endsWith('/notify')),
      isEmpty,
    );
    // 汇总通道一次提交一组三来源、总量 3000。
    final writes = requests
        .where((request) => request.path.endsWith('/aggregate-orders/submit'))
        .toList();
    expect(writes, hasLength(1));
    final group = _records(writes.single.body!['groups']).single;
    expect((group['materialLineIds'] as List), hasLength(3));
    expect(
      group['materialLineIds'],
      containsAll(<String>['shared-0', 'shared-1', 'shared-2']),
    );
    expect(group['qty'], '3000');
    expect(group['route'], 'BUY');
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('只缺生产车间/负责人的行：必填格实时红框，下单拦下滚动定位，不给提交', (tester) async {
    await _pump(
      tester,
      overSupply: true,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return _threeSharedBuySources(data);
      },
      // 顶层(自制)两格必填且没有任何默认：格子必须实时描红。
      aggregatePreview: _sharedAggregatePreview,
      aggregateSubmit: _sharedAggregateSubmit,
    );
    // 必填红框：生产车间/负责人格为空即描红(RequiredCellFrame 同款主题红边)。
    final rootWorkshop = find.byKey(
      ValueKey('material-analysis-workshop-${_groupKey('root-0')}'),
    );
    final rootWorker = find.byKey(
      ValueKey('material-analysis-worker-${_groupKey('root-0')}'),
    );
    expect(_framedRed(tester, rootWorkshop), isTrue);
    expect(_framedRed(tester, rootWorker), isTrue);
    for (var i = 0; i < 3; i++) {
      await _check(tester, _productCheckbox('product-$i'));
    }
    await tester.pumpAndSettle();
    requests.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 必填没填完不给下单：不弹任何确认框(与上一个用例「带默认车间即放行」对照)，
    // 一个写请求都不发；红框格原样留着让人填。
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(_submits(), isEmpty);
    expect(
      requests.where(
        (request) => request.path.endsWith('/aggregate-orders/submit'),
      ),
      isEmpty,
    );
    expect(_framedRed(tester, rootWorkshop), isTrue);
  });

  for (final scenario in [
    (manual: false, retained: false),
    (manual: true, retained: false),
    (manual: false, retained: true),
  ]) {
    testWidgets(
      '汇总DAG同料跨深度，桥接去重与失败续做 ${scenario.manual}/${scenario.retained}',
      (tester) async {
        final failures = <String, int>{};
        var writes = 0;
        await _pump(
          tester,
          permissions: {
            ..._permissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          mutate: _aggregateDagAnalysis,
          aggregatePreview: _aggregateDagPreview,
          aggregateSubmit: (body, data) {
            final result = _aggregateDagSubmit(
              body,
              data,
              retainOriginal: scenario.retained,
            );
            if (++writes == 1) failures['/aggregate-orders/submit'] = 503;
            return result;
          },
          failOn: failures,
          defaultWorkshops: [
            for (final goods in ['g-h', 'g-p'])
              {
                'goodsId': goods,
                'departmentId': 'ws',
                'departmentName': '注塑车间',
                'workerId': 'worker',
                'workerName': '负责人',
              },
          ],
        );
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-material')),
        );
        await tester.pumpAndSettle();
        for (final goods in ['h', 'p', 'raw']) {
          await _check(
            tester,
            find.descendant(
              of: find.byKey(ValueKey('material-aggregate-g-$goods|本色|unit-1')),
              matching: find.byType(Checkbox),
            ),
          );
        }
        if (scenario.manual) {
          await tester.enterText(
            find.byKey(
              const ValueKey('material-aggregate-qty-g-raw|本色|unit-1'),
            ),
            '7',
          );
          await _settlePreview(tester);
        }
        requests.clear();
        await tester.tap(
          find.byKey(const Key('material-analysis-submit-orders')),
        );
        await tester.pumpAndSettle();
        await _confirmAggregateRound(tester);
        final first = requests
            .where((r) => r.path.endsWith('/aggregate-orders/submit'))
            .single;
        expect(_records(first.body!['groups']).single['materialLineIds'], [
          'h',
        ]);
        expect(
          find.textContaining('确认下达'),
          findsOneWidget,
          reason: '第二轮是P，M不能因较浅来源提前办理',
        );
        await _confirmAggregateRound(tester);
        final failed = requests
            .where((r) => r.path.endsWith('/aggregate-orders/submit'))
            .last
            .body!;
        expect(_records(failed['groups']).single['materialLineIds'], [
          'shared-p',
        ]);
        failures.clear();
        await tester.tap(
          find.byKey(const Key('material-analysis-submit-orders')),
        );
        await tester.pumpAndSettle();
        final afterRetry = requests
            .where((r) => r.path.endsWith('/aggregate-orders/submit'))
            .toList();
        expect(afterRetry, hasLength(3));
        expect(afterRetry.last.body, failed, reason: '续做原样重试第二轮，不重下H');
        await _confirmAggregateRound(tester);
        final all = requests
            .where((r) => r.path.endsWith('/aggregate-orders/submit'))
            .toList();
        expect(all, hasLength(4));
        final raw = (all.last.body!['groups'] as List).single as Map;
        expect((raw['materialLineIds'] as List).toSet(), {
          'shared-raw-direct',
          'shared-raw-deep',
          if (scenario.retained) 'raw-direct',
        });
        expect(
          raw['qty'],
          scenario.manual
              ? '7'
              : scenario.retained
              ? '3'
              : '2',
          reason: '手填总量不丢，保留的旧责任和新canonical各计一次',
        );
        expect(_submits(), isEmpty);
      },
    );
  }

  testWidgets('汇总整批撤回列出全部三来源和公共份，拒绝后保留事实再原键重试', (tester) async {
    final failures = <String, int>{'/cancel': 409};
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        (data['allowedActions'] as List).add('CANCEL_ACTION');
        return _sharedAggregateSubmit({
              'groups': [
                {'clientGroupKey': 'g-m-2|本色|unit-1'},
              ],
            }, data)['analysis']
            as Map<String, dynamic>;
      },
      failOn: failures,
      aggregateCancel: (body, data) {
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        for (final raw in _records(next['flatMaterials'])) {
          for (final ref in _records(raw['downstreamReferences'])) {
            ref['status'] = 'CANCELLED';
          }
        }
        _records(next['supplyActions']).single['status'] = 'CANCELLED';
        return next;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(
      const ValueKey('material-aggregate-cancel-aggregate-action'),
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining('总量 3100'), findsOneWidget);
      expect(find.textContaining('公共备货 100'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('测试产品$i'),
          ),
          findsOneWidget,
        );
      }
      await tester.enterText(
        find.byKey(const Key('material-aggregate-cancel-reason')),
        '重复安排',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('确认整批撤回'),
        ),
      );
      await tester.pumpAndSettle();
      if (attempt == 0) {
        expect(button, findsOneWidget);
        failures.clear();
      }
    }
    final cancels = requests.where((r) => r.path.endsWith('/cancel')).toList();
    expect(cancels, hasLength(2));
    expect(
      cancels.last.path,
      '/production/material-analyses/analysis-1/aggregate-orders/actions/aggregate-action/cancel',
    );
    expect(cancels.last.body, cancels.first.body);
    expect(button, findsNothing);
  });

  testWidgets('汇总整批撤回来源份额不完整时阻止确认和请求', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        (data['allowedActions'] as List).add('CANCEL_ACTION');
        final next =
            _sharedAggregateSubmit({
                  'groups': [
                    {'clientGroupKey': 'g-m-2|本色|unit-1'},
                  ],
                }, data)['analysis']
                as Map<String, dynamic>;
        (next['flatMaterials'] as List).removeWhere(
          (raw) => (raw as Map)['materialLineId'] == 'shared-2',
        );
        return next;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(requests.where((r) => r.path.endsWith('/cancel')), isEmpty);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionMaterialAnalysisPage)),
    );
    expect(
      container.read(appNotificationProvider).last.message,
      contains('来源资料不完整'),
    );
  });

  testWidgets('汇总产品任务与同货品组件分开，顶层只可切回原产品流程', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        for (final raw in _records(data['flatMaterials'])) {
          if ((raw['materialLineId'] as String).startsWith('root-')) {
            raw['goodsId'] = 'g-m-2';
          }
        }
        return data;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
    );
    expect(
      tester.widget<TextField>(field).controller!.text,
      '3000',
      reason: '组件汇总不把顶层同货品3000算进来',
    );
    expect(find.textContaining('产品任务（按产品办理）'), findsNWidgets(3));
    final root = _productCheckbox('product-0');
    expect(tester.widget<Checkbox>(root).onChanged, isNull);
    await tester.tap(find.text('按产品办理').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('产品任务（按产品办理）'), findsNothing);
  });

  testWidgets('汇总委外后续流转只展示进度，不把同批来源和公共份重复算下单', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        (data['allowedActions'] as List).add('CANCEL_ACTION');
        final next =
            _sharedAggregateSubmit({
                  'groups': [
                    {'clientGroupKey': 'g-m-2|本色|unit-1'},
                  ],
                }, data)['analysis']
                as Map<String, dynamic>;
        final action = _records(next['supplyActions']).single;
        action['route'] = 'SUBCONTRACT';
        action['documentType'] = 'SUBCONTRACT_MAKE_TASK';
        next['supplyActions'] = [
          ..._records(next['supplyActions']),
          {
            ...action,
            'actionId': 'continuation',
            'operationType': 'AGGREGATE_CONTINUATION',
            'documentType': 'SUBCONTRACT_APPLICATION',
          },
        ];
        for (final material in _records(
          next['flatMaterials'],
        ).where((m) => (m['materialLineId'] as String).startsWith('shared-'))) {
          material['sourceConfirmed'] = 'SUBCONTRACT';
          final target = _records(material['downstreamReferences']).single;
          target['route'] = 'SUBCONTRACT';
          material['downstreamReferences'] = [
            ..._records(material['downstreamReferences']),
            {
              ...target,
              'actionId': 'continuation',
              'documentId': 'application',
              'documentType': 'SUBCONTRACT_APPLICATION',
            },
          ];
        }
        return next;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('material-aggregate-order-g-m-2|本色|unit-1'),
            ),
          )
          .data,
      '3100',
    );
    expect(
      find.byKey(const ValueKey('material-aggregate-cancel-continuation')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey('material-aggregate-cancel-aggregate-action'),
            ),
          )
          .onPressed,
      isNull,
      reason: '前置生产撤回需generate，不用普通notify替代',
    );
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    expect(
      _issuedTooltip('1000'),
      findsNWidgets(3),
      reason: '每个来源只算本份1000，公共份和后续流转不再分三遍',
    );
  });

  testWidgets('汇总保留旧制造锚点1000并叠加共享份100，公共30只计整组一次', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final source = _fixtureMaterial(data, 'm-6');
        data['flatMaterials'] = [
          _fixtureMaterial(data, 'm-root'),
          for (var i = 0; i < 3; i++)
            {
              ...source,
              'materialLineId': 'legacy-$i',
              'nodeKey': 'legacy-node-$i',
              'actionGroupKey': 'a-legacy-$i',
              'planAnchorAnalysisLineId': 'legacy-anchor-$i',
              'requiredQty': 1000,
              'sourceRequiredQty': 1000,
              'additionalSupplyRecommendedQty': 0,
              'downstreamReferences': [
                {
                  'actionId': 'shared-extra',
                  'route': 'MAKE',
                  'status': 'CREATED',
                  'documentType': 'PREPLAN_MAKE_TASK',
                  'documentId': 'shared-anchor',
                  'allocatedQty': 100,
                },
              ],
            },
        ];
        (data['products'] as List).addAll([
          for (var i = 0; i < 3; i++)
            {
              'analysisLineId': 'legacy-anchor-$i',
              'sourceType': 'MAKE_COMPONENT',
              'parentAnalysisLineId': 'product-1',
              'goodsId': source['goodsId'],
              'requestedQty': 1000,
              'approvedQty': 1000,
              'issuedPlanQty': 1000,
              'remainingQty': 0,
              'canSchedule': false,
              'canIssueSurplus': true,
            },
        ]);
        data['supplyActions'] = [
          {
            'actionId': 'shared-extra',
            'route': 'MAKE',
            'operationType': 'AGGREGATE_SUPPLY',
            'requestedQty': 300,
            'publicSurplusQty': 30,
          },
        ];
        return data;
      },
    );
    expect(_issuedTooltip('1100'), findsNWidgets(3));
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('material-aggregate-order-g-m-6|本色|unit-1'),
            ),
          )
          .data,
      '3330',
    );
    expect(
      _qtyText(
        tester,
        find.byKey(const ValueKey('material-aggregate-qty-g-m-6|本色|unit-1')),
      ),
      '0',
    );
  });

  for (final increment in [0.0, 0.0001]) {
    testWidgets('汇总追加同批采纳服务端子料净增量 $increment，不重复原整包也不吞最小量', (tester) async {
      await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
        mutate: (data) {
          _aggregateDagAnalysis(data);
          (data['flatMaterials'] as List).removeWhere(
            (raw) => ['p', 'raw-deep'].contains((raw as Map)['materialLineId']),
          );
          final parent = _fixtureMaterial(data, 'h');
          for (final key in [
            'requiredQty',
            'additionalSupplyRecommendedQty',
            'netShortageQty',
            'shortageQty',
            'demandSupplyGapQty',
          ]) {
            parent[key] = 2;
          }
          return data;
        },
        aggregatePreview: (body, data) {
          final preview = _aggregateDagPreview(body, data);
          final group = _records(preview['groups']).single;
          if (group['goodsId'] == 'g-h') {
            group['existingBatchId'] = 'original-batch';
            group['priorOutputQty'] = 3;
            group['sharedBomChildren'] = [
              {
                'goodsId': 'g-raw',
                'requiredQty': increment,
                'unitId': 'unit-1',
                'colorName': '本色',
                'relativeBomPath': 'edge-raw',
              },
            ];
          }
          return preview;
        },
        aggregateSubmit: (body, data) {
          final group = _records(body['groups']).single;
          if (group['route'] == 'BUY') return _aggregateDagSubmit(body, data);
          final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          next['version'] = (data['version'] as int) + 1;
          next['fingerprint'] = 'increment-fp';
          (next['products'] as List).add({
            'analysisLineId': 'shared-h',
            'sourceType': 'AGGREGATE_MAKE',
            'goodsId': 'g-h',
            'issuedPlanQty': 5,
            'approvedQty': 5,
            'requestedQty': 5,
            'remainingQty': 0,
            'canIssueSurplus': true,
          });
          final old = _fixtureMaterial(next, 'raw-direct');
          final child = {
            ...old,
            'materialLineId': 'canonical-raw',
            'nodeKey': 'n-canonical',
            'actionGroupKey': 'a-canonical',
            'analysisLineId': 'shared-h',
            'parentNodeKey': null,
            'sourceRequiredQty': 0,
          };
          for (final key in [
            'requiredQty',
            'additionalSupplyRecommendedQty',
            'netShortageQty',
            'shortageQty',
            'demandSupplyGapQty',
          ]) {
            child[key] = increment;
            old[key] = 0;
          }
          old['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
          (next['flatMaterials'] as List).add(child);
          return {
            'analysis': next,
            'replayed': false,
            'batches': <Object>[],
            'materialIdentityBridges': [
              {
                'fromMaterialLineIds': ['raw-direct'],
                'toMaterialLineId': 'canonical-raw',
                'relativeBomPath': 'edge-raw',
                'requiredQty': increment,
              },
            ],
          };
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      for (final goods in ['h', 'raw']) {
        await _check(
          tester,
          find.descendant(
            of: find.byKey(ValueKey('material-aggregate-g-$goods|本色|unit-1')),
            matching: find.byType(Checkbox),
          ),
        );
      }
      requests.clear();
      await tester.tap(
        find.byKey(const Key('material-analysis-submit-orders')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('追加原批次'), findsOneWidget);
      await _confirmAggregateRound(tester);
      if (increment > 0) await _confirmAggregateRound(tester);
      final writes = requests
          .where((r) => r.path.endsWith('/aggregate-orders/submit'))
          .toList();
      expect(writes, hasLength(increment == 0 ? 1 : 2));
      if (increment > 0) {
        final input = _records(writes.last.body!['groups']).single;
        expect(input['qty'], '0.0001');
        expect(input['materialLineIds'], ['canonical-raw']);
      }
    });
  }

  testWidgets('列定稿为 17 列，可用数量回到需要数量与还缺数量之间', (tester) async {
    await _pump(tester);
    expect(find.text('表头设置 17/17'), findsOneWidget);
    for (final label in const [
      '物料办理',
      '物料名称',
      '编号',
      '颜色',
      '单位',
      '供应方式',
      '需要数量',
      '可用数量',
      '还缺数量',
      '下单数量',
      '允许超产比例',
      '追加下单',
      '所属仓库',
      '归属车间',
      '生产车间',
      '负责人',
      '进度 / 待办',
    ]) {
      expect(find.text(label), findsWidgets, reason: '表头缺少「$label」列');
    }
    // 退役的三列不能再出现（「可用数量」2026-09-25 起按公共口径回归）。
    for (final retired in const ['在途未到', '公共认领未实收', '在途调拨']) {
      expect(find.text(retired), findsNothing, reason: '「$retired」列应已退役');
    }
  });

  testWidgets('没确认路线的行：供应方式框标红、不给填数、也下不了单', (tester) async {
    await _pump(tester);
    // 红框是这一行唯一的入口提示。
    expect(
      find.byKey(const ValueKey('material-route-pending-m-1')),
      findsOneWidget,
    );
    // 已确认的行不该有红框。
    expect(
      find.byKey(const ValueKey('material-route-pending-m-2')),
      findsNothing,
    );
    // 路线未定 = 两个数量格都不给填。
    expect(_orderQty('m-1'), findsNothing);
    expect(_appendQty('m-1'), findsNothing);
    // 2026-09-22 用户口径「物料办理只要调拨」: 这一列不再有下达按钮, 整表一个都没有。
    expect(_issueButton('m-1'), findsNothing);
    expect(
      find.byKey(const ValueKey('material-analysis-handle-issue-any')),
      findsNothing,
    );
    // 调拨按钮照常在(置灰), 这一列没被整个抹掉。
    expect(_transferButton('m-1'), findsOneWidget);
  });

  testWidgets('确认过路线但没下过单的行：下单数量可填并预填还缺数量，追加下单恒为只读 0', (tester) async {
    await _pump(tester);
    final field = tester.widget<TextField>(_orderQty('m-2'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '500');
    // 还没下过单就没有「追加」可言，避免两列都能填造成歧义。
    expect(_appendQty('m-2'), findsNothing);
  });

  testWidgets('已下达的行：下单数量锁死并显示累计已下单量，改填追加下单', (tester) async {
    await _pump(tester);
    // 下单数量格换成只读的累计值，不再是输入框。
    expect(_orderQty('m-3'), findsNothing);
    // 追加格可填，默认 0 = 本次不动它。
    final append = tester.widget<TextField>(_appendQty('m-3'));
    expect(append.enabled, isTrue);
    expect(append.controller!.text, '0');
    // 「追加」这个语义现在只由追加下单格承载, 办理列不再有下达/追加按钮。
    expect(_issueButton('m-3'), findsNothing);
  });

  testWidgets('没有量可下的行：下单格只读 0，不再渲染成可编辑的红 0(2026-09-26)', (tester) async {
    await _pump(tester);
    // 同料兄弟行(需要数量 0)与现货盖住的行(缺口 0)都不给输入框——
    // 全选下单结束后满屏「可编辑的红 0」会让人以为中间很多行没下成。
    expect(_orderQty('m-sibling'), findsNothing);
    expect(_orderQty('m-covered'), findsNothing);
    final readonly = find.byWidgetPredicate(
      (widget) =>
          widget is Tooltip && (widget.message ?? '').contains('没有要下单的量'),
    );
    expect(readonly, findsNWidgets(2));
    // 追加格照旧是「还没下达过」的纯文本 0。
    expect(_appendQty('m-sibling'), findsNothing);
    // 有缺口的行不受影响，照旧可填。
    expect(_orderQty('m-pc'), findsOneWidget);
  });

  // 同料合并走「来源保全共享批次」后，原产品树里的行 requiredQty 归零、也没有
  // 自己的下单引用(引用在共享批次的目标行上)。2026-09-26 用户实机：这些行
  // 显示成可填的 0、超量下的也没锁；共享批次本身还在产品视图立了顶层行，
  // 「正常只有插座0/1/2」的结构被打破。守的是修复后的两条口径：
  // 1) 原行锁成本行转交份额，不给输入框；2) 共享批次不在产品视图出现。
  Map<String, dynamic> delegatedFixture(
    Map<String, dynamic> data, {
    required bool ordered,
  }) {
    (data['products'] as List).add({
      'analysisLineId': 'shared-anchor',
      'sourceType': 'AGGREGATE_MAKE',
      'goodsId': 'g-m-6',
      'goodsCode': 'M-m-6',
      'goodsName': '自制外壳',
      'requestedQty': 4000,
      if (ordered) 'issuedPlanQty': 4000,
      'remainingQty': ordered ? 0 : 4000,
      'canSchedule': !ordered,
      'canIssueSurplus': true,
      'unitName': '个',
    });
    // 共享批次 BOM 上的同物料目标行：真实下单引用挂在它身上。
    (data['flatMaterials'] as List).add({
      ..._material(
        line: 'm-6-shared',
        name: '自制外壳',
        confirmed: 'MAKE',
        netShortageQty: 0,
        requiredQty: 4000,
        stockQty: 0,
      ),
      // 与 m-6 同「货品+颜色+单位」，页面按这个键找共享批次里的目标行。
      'goodsId': 'g-m-6',
      'goodsCode': 'M-m-6',
      'analysisLineId': 'shared-anchor',
      'planAnchorAnalysisLineId': 'shared-anchor',
      'downstreamReferences': [
        if (ordered)
          {
            'actionId': 'act-agg',
            'route': 'MAKE',
            'status': 'REQUESTED',
            'documentNo': 'SJ-0009',
            'allocatedQty': 4000,
          },
      ],
    });
    // 原行：需求整体转交(份额 1000)，本行没有任何引用。
    final original = _fixtureMaterial(data, 'm-6');
    original['requiredQty'] = 0;
    original['sourceRequiredQty'] = 0;
    original['allocatedAvailableQty'] = 0;
    original['availableQty'] = 0;
    original['shortageQty'] = 0;
    original['demandSupplyGapQty'] = 0;
    original['additionalSupplyRecommendedQty'] = 0;
    original['netShortageQty'] = 0;
    original['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
    original['delegatedToAnalysisLineId'] = 'shared-anchor';
    original['aggregateDelegatedQty'] = 1000;
    return data;
  }

  testWidgets('需求并入共享批次且已下达：原行锁成转交份额，产品视图不再立共享批次顶层行(2026-09-26)', (
    tester,
  ) async {
    await _pump(
      tester,
      mutate: (data) => delegatedFixture(data, ordered: true),
    );
    // 结构：产品视图只有产品顶层，「汇总生产用料」批次行不再出现。
    expect(find.textContaining('汇总生产用料'), findsNothing);
    // 原行：下单格没有输入框，锁成本行份额 1000。
    expect(_orderQty('m-6'), findsNothing);
    expect(_appendQty('m-6'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6')),
        matching: find.text('1000'),
      ),
      findsWidgets,
      reason: '转交份额 1000 应显示在下单数量格里',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').contains('已并入共享制造批次下达'),
      ),
      findsOneWidget,
    );
    // 追加格是「—」并指路按物料汇总，不再是可编辑的 0。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('追加或撤回到「按物料汇总」'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('需求转入共享批次但还没下达：原行只读份额并指路，不给输入框(2026-09-26)', (tester) async {
    await _pump(
      tester,
      mutate: (data) => delegatedFixture(data, ordered: false),
    );
    expect(_orderQty('m-6'), findsNothing);
    expect(_appendQty('m-6'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').contains('需求已转入共享制造批次'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('主表追加格也带动子层：在已下达父件的追加格填数，子件按新数量重算', (tester) async {
    await _pump(tester);
    // 已下达的自制父件两格都在(下单数量 + 追加下单)，它们是同一个提交单元的
    // 两半；子件此刻按权威快照是 600。
    expect(find.text('已下达委外父件'), findsWidgets);
    expect(find.text('父件的子件'), findsWidgets);
    expect(_qtyText(tester, _appendQty('m-p')), '0');
    expect(_qtyText(tester, _orderQty('m-pc')), '600');

    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 追加格填的数要进 typedOutputs，否则子层纹丝不动(这一条原来是断的)。
    expect(previews, isNotEmpty);
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-p', 'qty': 1500.0},
    ]);
    expect(previews.last['lines'], isEmpty);
    // 子件跟着重算后的数走。
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('层级预览单飞 + 尾随：在途期间连改 5 次，只按最后一次补发一份(ADR-116)', (tester) async {
    await _pump(tester, previewDelayMs: 3000);
    await tester.enterText(_appendQty('m-p'), '1100');
    // 去抖到点，第一份预览发出并一直在途。
    await tester.pump(const Duration(milliseconds: 400));
    expect(previews, hasLength(1));
    for (final qty in ['1200', '1300', '1400', '1500', '1600']) {
      await tester.enterText(_appendQty('m-p'), qty);
      // 每次去抖都到点，但上一份还在路上：一份也不多发。
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(previews, hasLength(1));
    // 第一份回来 → 立刻按此刻的填数(1600)补发一份；再等它回来。
    await tester.pump(const Duration(milliseconds: 1100));
    expect(previews, hasLength(2));
    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pumpAndSettle();
    expect(previews, hasLength(2));
    expect(maxPreviewsInFlight, 1);
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-p', 'qty': 1600.0},
    ]);
    expect(_qtyText(tester, _orderQty('m-pc')), '1600');
  });

  testWidgets('父行改量后子件的还缺数量与下单预填都跟着重算后的快照走', (tester) async {
    await _pump(tester);
    final shortage = find.byKey(
      const ValueKey('material-analysis-net-shortage-m-pc'),
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 600'));

    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 原始需要量保持 1000；追加产出的实际备料仍驱动缺口和下单预填。
    expect(_sourceRequiredText(tester, 'MATERIAL|m-pc'), '1000');
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 1500'));
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('两格都空 = 交还系统算：清掉追加格后不再送这一行的数', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews.last['typedOutputs'], isNotEmpty);

    final sent = previews.length;
    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 手滑敲一下再删掉不能让这一行永久脱离跟随：模拟快照当场作废、子件回到
    // 权威快照的 600，而且不必再问服务端一次(没有要送的数量了)。
    expect(previews, hasLength(sent));
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
  });

  testWidgets('敲一下当场变：父行填数的那一拍子件就按比例换算好，不等服务端那趟', (tester) async {
    await _pump(tester);
    final shortage = find.byKey(
      const ValueKey('material-analysis-net-shortage-m-pc'),
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 600'));

    await tester.enterText(_appendQty('m-p'), '1500');
    // 只推一帧、不推时间：去抖还没到，服务端一趟都没发。
    await tester.pump();
    expect(previews, isEmpty);
    // 估算：父件已下 1000、再追加 1500 → 产出 2500 = 2.5 倍；子件需求 1000 → 2500，
    // 已覆盖的 400 是不变量，还需安排 2100；原始需要数量仍为 1000。
    expect(_sourceRequiredText(tester, 'MATERIAL|m-pc'), '1000');
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 2100'));
    expect(_qtyText(tester, _orderQty('m-pc')), '2100');

    // 300ms 后服务端那份回来(假后端按 1500 展开)，整体覆盖估算值。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
    expect(_sourceRequiredText(tester, 'MATERIAL|m-pc'), '1000');
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 1500'));
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('填了又立刻清空：子件当场回落到快照值，一次服务端都不问', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump();
    expect(_qtyText(tester, _orderQty('m-pc')), '2100');

    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump();
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
  });

  testWidgets('服务端那份回来之后再改：从模拟快照起算比例，不是从权威快照', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');

    // 分母摆到「请求时那份填数」上：父件产出 1000 + 1500 = 2500 → 1000 + 3000 = 4000，
    // 比例 1.6；子件在模拟快照里是 1500(没有覆盖量) → 2400。
    await tester.enterText(_appendQty('m-p'), '3000');
    await tester.pump();
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _orderQty('m-pc')), '2400');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(2));
    expect(_qtyText(tester, _orderQty('m-pc')), '3000');
  });

  testWidgets('顶层产品行改数：整棵树当场按比例变，而且会去问服务端(原来判成没有下层)', (tester) async {
    await _pump(tester);
    expect(_qtyText(tester, _orderQty('m-6')), '400');
    expect(_qtyText(tester, _orderQty('m-pc')), '600');

    // 顶层需求 1000、本次填 1200 → 1.2 倍。第 1 层子件的 parentNodeKey 是空的，
    // 按原始桶查顶层永远「没有下层」——既不换算也不发请求，正是用户实机看到的
    // 「主表改数值没反应」。
    await tester.enterText(_orderQty('m-root'), '1200');
    await tester.pump();
    expect(previews, isEmpty);
    // 自制子件：需求 1000 → 1200，已覆盖 600 不变 → 还需 600。
    expect(_qtyText(tester, _orderQty('m-6')), '600');
    // 已下达的委外父件 m-p 跟着变(已下 1000 + 还需 200 = 1200)，它的子件再按 1.2 倍：
    // 需求 1200、已覆盖 400 → 还需 800。
    expect(_qtyText(tester, _orderQty('m-pc')), '800');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-root', 'qty': 1200.0},
    ]);
  });

  testWidgets('仅顶层下单数从2000改3000：待下层的自制中间件及多层子件自动选中', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: _withConfirmedMakeSubtree,
      defaultWorkshops: _workshopDefaultsFor(const [
        'g-m-root',
        'g-m-hv5g001',
        'g-m-nested',
      ]),
      preview: (data, typed) {
        final quantity = typed['m-root']!;
        for (final raw in _records(data['flatMaterials'])) {
          final material = raw;
          if (material['materialLineId'] == 'm-root') continue;
          for (final field in const [
            'requiredQty',
            'shortageQty',
            'demandSupplyGapQty',
            'additionalSupplyRecommendedQty',
            'netShortageQty',
          ]) {
            material[field] = quantity;
          }
        }
        return data;
      },
    );
    for (final line in const ['m-hv5g001', 'm-nested', 'm-leaf']) {
      expect(_qtyText(tester, _orderQty(line)), '2000');
      expect(_rowChecked(tester, line), isFalse);
    }

    // 只操作顶层，未触碰中间件数量或任何复选框。
    await tester.enterText(_orderQty('m-root'), '3000');
    await tester.pump();
    await _settleRebuild(tester);
    expect(
      tester.widget<Checkbox>(_productCheckbox('product-1')).value,
      isTrue,
    );
    for (final line in const ['m-hv5g001', 'm-nested', 'm-leaf']) {
      expect(_qtyText(tester, _orderQty(line)), '3000');
      expect(_rowChecked(tester, line), isTrue, reason: '$line 应随顶层自动勾选');
    }
    expect(find.text('下单(4)'), findsOneWidget);

    await _settlePreview(tester);
    expect(previews.single['typedOutputs'], [
      {'materialLineId': 'm-root', 'qty': 3000.0},
    ]);
    expect(
      tester.widget<Checkbox>(_productCheckbox('product-1')).value,
      isTrue,
    );
    for (final line in const ['m-hv5g001', 'm-nested', 'm-leaf']) {
      expect(_qtyText(tester, _orderQty(line)), '3000');
      expect(_rowChecked(tester, line), isTrue, reason: '$line 预览后应保持勾选');
    }
    expect(find.text('下单(4)'), findsOneWidget);
  });

  testWidgets('仅顶层改数且第一层父节点为空串：自制中间件应自动选中', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        _withConfirmedMakeSubtree(data);
        _fixtureMaterial(data, 'm-hv5g001')['parentNodeKey'] = '';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const [
        'g-m-root',
        'g-m-hv5g001',
        'g-m-nested',
      ]),
      preview: _previewRootOnlySubtree,
    );
    await tester.enterText(_orderQty('m-root'), '3000');
    await tester.pump();
    await _settleRebuild(tester);
    expect(_qtyText(tester, _orderQty('m-hv5g001')), '3000');
    expect(_rowChecked(tester, 'm-hv5g001'), isTrue);
    await _settlePreview(tester);
    expect(previews, hasLength(1));
    expect(_rowChecked(tester, 'm-hv5g001'), isTrue);
  });

  testWidgets('数量填少了 / 填错了当场冒红，改对了红框就消失；父行改大让子行缺了也冒红', (tester) async {
    await _pump(tester);
    // 自制外壳：还需安排 400，预填 400 → 不红。
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);
    await tester.enterText(_orderQty('m-6'), '300');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isTrue);
    await tester.enterText(_orderQty('m-6'), '');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isTrue);
    await tester.enterText(_orderQty('m-6'), '400');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);
    // 多填不红：超出部分按公共备货记账。
    await tester.enterText(_orderQty('m-6'), '900');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);

    // 子件亲手填了 700(此刻还需安排 600，多填不红)，父件再追加 1500 → 子件还需
    // 安排当场变成 2100，700 就是「缺的」，那一拍就冒红；不必等服务端。
    // (填 600 会与系统预填值相同，被当成没动过而跟着回填成 2100——那不叫缺。)
    await tester.enterText(_orderQty('m-pc'), '700');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-pc')), isFalse);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump();
    expect(previews, isEmpty);
    expect(_framedRed(tester, _orderQty('m-pc')), isTrue);
    await tester.enterText(_orderQty('m-pc'), '2100');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-pc')), isFalse);
    // 追加格：填多少都行(追加的是额外的量, 不跟还需安排比)，0 也合法；清空 / 负数才红。
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '1');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '0');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '-1');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isTrue);
    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });

  testWidgets('父件追加带动已下过单的子件：刚好下够的子件追加格自动填上新缺口并替他勾上', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    // 子件之前刚好下够(需求 1000 = 现货 200 + 已订 800)：缺口 0，追加格 0，没勾。
    expect(_qtyText(tester, _appendQty('m-qc1')), '0');
    expect(_rowChecked(tester, 'm-qc1'), isFalse);

    // 父件(已下 1000)追加 200 → 1.2 倍 → 子件需求 1200、还缺 200：那一拍追加格就是 200，
    // 不等服务端(用户口径「父组件追加 200, 子组件追加那里也自动追加 200」)。
    await tester.enterText(_appendQty('m-q'), '200');
    await tester.pump();
    expect(previews, isEmpty);
    expect(_qtyText(tester, _appendQty('m-qc1')), '200');
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(const ValueKey('material-analysis-net-shortage-m-qc1')),
          )
          .message,
      contains('还要另外下 200'),
    );
    // 停手 200ms 后那次整页刷新：有数的行替他勾上(亲手填数的父件也勾上)，
    // 底部「下单(2)」。
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isTrue);
    expect(_rowChecked(tester, 'm-q'), isTrue);
    expect(find.text('下单(2)'), findsOneWidget);
    // 服务端那份回来(按 200 展开)：追加格与勾选都保持。
    await _settlePreview(tester);
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _appendQty('m-qc1')), '200');
    expect(_rowChecked(tester, 'm-qc1'), isTrue);

    // 父件清空追加 → 子件回落到 0，替他勾的那个勾撤掉，父件自己也撤掉。
    await tester.enterText(_appendQty('m-q'), '');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-qc1')), '0');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
    expect(_rowChecked(tester, 'm-q'), isFalse);
    expect(find.text('下单(2)'), findsNothing);
    await _settlePreview(tester);
  });

  testWidgets('多下过的子件在父件追加时一颗都不缺：追加格保持 0、不替他勾', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    // 子件需求 1000 → 1200，但它之前订了 2400(现货另有 200)，仍全被盖住——
    // 服务端封顶的还需安排看不出多下的那 1400，页面按不封顶的覆盖量算。
    await tester.enterText(_appendQty('m-r'), '200');
    await tester.pump();
    expect(_sourceRequiredText(tester, 'MATERIAL|m-rc'), '1000');
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-rc'), isFalse);
    expect(_rowChecked(tester, 'm-r'), isTrue);
    expect(find.text('下单(1)'), findsOneWidget);
    await _settlePreview(tester);
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    // 追加到 1700 才开始缺：需求 2700 − 覆盖 2600 = 100(从模拟快照起算比例)。
    await tester.enterText(_appendQty('m-r'), '1700');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-rc')), '100');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-rc'), isTrue);
    expect(find.text('下单(2)'), findsOneWidget);
    // 服务端那份回来(同一口径)：保持。
    await _settlePreview(tester);
    expect(previews, hasLength(2));
    expect(_qtyText(tester, _appendQty('m-rc')), '100');
    expect(_rowChecked(tester, 'm-rc'), isTrue);
  });

  testWidgets('子件追加格亲手填过就不跟父件走；亲手撤过的勾父件再改也不替他勾回来', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    await tester.enterText(_appendQty('m-qc1'), '50');
    await _settleRebuild(tester);
    // 亲手填了数 = 要下的行：勾上。
    expect(_rowChecked(tester, 'm-qc1'), isTrue);
    // 亲手撤掉。
    await tester.tap(_rowCheckbox('m-qc1'));
    await tester.pumpAndSettle();
    expect(_rowChecked(tester, 'm-qc1'), isFalse);

    await tester.enterText(_appendQty('m-q'), '200');
    await tester.pump();
    // 亲手填的 50 保留(父件把缺口抬到 200 也不覆盖)，勾也不替他勾回来；
    // 「还缺数量」照实说它缺 200。
    expect(_qtyText(tester, _appendQty('m-qc1')), '50');
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(const ValueKey('material-analysis-net-shortage-m-qc1')),
          )
          .message,
      contains('还要另外下 200'),
    );
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
    await _settlePreview(tester);
    expect(_qtyText(tester, _appendQty('m-qc1')), '50');
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
  });

  testWidgets('物料办理：有别的计划锁着的量才可调拨，没有就置灰并说明', (tester) async {
    await _pump(tester);
    // 夹具只给 m-2 返回了可调拨量。
    expect(_enabled(tester, _transferButton('m-2')), isTrue);
    expect(_enabled(tester, _transferButton('m-3')), isFalse);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: _transferButton('m-3'),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      contains('没有别的计划锁着这个物料'),
    );
  });

  testWidgets('勾选换义：确认过路线的行现在可勾，底部出现「下单(N)」', (tester) async {
    await _pump(tester);
    // 换义前只有「未确认路线」的行有勾选框；现在可下单的行也有。
    final row = find.byKey(const ValueKey('material-table-row-m-2'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(Checkbox)),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(find.text('下单(1)'), findsOneWidget);
    // 2026-09-25 确认路线退役：悬浮区只剩「下单」，确认路线按钮不再渲染。
    expect(
      find.byKey(const Key('material-analysis-create-routes')),
      findsNothing,
    );
  });

  testWidgets('自制行的下单数量可填：预填毛量, 不再是只读的整批接管', (tester) async {
    await _pump(tester);
    // 2026-09-22 修订：锁死自制行的理由(服务端要求逐字等于剩余需求)引错了对象 ——
    // 那条校验长在 notifySupply 里, 而自制行在更靠前的地方就被拦掉、根本走不到;
    // 自制行实际走 issue-plans, 那条路按 V577 接受任意数量。
    final field = tester.widget<TextField>(_orderQty('m-6'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '400');
    // 还没下达过, 追加格仍是只读的(避免两列都能填的歧义)。
    expect(_appendQty('m-6'), findsNothing);
  });

  testWidgets('要先自制目标件的委外行：有「下达车间」权限时下单数量可填，没有权限才整批接管只读', (tester) async {
    // 2026-09-22 用户实机：把一行改成委外后「下单数量就定死了不能修改, 我都没有下单过」——
    // 原来这类行不看权限一律锁死, 而有权限时它走 issue-plans 的 ARRANGE 段, 数量可改可超。
    await _pump(tester, mutate: _withPreparationSubcontract);
    // 默认权限没有「生成生产计划」：退回 notify 整批接管, 下单数量只读显示 800、追加横杠。
    expect(_orderQty('m-u'), findsNothing);
    expect(_appendQty('m-u'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-u')),
        matching: find.text('800'),
      ),
      findsWidgets,
    );

    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return _withPreparationSubcontract(data);
      },
    );
    final field = tester.widget<TextField>(_orderQty('m-u'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '800');
    // 还没下达过：追加格仍是只读的 0(不是横杠)。
    expect(_appendQty('m-u'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-u')),
        matching: find.text('0'),
      ),
      findsWidgets,
    );
    // 生产车间 / 负责人跟路线走：委外行两格横杠、不要求指派, 行照样可勾；
    // 自制行(m-6)才有指派格。
    expect(
      find.byKey(ValueKey('material-analysis-workshop-${_groupKey('m-u')}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('material-analysis-worker-${_groupKey('m-u')}')),
      findsNothing,
    );
    expect(_rowCheckbox('m-u'), findsOneWidget);
    expect(
      find.byKey(ValueKey('material-analysis-workshop-${_groupKey('m-6')}')),
      findsOneWidget,
    );
  });

  testWidgets('已建前置自制任务且多下过的委外子件：按锚点计划算已下达与覆盖, 父件追加时不再被算成还缺', (tester) async {
    // 2026-09-22 用户实机：顶层追加后下单 409「当前分析需求已全部转入生产计划」——
    // 子层里一颗要先自制的委外件之前多下了(需求 3000 的锚点排了 4000), 主表按发外申请
    // 3000 当「已下达」, 父件追加就把它算成还缺、送去 ARRANGE 一段, 服务端按锚点判它排满。
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: _withOverIssuedAnchoredSubcontractChild,
    );
    // 累计已下单按锚点计划 1400(不是发外申请 1000), 追加格预填 0。
    expect(_orderQty('m-vc'), findsNothing);
    expect(_issuedTooltip('1400'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-vc')), '0');

    // 父件追加 600 → 子件需求 1000 → 1600, 锚点 1400 + 现货 200 全盖住：追加格保持 0、不勾。
    await tester.enterText(_appendQty('m-v'), '600');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-vc')), '0');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-vc'), isFalse);
    // 追加 1000 → 需求 2000, 才缺 400。
    await tester.enterText(_appendQty('m-v'), '1000');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-vc')), '400');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-vc'), isTrue);
    await _settlePreview(tester);
  });

  testWidgets('顶层行不再是一排横杠：调拨按钮、下单数量、还缺数量都在', (tester) async {
    await _pump(tester);
    // 产品行直接承载 ROOT_SUPPLY(V478)。原来 _tableEditableGroup 对产品行一律
    // 早退, 导致办理/下单/追加/车间/负责人五列全横杠, 而「还缺数量」走另一套判据
    // 会显示真实数字 —— 同一行左边看得见缺口、右边办不了事。
    expect(_transferButton('m-root'), findsOneWidget);
    final field = tester.widget<TextField>(_orderQty('m-root'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '600');
  });

  testWidgets('有公共在途可认领时：还缺数量显示净数，下单数量预填毛量', (tester) async {
    await _pump(tester);
    // 这一行需求覆盖 1000，其中 300 下达时服务端会自动从公共在途认领。
    // 「还缺数量」按用户口径显示净数 700。
    final tooltip = tester.widget<Tooltip>(
      find.byKey(const ValueKey('material-analysis-net-shortage-m-4')),
    );
    expect(tooltip.message, contains('还要另外下 700'));
    expect(tooltip.message, contains('已按公共在途扣减 300'));
    // 但「下单数量」必须预填毛量 1000：服务端是从你填的数里切走认领量、
    // 不是在它之上另加。填 700 只会换来「认领 300 + 新单 400 = 700」，
    // 对着 1000 的需求仍差 300 —— 每一行都少下一个认领量。
    expect(tester.widget<TextField>(_orderQty('m-4')).controller!.text, '1000');
    // 悬浮说明要把这个「两个数不一样」讲清楚，别让人以为填错了。
    expect(tooltip.message, contains('本次要覆盖的总量 1000'));
  });

  testWidgets('从别的计划调拨进来的量不算已下单，这一行照样能正常下单', (tester) async {
    await _pump(tester);
    // m-5 有一条 FUTURE_TRANSFER 分摊，但一张订货单都没下过。
    // 它不该被当成「已下达」——否则下单格锁死、追加默认 0、批量下单静默跳过它。
    expect(_orderQty('m-5'), findsOneWidget);
    expect(_appendQty('m-5'), findsNothing);
    // 追加格不出现本身就说明这一行没被当成「已下达」(已下达才给追加格)。
    expect(_issueButton('m-5'), findsNothing);
  });

  testWidgets('全选下单的提交顺序：父先子后——直接外发委外父件先于它的采购子件，采购最后一次', (tester) async {
    await _pump(tester, mutate: _withSubcontractPair, delayMs: 350);
    // 委外父件(直接外发、我方供料)有下层：改量会去抖要一次服务端重算。
    await tester.enterText(_orderQty('m-s'), '700');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
    for (final line in const ['m-2', 'm-sc', 'm-s']) {
      await _check(tester, _rowCheckbox(line));
    }
    await tester.pumpAndSettle();
    expect(find.text('下单(3)'), findsOneWidget);
    await _submitSelected(tester);
    // 原来是「采购 → 委外」：子件按父件新数量填的量先到，服务端当成超出当时需求的
    // 公共备货；父件的委外申请随后把子件需求抬上去，子件行留下一截认不回来的缺口。
    final submits = _submits();
    expect(submits.map((request) => request.body?['target']), [
      'SUBCONTRACT',
      'BUY',
    ]);
    expect(submits.first.body?['actionGroupKeys'], ['a-m-s']);
    expect(_qtyOf(submits.first, 'a-m-s'), 700);
    expect(
      submits.last.body?['actionGroupKeys'],
      unorderedEquals(['a-m-2', 'a-m-sc']),
    );
    // 子件按父件填的 700 换算(还需安排 800 → 700)，父件落地后照样送 700，不翻倍。
    expect(_qtyOf(submits.last, 'a-m-2'), 500);
    expect(_qtyOf(submits.last, 'a-m-sc'), 700);
    // 提交期间与提交之后都不再补发层级预览：填过的数已随下达交还系统。
    // 假后端每段等 350ms，300ms 的去抖若没被挡住早就发出去了。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
    expect(
      requests.where((request) => request.path.endsWith('/preview')),
      isEmpty,
    );
    // 成功的行勾选撤掉。
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('顶层自制行下过单后：下单数量锁死显示计划总量、改填追加；再全选下单不会把它当新计划重下', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product['issuedPlanQty'] = 2000;
        product['canSchedule'] = false;
        product['canIssueSurplus'] = true;
        product['remainingQty'] = 0;
        product['latestPlanId'] = 'plan-1';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root']),
    );
    // 顶层产品行自己就是排产对象，计划挂在它身上而不是锚点：已下过单 = 锁死。
    // 原来这里读 planAnchorAnalysisLineId(顶层恒为空)，顶层下了 2000 的计划照旧
    // 给一个可填的「下单数量」，再全选下单就把它当新计划重下、服务端 409 整批停在
    // 第一步(2026-09-23 用户实机)。
    expect(_orderQty('m-root'), findsNothing);
    expect(_issuedTooltip('2000'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-root')), '0');
    // 勾上它和一条采购行一起下单：追加 0 = 本次不动它，只会发采购那一段。
    await _onlyRoot(tester);
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    expect(find.text('下单(2)'), findsOneWidget);
    await _submitSelected(tester);
    final submits = _submits();
    expect(submits.map((request) => request.path.split('/').last), ['notify']);
    expect(submits.single.body?['target'], 'BUY');
  });

  testWidgets('顶层追加格填了数：顶层自己和被带出缺口的子件都自动勾上', (tester) async {
    // 2026-09-22 用户实机：「我填数字的这层(顶层)默认是没有选中的, 子层需要追加的都自动选中」。
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product['issuedPlanQty'] = 2000;
        product['canSchedule'] = false;
        product['canIssueSurplus'] = true;
        product['remainingQty'] = 0;
        product['latestPlanId'] = 'plan-1';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
    );
    expect(
      tester.widget<Checkbox>(_productCheckbox('product-1')).value,
      isFalse,
    );
    await tester.enterText(_appendQty('m-root'), '1000');
    await tester.pump();
    await _settleRebuild(tester);
    expect(_nodeSelected(tester, 'm-root'), isTrue);
    // 自制子件 m-6 的需求被带大(缺口从 400 变大), 也替他勾上。
    expect(_rowChecked(tester, 'm-6'), isTrue);
    await _settlePreview(tester);
    expect(_nodeSelected(tester, 'm-root'), isTrue);
  });

  testWidgets('顶层填了追加数却缺生产车间勾不上：当场说原因，不重复刷屏', (tester) async {
    // 2026-09-22 用户实机「我填数字的这层(顶层)默认是没有选中的」的另一种真因：数量格只要有
    // 下达权限就是开着的, 顶层没有车间学习默认值时填了数、子层照带, 自己却静静地勾不上,
    // 原因只藏在悬浮说明里。
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product['issuedPlanQty'] = 2000;
        product['canSchedule'] = false;
        product['canIssueSurplus'] = true;
        product['remainingQty'] = 0;
        product['latestPlanId'] = 'plan-1';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
    );
    await tester.enterText(_appendQty('m-root'), '1000');
    await tester.pump();
    await _settleRebuild(tester);
    expect(_nodeSelected(tester, 'm-root'), isFalse);
    expect(_rowChecked(tester, 'm-6'), isTrue);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionMaterialAnalysisPage)),
    );
    bool blockedNotice(AppNotification notice) =>
        notice.message.contains('填了数但本次还下不了单') &&
        notice.message.contains('生产车间');
    expect(
      container.read(appNotificationProvider).where(blockedNotice),
      hasLength(1),
    );
    // 再改一位数：同一行同一原因不再说第二遍。
    await tester.enterText(_appendQty('m-root'), '1200');
    await tester.pump();
    await _settleRebuild(tester);
    expect(
      container.read(appNotificationProvider).where(blockedNotice),
      hasLength(1),
    );
  });

  testWidgets('采购行填得比当时需求多：累计已下单 = 归需求份 + 公共备货份', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        // act-3 分摊到本行 300，另有 200 记在同一条行动的公共备货份上。
        ((data['supplyActions'] as List).first as Map)['publicSurplusQty'] =
            200;
        return data;
      },
    );
    // 申请明细上就是 500。只显示 300 的话，用户实机看到的就是
    // 「我填了 5000 怎么只下了 2000」(需求 2000 + 公共 3000)。
    expect(_issuedTooltip('500'), findsOneWidget);
  });

  testWidgets('叶子行填数后下单：提交后不再补发层级预览，填的数交还系统', (tester) async {
    await _pump(tester);
    await tester.enterText(_orderQty('m-2'), '450');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 叶子行改量不惊动服务端。
    expect(previews, isEmpty);
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final submits = _submits();
    expect(submits, hasLength(1));
    final quantities = submits.single.body?['quantities'] as List;
    expect((quantities.single as Map)['actionGroupKey'], 'a-m-2');
    expect((quantities.single as Map)['qty'], 450);
    // 原来下达成功后 _applyAnalysis 会带着这行填的数去抖发一次 preview(服务端是
    // 「已下达 + 本次填的」，等于把刚下达的量再加一遍)；现在填的数已交还系统，
    // 一次都不发；这一行落库后锁成累计已下单 450。追加格预填 = 新快照里的缺口
    // (需求 500 只下了 450 → 缺 50; 2026-09-22 晚用户口径「缺的话追加那里自动
    // 显示」), 不再恒为 0; 勾选已撤、底部计数归零。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    expect(_orderQty('m-2'), findsNothing);
    expect(_issuedTooltip('450'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-2')), '50');
    expect(_rowChecked(tester, 'm-2'), isFalse);
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('已下达的自制行：还能下多少按锚点剩余可排量，排满即 0；排满且不能追加公共备货时不可勾', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) => _withIssuedMakeRow(data),
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-7']),
    );
    // 服务端给物料行的 additionalSupplyRecommendedQty 不扣已下达的自制计划(还是 2000)，
    // 照它走会把已排满的行显示成「还需安排 2000」、追加格 0 恒红。
    expect(_orderQty('m-7'), findsNothing);
    expect(_issuedTooltip('2000'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-7')), '0');
    expect(_framedRed(tester, _appendQty('m-7')), isFalse);
    expect(tester.widget<Checkbox>(_rowCheckbox('m-7')).onChanged, isNotNull);

    // 锚点排满又不能再追加公共备货产出：勾了也只会吃服务端 409，直接不给勾——路线
    // 也已锁死，于是这一行剩下的是表格给不可勾选行的那个灰勾选框(onChanged 为空)。
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) => _withIssuedMakeRow(data, canIssueSurplus: false),
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-7']),
    );
    expect(tester.widget<Checkbox>(_rowCheckbox('m-7')).onChanged, isNull);
  });

  testWidgets('车间行 + 委外父件 + 采购子件一起下：issue-plans → 委外 notify → 采购 notify', (
    tester,
  ) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return _withSubcontractPair(data);
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
      delayMs: 350,
    );
    Finder rate(String line) => find.descendant(
      of: find.byKey(
        ValueKey('material-analysis-overproduction-rate-${_groupKey(line)}'),
      ),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(rate('m-6')).controller!.text, '10');
    expect(rate('m-s'), findsNothing);
    expect(rate('m-sc'), findsNothing);
    await tester.enterText(rate('m-6'), '12.3456');
    for (final line in const ['m-6', 'm-s', 'm-sc']) {
      await _check(tester, _rowCheckbox(line));
    }
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final submits = _submits();
    expect(submits.map((request) => request.path.split('/').last), [
      'issue-plans',
      'notify',
      'notify',
    ]);
    final planLines = submits.first.body?['lines'] as List;
    expect((planLines.single as Map)['materialLineId'], 'm-6');
    expect((planLines.single as Map)['qty'], 400);
    expect((planLines.single as Map)['allowedOverproductionRate'], 0.123456);
    expect(submits[1].body?['target'], 'SUBCONTRACT');
    expect(submits[2].body?['target'], 'BUY');
    expect(previews, isEmpty);
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('准备页无效比例阻止写入，修正为零后按零提交', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
    );
    final rate = find.descendant(
      of: find.byKey(
        ValueKey('material-analysis-overproduction-rate-${_groupKey("m-6")}'),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(rate, '10.12345');
    await _check(tester, _rowCheckbox('m-6'));
    requests.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(_submits(), isEmpty);
    expect(tester.widget<TextField>(rate).controller!.text, '10.12345');
    await tester.enterText(rate, '0');
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_submits(), hasLength(1));
    final line = (_submits().single.body!['lines'] as List).single as Map;
    expect(line['allowedOverproductionRate'], 0);
  });

  testWidgets('顶层已下达后追加：走产品行 planDrafts 且声明纯公共备货', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product['issuedPlanQty'] = 2000;
        product['canSchedule'] = false;
        product['canIssueSurplus'] = true;
        product['remainingQty'] = 0;
        product['latestPlanId'] = 'plan-1';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root']),
    );
    await tester.enterText(_appendQty('m-root'), '300');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await _onlyRoot(tester);
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final submits = _submits();
    expect(submits.map((request) => request.path.split('/').last), [
      'issue-plans',
    ]);
    final line = (submits.single.body?['lines'] as List).single as Map;
    expect(line['analysisLineId'], 'product-1');
    expect(line['materialLineId'], isNull);
    expect(line['qty'], 300);
    expect(line['publicSurplusOnly'], isTrue);
    // 落库后追加格回 0、勾选撤掉、填的数交还系统。
    expect(_qtyText(tester, _appendQty('m-root')), '0');
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('父行手填 + 已排满子行追加：第二段仍按权威锚点判纯公共备货，不被段间估算带偏', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) => _withIssuedMakeRow(data),
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-7']),
    );
    // 顶层多填(600 → 1500)，已排满的自制子件追加 500 做纯公共备货。
    await tester.enterText(_orderQty('m-root'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.enterText(_appendQty('m-7'), '500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await _onlyRoot(tester);
    await _check(tester, _rowCheckbox('m-7'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final submits = _submits();
    expect(submits.map((request) => request.path.split('/').last), [
      'issue-plans',
      'issue-plans',
    ]);
    final rootLine = (submits.first.body?['lines'] as List).single as Map;
    expect(rootLine['analysisLineId'], 'product-1');
    expect(rootLine['qty'], 1500);
    // 第一段落地后快照里顶层已下 1500，而顶层填的 1500 还挂在 typedOutputs 上——原来
    // 这一刻的重估会把子树翻倍，m-7 的还需安排被估成正数，纯公共备货就被判成 false，
    // 服务端 409「当前分析需求已全部转入生产计划」整批停下(2026-09-23 对抗复查)。
    final childLine = (submits.last.body?['lines'] as List).single as Map;
    expect(childLine['materialLineId'], 'm-7');
    expect(childLine['qty'], 500);
    expect(childLine['publicSurplusOnly'], isTrue);
  });

  testWidgets('车间段失败：后面的采购段不发，勾选保留，之后填数仍会去抖发预览', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return _withSubcontractPair(data);
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
      failOn: const {'/issue-plans': 409},
    );
    await _check(tester, _rowCheckbox('m-6'));
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_submits().map((request) => request.path.split('/').last), [
      'issue-plans',
    ]);
    // 停在第一段：勾选一个都不撤，让人改了再试。
    expect(find.text('下单(2)'), findsOneWidget);
    // 编排的忙标志已复位：再填一个带下层的行，300ms 后照常去抖发预览。
    await tester.enterText(_orderQty('m-s'), '700');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
  });

  testWidgets('下过生产计划的自制行(含顶层)：供应方式锁死，不再给下拉', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product['issuedPlanQty'] = 2000;
        product['canSchedule'] = false;
        product['canIssueSurplus'] = true;
        product['remainingQty'] = 0;
        product['latestPlanId'] = 'plan-1';
        return _withIssuedMakeRow(data);
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-7']),
    );
    // 原来锁路线只认采购 / 委外的下游申请(notifiedTargets)，自制计划不在里面：
    // 顶层与自制子件下了计划，「供应方式」下拉照旧可改(2026-09-23 用户实机)。
    expect(
      find.byKey(const ValueKey('material-route-dropdown-m-root')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('material-route-dropdown-m-7')),
      findsNothing,
    );
    // 没下过计划的自制行照旧可改。
    expect(
      find.byKey(const ValueKey('material-route-dropdown-m-6')),
      findsOneWidget,
    );
  });

  testWidgets('还缺数量的悬浮说明接住了退役三列的事实', (tester) async {
    await _pump(tester);
    final tooltip = tester.widget<Tooltip>(
      find.byKey(const ValueKey('material-analysis-net-shortage-m-2')),
    );
    expect(tooltip.message, contains('还要另外下 500'));
    // 「可用数量」「在途未到」并进这里，不再各占一列。
    expect(tooltip.message, contains('仓库现在可用 200'));
    expect(tooltip.message, contains('已安排但还没合格入库 100'));
    // 实物缺口是另一个口径，必须分开讲清楚。
    expect(tooltip.message, contains('实物缺口仍是 800'));
  });
}

/// 本次 pump 期间发出的每一份「下达预览」请求体，供断言 typedOutputs。
final List<Map<String, dynamic>> previews = [];

/// 假后端上同时在途的预览数与本次 pump 期间的最大值(ADR-116 单飞)。
int previewsInFlight = 0;
int maxPreviewsInFlight = 0;

/// 本次 pump 期间发出的每一个请求(方法 / 路径 / 请求体)，供断言提交顺序。
final List<({String method, String path, Map<String, dynamic>? body})>
requests = [];

/// [mutate] 在夹具上做用例专属的改动(加行、改产品)；[defaultWorkshops] 是
/// GET default-workshops 的返回(goodsId → 车间 / 负责人学习记忆)。
Future<void> _pump(
  WidgetTester tester, {
  Set<String> permissions = _permissions,
  // 夹具已有十几行物料, 视口给高一点: 页面级滚动下看不见的行不会被建出来,
  // 排在后面的行(以及别的用例 mutate 追加的行)的输入框会找不到。
  Size size = const Size(1800, 1800),
  bool overSupply = false,
  Map<String, dynamic> Function(Map<String, dynamic> data)? mutate,
  Map<String, dynamic> Function(Map<String, dynamic> data)? afterWrite,
  Map<String, dynamic> Function(
    Map<String, dynamic> data,
    Map<String, double> typed,
  )?
  preview,
  Map<String, dynamic> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregatePreview,
  Map<String, dynamic> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregateSubmit,
  Map<String, dynamic> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregateCancel,
  List<Map<String, dynamic>> defaultWorkshops = const [],
  // 真下达 / 通知在服务端要跑几秒; 给假后端一个延迟, 段间的 300ms 去抖才有机会露馅。
  int delayMs = 0,
  // 路径后缀 → 状态码: 命中的请求直接拒绝, 用来验分段编排「失败即停」。
  Map<String, int> failOn = const {},
  // 只延迟「下达预览」应答: 验单飞 + 尾随时让第一份一直在途。
  int previewDelayMs = 0,
}) async {
  previews.clear();
  requests.clear();
  previewsInFlight = 0;
  maxPreviewsInFlight = 0;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  var data =
      jsonDecode(jsonEncode(_analysis(overSupply: overSupply)))
          as Map<String, dynamic>;
  if (mutate != null) data = mutate(data);
  // 真下达 / 通知之后服务端会换版本与指纹；夹具照样推一版，否则页面把
  // 「版本没动」当成「这次一条都没下」。
  Map<String, dynamic> bumped() {
    data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    final version = (data['version'] as int) + 1;
    data['version'] = version;
    data['fingerprint'] = '$version'.padLeft(64, 'b');
    if (afterWrite != null) data = afterWrite(data);
    return data;
  }

  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        requests.add((
          method: request.method,
          path: request.path,
          body: request.data is Map
              ? (request.data as Map).cast<String, dynamic>()
              : null,
        ));
        Object result = <Object>[];
        if (request.path == '/master/warehouses/dict') {
          result = [
            {'id': 'main', 'name': '综合主仓', 'code': '001'},
            {
              'id': 'warehouse-1',
              'name': '原料子仓',
              'code': '010',
              'parentId': 'main',
            },
          ];
        } else if (request.path.endsWith('/transferable-in-summary')) {
          // 只有 m-2 能从别的计划调进来。
          result = {
            'qtyByMaterialLineId': {'m-2': 120},
          };
        } else if (request.path.endsWith('/default-workshops')) {
          result = defaultWorkshops;
        } else if (request.path.contains('/aggregate-orders/actions/') &&
            request.path.endsWith('/cancel')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          result = aggregateCancel!(request.data as Map<String, dynamic>, data);
          data = Map<String, dynamic>.from(result as Map);
        } else if (request.path.endsWith('/aggregate-orders/preview')) {
          result = aggregatePreview!(
            request.data as Map<String, dynamic>,
            data,
          );
        } else if (request.path.endsWith('/aggregate-orders/submit')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          result = aggregateSubmit!(request.data as Map<String, dynamic>, data);
          data = Map<String, dynamic>.from((result as Map)['analysis'] as Map);
        } else if (request.path.endsWith('/issue-plans/preview')) {
          // 回滚式预览：按请求里 typedOutputs 把子层需求放大(与服务端「子件按
          // 父件计划产出量展开」同一口径)，并记下这次送了什么供断言。
          final body = request.data as Map<String, dynamic>;
          previews.add(body);
          previewsInFlight++;
          if (previewsInFlight > maxPreviewsInFlight) {
            maxPreviewsInFlight = previewsInFlight;
          }
          if (previewDelayMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: previewDelayMs));
          }
          previewsInFlight--;
          final typed = {
            for (final raw in (body['typedOutputs'] as List? ?? const []))
              (raw as Map)['materialLineId'] as String: (raw['qty'] as num)
                  .toDouble(),
          };
          final scaled = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          for (final pair in const [('m-p', 'm-pc'), ('m-s', 'm-sc')]) {
            final parent = typed[pair.$1];
            if (parent == null) continue;
            for (final raw in (scaled['flatMaterials'] as List)) {
              final material = raw as Map<String, dynamic>;
              if (material['materialLineId'] != pair.$2) continue;
              // 模拟快照里这一行「没有覆盖量」：需求 = 缺口 = 还需安排, 现货分配也
              // 清零, 四个数自洽(页面按现货分配 + 已下达算不封顶的覆盖量)。
              material['requiredQty'] = parent;
              material['shortageQty'] = parent;
              material['demandSupplyGapQty'] = parent;
              material['allocatedAvailableQty'] = 0;
              material['netShortageQty'] = parent;
              material['additionalSupplyRecommendedQty'] = parent;
            }
          }
          // 父件二 / 三的追加带动**已下过单**的子件(服务端口径: 需求按父件产出量
          // 展开, 还需安排 = 需求 − 覆盖, 封顶 0): 刚好下够的子件覆盖 1000(现货 200 +
          // 已订 800), 多下过的覆盖 2600(现货 200 + 已订 2400)。
          for (final raw in (scaled['flatMaterials'] as List)) {
            final material = raw as Map<String, dynamic>;
            final line = material['materialLineId'] as String;
            final appended = switch (line) {
              'm-qc1' => typed['m-q'],
              'm-rc' => typed['m-r'],
              // 多下过的委外子件：锚点计划 1400 + 现货 200 盖住 1600。
              'm-vc' => typed['m-v'],
              // 顶层(已下 2000)追加 → 自制子件按 (2000 + 追加) / 2000 展开, 覆盖 600。
              'm-6' => typed['m-root'],
              _ => null,
            };
            if (appended == null) continue;
            final covered = switch (line) {
              'm-qc1' => 1000.0,
              'm-rc' => 2600.0,
              'm-6' => 600.0,
              _ => 1600.0,
            };
            final required = line == 'm-6'
                ? 1000 * (2000 + appended) / 2000
                : 1000 + appended;
            final residual = required - covered;
            material['requiredQty'] = required;
            material['additionalSupplyRecommendedQty'] = residual > 0
                ? residual
                : 0.0;
            material['netShortageQty'] = residual > 0 ? residual : 0.0;
          }
          // 服务端「锚点配额随父件长大」：多下过的委外子件的前置自制锚点需求 = 物料
          // 需求 − 现货 200, 剩余可排量 = 需求 − 已排 1400(封顶 0)。
          final appendedV = typed['m-v'];
          if (appendedV != null) {
            for (final raw in (scaled['products'] as List)) {
              final product = raw as Map<String, dynamic>;
              if (product['analysisLineId'] != 'anchor-vc') continue;
              final requested = 800 + appendedV;
              final remaining = requested - 1400;
              product['requestedQty'] = requested;
              product['remainingQty'] = remaining > 0 ? remaining : 0.0;
              product['canSchedule'] = remaining > 0;
            }
          }
          result = preview?.call(scaled, typed) ?? scaled;
        } else if (request.path.endsWith('/issue-plans')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          _applyIssuePlansToFixture(data, request.data as Map<String, dynamic>);
          result = {
            'analysis': bumped(),
            'replayed': false,
            'plans': <Object>[],
          };
        } else if (request.path.endsWith('/notify')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          _applyNotifyToFixture(data, request.data as Map<String, dynamic>);
          result = bumped();
        } else if (request.path == '/production/material-analyses/analysis-1') {
          result = data;
        } else if (request.path.endsWith('/routes') &&
            request.method == 'PUT') {
          // 2026-09-25 确认路线退役：进页自动确认会打这条通道——夹具对齐
          // 真实服务端，回写 confirmed（否则脏组永存，拖死后续下单拦截）。
          data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          for (final decision
              in (request.data as Map<String, dynamic>)['decisions'] as List) {
            final decisionMap = decision as Map<String, dynamic>;
            for (final row
                in (data['flatMaterials'] as List)
                    .cast<Map<String, dynamic>>()) {
              final matches =
                  row['actionGroupKey'] == decisionMap['actionGroupKey'] ||
                  row['materialLineId'] == decisionMap['materialLineId'];
              if (!matches) continue;
              row['sourceConfirmed'] = decisionMap['route'];
              row['sourceSuggestion'] = decisionMap['route'];
              row['routeConfirmed'] = true;
            }
          }
          result = data;
        } else if (request.path.endsWith('/sales-candidates')) {
          result = {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          };
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: result,
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
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const ProductionMaterialAnalysisPage(
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
}

Map<String, dynamic> _threeSharedBuySources(Map<String, dynamic> data) {
  final product = Map<String, dynamic>.from(
    (data['products'] as List).first as Map,
  );
  final root = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-root'));
  final material = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-2'));
  data['products'] = [
    for (var i = 0; i < 3; i++)
      {
        ...product,
        'analysisLineId': 'product-$i',
        'goodsId': 'parent-$i',
        'goodsName': '测试产品$i',
        'rootMaterialLineId': 'root-$i',
      },
  ];
  data['flatMaterials'] = [
    for (var i = 0; i < 3; i++) ...[
      {
        ...root,
        'materialLineId': 'root-$i',
        'analysisLineId': 'product-$i',
        'nodeKey': 'root-node-$i',
        'actionGroupKey': 'a-root-$i',
        'goodsId': 'parent-$i',
      },
      {
        ...material,
        'materialLineId': 'shared-$i',
        'analysisLineId': 'product-$i',
        'nodeKey': 'shared-node-$i',
        'actionGroupKey': 'a-shared-$i',
        'requiredQty': 1000,
        'sourceRequiredQty': 1000,
        'shortageQty': 1000,
        'availableQty': 0,
        'allocatedAvailableQty': 0,
        'demandSupplyGapQty': 1000,
        'additionalSupplyRecommendedQty': 1000,
        'netShortageQty': 1000,
      },
    ],
  ];
  data['supplyActions'] = <Object>[];
  return data;
}

Future<void> _confirmAggregateRound(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Map<String, dynamic> _aggregateDagAnalysis(Map<String, dynamic> data) {
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  data['products'] = [(data['products'] as List).first];
  data['overproductionDefaults'] = {'g-h': 0, 'g-p': 0};
  data['flatMaterials'] = [
    _fixtureMaterial(data, 'm-root'),
    for (final spec in [
      ('h', 'MAKE', 3.0, 'm-root', 'g-h'),
      ('p', 'MAKE', 3.0, 'h', 'g-p'),
      ('raw-direct', 'BUY', 1.0, 'h', 'g-raw'),
      ('raw-deep', 'BUY', 1.0, 'p', 'g-raw'),
    ])
      {
        ..._material(
          line: spec.$1,
          name: spec.$5,
          confirmed: spec.$2,
          netShortageQty: spec.$3,
          parentLine: spec.$4,
          stockQty: 0,
        ),
        'goodsId': spec.$5,
        'requiredQty': spec.$3,
        'sourceRequiredQty': spec.$3,
        'shortageQty': spec.$3,
        'demandSupplyGapQty': spec.$3,
      },
  ];
  return data;
}

List<Map<String, dynamic>> _records(Object? value) =>
    (value as List? ?? const <Object>[]).cast<Map<String, dynamic>>();

Map<String, dynamic> _aggregateDagPreview(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) => {
  'analysisId': data['analysisId'],
  'version': data['version'],
  'fingerprint': data['fingerprint'],
  'previewFingerprint': 'dag-${data['version']}',
  'analysis': data,
  'groups': [
    for (final group in _records(body['groups']))
      {
        'clientGroupKey': group['clientGroupKey'],
        'goodsId': _fixtureMaterial(
          data,
          (group['materialLineIds'] as List).cast<String>().first,
        )['goodsId'],
        'goodsName': '物料',
        'route': group['route'],
        'unitName': '个',
        'requestedQty': double.parse(group['qty'].toString()),
        'publicExtraQty':
            double.parse(group['qty'].toString()) -
            (group['materialLineIds'] as List).cast<String>().fold<double>(
              0,
              (sum, id) =>
                  sum +
                  (_fixtureMaterial(data, id)['additionalSupplyRecommendedQty']
                          as num)
                      .toDouble(),
            ),
        'sources': [
          for (final id in (group['materialLineIds'] as List).cast<String>())
            {
              'materialLineId': id,
              'sourceLabel': id,
              'allocatedQty': _fixtureMaterial(
                data,
                id,
              )['additionalSupplyRecommendedQty'],
            },
        ],
        'sharedBomChildren': <Object>[],
      },
  ],
};

Map<String, dynamic> _aggregateDagSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data, {
  bool retainOriginal = false,
}) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = '${next['version']}'.padLeft(64, 'd');
  final group = (body['groups'] as List).single as Map;
  final ids = List<String>.from(group['materialLineIds'] as List);
  final kind = (group['clientGroupKey'] as String).split('|').first;
  final anchor = kind == 'g-h' ? 'anchor-h' : 'anchor-p';
  final bridges = <Map<String, dynamic>>[];
  for (final id in ids) {
    final material = _fixtureMaterial(next, id);
    material['additionalSupplyRecommendedQty'] = 0;
    material['netShortageQty'] = 0;
    material['downstreamReferences'] = [
      {
        'actionId': 'dag-$kind',
        'route': group['route'],
        'documentType': group['route'] == 'MAKE'
            ? 'PRODUCTION_PLAN'
            : 'PURCHASE_REQUEST',
        'documentId': anchor,
        'status': 'REQUESTED',
        'allocatedQty': material['requiredQty'],
      },
    ];
    if (group['route'] == 'MAKE') material['planAnchorAnalysisLineId'] = anchor;
  }
  (next['supplyActions'] as List).add({
    'actionId': 'dag-$kind',
    'route': group['route'],
    'operationType': 'AGGREGATE_SUPPLY',
    'requestedQty': double.parse(group['qty'].toString()),
    'publicSurplusQty': 0,
  });
  if (group['route'] == 'MAKE') {
    (next['products'] as List).add({
      'analysisLineId': anchor,
      'sourceType': 'AGGREGATE_MAKE',
      'goodsId': kind,
      'goodsName': kind,
      'requestedQty': 3,
      'approvedQty': 3,
      'issuedPlanQty': 3,
      'remainingQty': 0,
      'canSchedule': false,
      'canIssueSurplus': true,
    });
    final mappings = kind == 'g-h'
        ? [
            ('p', 'shared-p'),
            ('raw-direct', 'shared-raw-direct'),
            ('raw-deep', 'raw-under-shared-p'),
          ]
        : [('raw-under-shared-p', 'shared-raw-deep')];
    for (final (old, id) in mappings) {
      final source = _fixtureMaterial(next, old);
      final qty = source['requiredQty'];
      final child = {
        ...source,
        'materialLineId': id,
        'nodeKey': 'n-$id',
        'actionGroupKey': 'a-$id',
        'analysisLineId': anchor,
        'sourceRequiredQty': 0,
        'parentNodeKey': id == 'raw-under-shared-p' ? 'n-shared-p' : null,
      };
      final retain = retainOriginal && old == 'raw-direct';
      if (!retain) {
        source['requiredQty'] = 0;
        source['additionalSupplyRecommendedQty'] = 0;
        source['netShortageQty'] = 0;
        source['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
        source['delegatedToAnalysisLineId'] = anchor;
      }
      (next['flatMaterials'] as List).add(child);
      bridges.add({
        'fromMaterialLineIds': [if (!retain) old],
        'toMaterialLineId': id,
        'relativeBomPath': 'edge-$old',
        'requiredQty': qty,
      });
    }
  }
  return {
    'analysis': next,
    'replayed': false,
    'materialIdentityBridges': bridges,
    'batches': [
      {
        'batchId': 'b-$kind',
        'clientGroupKey': group['clientGroupKey'],
        'route': group['route'],
        'documentNo': anchor,
        'qty': double.parse(group['qty'].toString()),
        'sources': <Object>[],
      },
    ],
  };
}

Map<String, dynamic> _sharedAggregatePreview(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final group = (body['groups'] as List).single as Map;
  final qty = double.parse(group['qty'].toString());
  return {
    'analysisId': data['analysisId'],
    'version': data['version'],
    'fingerprint': data['fingerprint'],
    'previewFingerprint': 'c' * 64,
    'analysis': data,
    'groups': [
      {
        'clientGroupKey': group['clientGroupKey'],
        'compatibilityKey': 'shared-buy',
        'route': 'BUY',
        'goodsId': 'g-m-2',
        'goodsName': '共享材料',
        'unitId': 'unit-1',
        'unitName': '个',
        'sourceRequiredQty': 3000,
        'orderedQty': 0,
        'remainingQty': 3000,
        'requestedQty': qty,
        'publicExtraQty': qty - 3000,
        'safetyQty': 0,
        'sources': [
          for (var i = 0; i < 3; i++)
            {
              'materialLineId': 'shared-$i',
              'analysisLineId': 'product-$i',
              'sourceLabel': '测试产品$i',
              'allocationPriority': i + 1,
              'sourceRequiredQty': 1000,
              'remainingQty': 1000,
              'allocatedQty': 1000,
              'orderedQty': 0,
            },
        ],
        'sharedBomChildren': <Object>[],
      },
    ],
  };
}

Map<String, dynamic> _sharedAggregateSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = 'b' * 64;
  for (final raw in _records(next['flatMaterials'])) {
    final material = raw;
    if (!(material['materialLineId'] as String).startsWith('shared-')) continue;
    material['downstreamReferences'] = [
      {
        'actionId': 'aggregate-action',
        'route': 'BUY',
        'status': 'REQUESTED',
        'documentType': 'PURCHASE_REQUEST',
        'documentId': 'purchase-aggregate',
        'documentNo': 'CS-AGG',
        'allocatedQty': 1000,
      },
    ];
    material['additionalSupplyRecommendedQty'] = 0;
    material['netShortageQty'] = 0;
  }
  next['supplyActions'] = [
    {
      'actionId': 'aggregate-action',
      'route': 'BUY',
      'operationType': 'AGGREGATE_SUPPLY',
      'requestedQty': 3000,
      'publicSurplusQty': 100,
    },
  ];
  final group = (body['groups'] as List).single as Map;
  return {
    'analysis': next,
    'replayed': false,
    'materialIdentityBridges': <Object>[],
    'batches': [
      {
        'batchId': 'batch-1',
        'clientGroupKey': group['clientGroupKey'],
        'route': 'BUY',
        'documentType': 'PURCHASE_REQUEST',
        'documentId': 'purchase-aggregate',
        'documentNo': 'CS-AGG',
        'qty': 3100,
        'publicExtraQty': 100,
        'sources': <Object>[],
      },
    ],
  };
}

/// 三行物料刚好铺满三种形态：未确认路线 / 已确认未下达 / 已下达。
/// [overSupply] = 服务端也放行超量(已下达的行追加要它)。
Map<String, dynamic> _analysis({bool overSupply = false}) => {
  'overproductionDefaults': {'g-m-root': 0, 'g-m-6': 0.1, 'g-m-7': 0.1},
  'analysisId': 'analysis-1',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'status': 'ACTIVE',
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'CROSS_REALLOCATE',
    if (overSupply) 'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'product-1',
      'sourceType': 'SALES_ORDER',
      'goodsId': 'product-goods',
      'goodsCode': 'UT-2026',
      'goodsName': '智能多功能插座',
      'requestedQty': 1000,
      'remainingQty': 1000,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 1000,
      'unitName': '件',
      'rootMaterialLineId': 'm-root',
    },
  ],
  'flatMaterials': [
    // 顶层根供给行: 产品行直接承载它(V478), 不再单独渲染一条根物料行。
    _material(
      line: 'm-root',
      name: '智能多功能插座',
      confirmed: 'MAKE',
      netShortageQty: 600,
      nodeRole: 'ROOT_SUPPLY',
      level: 0,
    ),
    // 自制子件: 2026-09-22 起下单数量可填可超量。
    _material(
      line: 'm-6',
      name: '自制外壳',
      confirmed: 'MAKE',
      netShortageQty: 400,
    ),
    _material(
      line: 'm-1',
      name: '未定路线件',
      confirmed: null,
      suggestion: null,
      netShortageQty: 800,
    ),
    // 已下达的自制父件 + 它的采购子件：主表上「父改子跟」与「追加也要带动子层」
    // 两条口径都落在这一对上(父件只能在追加格填数)。
    _material(
      line: 'm-p',
      name: '已下达委外父件',
      confirmed: 'SUBCONTRACT',
      // V581 我方供料的单一子件件：直接外发、不建前置自制任务，所以追加格可填。
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-p',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0001',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-pc',
      name: '父件的子件',
      confirmed: 'BUY',
      netShortageQty: 600,
      level: 2,
      parentLine: 'm-p',
    ),
    // 已下达的委外父件二 + 一个**刚好下够**的采购子件(需求 1000 = 现货 200 + 已订
    // 800)：父件追加时子件的追加格要自动填上新缺口(用户口径 2026-09-22)。
    _material(
      line: 'm-q',
      name: '已下达父件二',
      confirmed: 'SUBCONTRACT',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-q',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0002',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-qc1',
      name: '下够了的子件',
      confirmed: 'BUY',
      netShortageQty: 0,
      level: 2,
      parentLine: 'm-q',
      downstream: [
        {
          'actionId': 'act-qc1',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0002',
          'allocatedQty': 800,
        },
      ],
    ),
    // 已下达的委外父件三 + 一个**多下过**的采购子件(需求 1000，现货 200 之外还订了
    // 2400)：父件追加 200 时它一颗都不缺，追加格保持 0。
    _material(
      line: 'm-r',
      name: '已下达父件三',
      confirmed: 'SUBCONTRACT',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-r',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0003',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-rc',
      name: '多下了的子件',
      confirmed: 'BUY',
      netShortageQty: 0,
      level: 2,
      parentLine: 'm-r',
      downstream: [
        {
          'actionId': 'act-rc',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0003',
          'allocatedQty': 2400,
        },
      ],
    ),
    _material(
      line: 'm-2',
      name: '待下单紧固件',
      confirmed: 'BUY',
      netShortageQty: 500,
      inboundQty: 100,
    ),
    _material(
      line: 'm-3',
      name: '已下单紧固件',
      confirmed: 'BUY',
      netShortageQty: 0,
      downstream: [
        {
          'actionId': 'act-3',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0001',
          'allocatedQty': 300,
        },
      ],
    ),
    // 有公共在途可认领：毛量 1000、净数 700。
    _material(
      line: 'm-4',
      name: '有公共在途件',
      confirmed: 'BUY',
      netShortageQty: 700,
      grossQty: 1000,
      sharedFutureAvailableQty: 300,
    ),
    // 只从别的计划调拨进来一点，没下过任何订货单。
    _material(
      line: 'm-5',
      name: '刚调拨进来的件',
      confirmed: 'BUY',
      netShortageQty: 950,
      downstream: [
        {
          'actionId': 'act-transfer',
          'route': 'BUY',
          'status': 'CREATED',
          'documentNo': 'PR-9999',
          'allocatedQty': 50,
        },
      ],
    ),
    // 同料兄弟行：同一物料挂在别棵产品树上的 0 需求实例(需求量记在需求行上)。
    // 2026-09-26 用户实机：全选下单后这种行渲染成「可编辑的红 0」+「还没下达过」，
    // 看起来就是「中间很多行没下成」——现在下单格只读。
    _material(
      line: 'm-sibling',
      name: '同料兄弟行',
      confirmed: 'BUY',
      netShortageQty: 0,
      stockQty: 0,
      requiredQty: 0,
    ),
    // 缺口已由现货盖住、从未下过单的行：同样没有量可下。
    _material(
      line: 'm-covered',
      name: '现货盖住的行',
      confirmed: 'BUY',
      netShortageQty: 0,
      stockQty: 1000,
    ),
  ],
  // 客户端按 operationType 区分「真下过单」与「只是把别处的在途搬过来」。
  'supplyActions': [
    {'actionId': 'act-3', 'route': 'BUY', 'operationType': 'SUPPLY'},
    {
      'actionId': 'act-transfer',
      'route': 'BUY',
      'operationType': 'FUTURE_TRANSFER',
    },
  ],
};

/// 已确认路线、零库存且完全未下达的四层树，复现仅顶层填数的正常操作。
Map<String, dynamic> _previewRootOnlySubtree(
  Map<String, dynamic> data,
  Map<String, double> typed,
) {
  final requested = typed['m-root'] ?? 2000;
  final quantity = requested > 2000 ? requested : 2000.0;
  for (final raw in _records(data['flatMaterials'])) {
    final material = raw;
    if (material['materialLineId'] == 'm-root') continue;
    final issued = (material['downstreamReferences'] as List).fold<double>(
      0,
      (sum, raw) => sum + ((raw as Map)['allocatedQty'] as num).toDouble(),
    );
    final remaining = quantity - issued;
    material['requiredQty'] = quantity;
    material['shortageQty'] = quantity;
    material['demandSupplyGapQty'] = quantity;
    material['additionalSupplyRecommendedQty'] = remaining > 0
        ? remaining
        : 0.0;
    material['netShortageQty'] = remaining > 0 ? remaining : 0.0;
  }
  return data;
}

/// 已确认路线、零库存且完全未下达的四层树，复现仅顶层填数的正常操作。
Map<String, dynamic> _withConfirmedMakeSubtree(Map<String, dynamic> data) {
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  final product = (data['products'] as List).single as Map<String, dynamic>;
  product['requestedQty'] = 2000;
  product['remainingQty'] = 2000;
  product['maxSchedulableQty'] = 2000;
  final materials = [
    _material(
      line: 'm-root',
      name: '顶层插座',
      confirmed: 'MAKE',
      netShortageQty: 2000,
      nodeRole: 'ROOT_SUPPLY',
      level: 0,
      stockQty: 0,
    ),
    _material(
      line: 'm-hv5g001',
      name: 'HV5G001自制中间件',
      confirmed: 'MAKE',
      netShortageQty: 2000,
      stockQty: 0,
    )..['lowerLevelPending'] = true,
    _material(
      line: 'm-nested',
      name: '中间件的自制子件',
      confirmed: 'MAKE',
      netShortageQty: 2000,
      parentLine: 'm-hv5g001',
      level: 2,
      stockQty: 0,
    )..['lowerLevelPending'] = true,
    _material(
      line: 'm-leaf',
      name: '最下层采购件',
      confirmed: 'BUY',
      netShortageQty: 2000,
      parentLine: 'm-nested',
      level: 3,
      stockQty: 0,
    ),
  ];
  for (final material in materials) {
    material['sourceRequiredQty'] = 2000;
    material['requiredQty'] = 2000;
    material['shortageQty'] = 2000;
    material['demandSupplyGapQty'] = 2000;
  }
  data['flatMaterials'] = materials;
  data['supplyActions'] = <Object>[];
  return data;
}

/// 已排满的自制父件(锚点 1000/1000) → 已建前置自制任务且**多下过**的委外子件(锚点需求 1000、
/// 计划 1400, 发外申请 1000) → 它的自制子件(没下过)。父件追加时子件按锚点计划 1400 算覆盖。
Map<String, dynamic> _withOverIssuedAnchoredSubcontractChild(
  Map<String, dynamic> data,
) {
  (data['flatMaterials'] as List)
    ..add(
      _material(
        line: 'm-v',
        name: '已排满的自制父件',
        confirmed: 'MAKE',
        netShortageQty: 0,
        stockQty: 0,
        planAnchorAnalysisLineId: 'anchor-v',
      ),
    )
    ..add(
      _material(
        line: 'm-vc',
        name: '多下过的委外子件',
        confirmed: 'SUBCONTRACT',
        netShortageQty: 0,
        level: 2,
        parentLine: 'm-v',
        planAnchorAnalysisLineId: 'anchor-vc',
        downstream: [
          {
            'actionId': 'act-vc',
            'route': 'SUBCONTRACT',
            'status': 'IN_PROGRESS',
            'documentNo': 'SC-0004',
            'allocatedQty': 1000,
          },
        ],
      ),
    )
    ..add(
      _material(
        line: 'm-vcc',
        name: '委外子件的自制子件',
        confirmed: 'MAKE',
        netShortageQty: 800,
        level: 3,
        parentLine: 'm-vc',
      ),
    );
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  (data['products'] as List).addAll([
    {
      'analysisLineId': 'anchor-v',
      'sourceType': 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'product-1',
      'goodsId': 'g-m-v',
      'goodsCode': 'M-m-v',
      'goodsName': '已排满的自制父件',
      'requestedQty': 1000,
      'submittedQty': 0,
      'approvedQty': 1000,
      'remainingQty': 0,
      'issuedPlanQty': 1000,
      'canSchedule': false,
      'canIssueSurplus': true,
      'unitName': '个',
    },
    {
      'analysisLineId': 'anchor-vc',
      'sourceType': 'SUBCONTRACT_MAKE',
      'parentAnalysisLineId': 'product-1',
      'goodsId': 'g-m-vc',
      'goodsCode': 'M-m-vc',
      'goodsName': '多下过的委外子件',
      // 锚点需求 = 物料需求 1000 − 本批分到的现货 200; 计划 1400 = 多下了 600。
      'requestedQty': 800,
      'submittedQty': 0,
      'approvedQty': 800,
      'remainingQty': 0,
      'issuedPlanQty': 1400,
      'canSchedule': false,
      'canIssueSurplus': true,
      'unitName': '个',
    },
  ]);
  return data;
}

/// 一个「要先自制目标件再发外」的委外件(带一个自制子件, 不是 V581 单一子件件), 没下过单。
Map<String, dynamic> _withPreparationSubcontract(Map<String, dynamic> data) {
  (data['flatMaterials'] as List)
    ..add(
      _material(
        line: 'm-u',
        name: '要先自制的委外件',
        confirmed: 'SUBCONTRACT',
        netShortageQty: 800,
      ),
    )
    ..add(
      _material(
        line: 'm-uc',
        name: '委外件的自制子件',
        confirmed: 'MAKE',
        netShortageQty: 800,
        level: 2,
        parentLine: 'm-u',
      ),
    );
  return data;
}

/// 一对「直接外发委外父件 + 我方供料采购子件」，都还没下过单(提交顺序用例)。
Map<String, dynamic> _withSubcontractPair(Map<String, dynamic> data) {
  (data['flatMaterials'] as List)
    ..add(
      _material(
        line: 'm-s',
        name: '待外发委外父件',
        confirmed: 'SUBCONTRACT',
        subcontractOutboundForm: 'COMPONENT_OUTBOUND',
        netShortageQty: 800,
      ),
    )
    ..add(
      _material(
        line: 'm-sc',
        name: '委外父件的采购子件',
        confirmed: 'BUY',
        netShortageQty: 800,
        level: 2,
        parentLine: 'm-s',
      ),
    );
  return data;
}

/// 这些货品的车间 / 负责人学习记忆(GET default-workshops 的返回形状)。
List<Map<String, dynamic>> _workshopDefaultsFor(List<String> goodsIds) => [
  for (final goodsId in goodsIds)
    {
      'goodsId': goodsId,
      'departmentId': 'ws-1',
      'departmentName': '装配一车间',
      'responsibleEmployeeId': 'w-1',
      'responsibleEmployeeName': '张三',
    },
];

/// 命中 [failOn] 的请求按配置的状态码拒绝(先等 [delayMs]), 返回是否已拒绝。
Future<bool> _rejectIfConfigured(
  RequestOptions request,
  RequestInterceptorHandler handler,
  Map<String, int> failOn,
  int delayMs,
) async {
  if (delayMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }
  final status = failOn.entries
      .where((entry) => request.path.endsWith(entry.key))
      .map((entry) => entry.value)
      .firstOrNull;
  if (status == null) return false;
  handler.reject(
    DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: request,
        statusCode: status,
        data: {'message': '夹具按配置拒绝'},
      ),
    ),
  );
  return true;
}

Map<String, dynamic> _fixtureMaterial(Map<String, dynamic> data, String line) =>
    (data['flatMaterials'] as List).cast<Map<String, dynamic>>().firstWhere(
      (material) => material['materialLineId'] == line,
    );

double _num(Object? value) => (value as num?)?.toDouble() ?? 0;

/// 像服务端那样把一次 notify 写回快照: 需求份 = min(填数, 还需安排), 多出的记公共备货份;
/// 本行挂上下游申请引用, 还需安排 / 还缺随之减少。
void _applyNotifyToFixture(
  Map<String, dynamic> data,
  Map<String, dynamic> body,
) {
  final route = body['target'] as String;
  for (final raw in (body['quantities'] as List? ?? const [])) {
    final quantity = raw as Map;
    final key = quantity['actionGroupKey'] as String?;
    if (key == null || !key.startsWith('a-')) continue;
    final line = key.substring(2);
    final material = _fixtureMaterial(data, line);
    final qty = _num(quantity['qty']);
    final residual = _num(material['additionalSupplyRecommendedQty']);
    final demand = qty < residual ? qty : residual;
    final actionId = 'act-$line-${requests.length}';
    // 夹具行的列表可能是 const, 一律换成新列表而不是就地 add。
    material['downstreamReferences'] = [
      ...(material['downstreamReferences'] as List? ?? const []),
      {
        'actionId': actionId,
        'route': route,
        'status': 'CREATED',
        'documentNo': 'REQ-$line',
        'allocatedQty': demand,
        'growableLineQty': qty,
      },
    ];
    material['additionalSupplyRecommendedQty'] = residual - demand;
    material['netShortageQty'] = residual - demand;
    data['supplyActions'] = [
      ...(data['supplyActions'] as List? ?? const []),
      {
        'actionId': actionId,
        'route': route,
        'operationType': 'SUPPLY',
        'requestedQty': demand,
        'publicSurplusQty': qty - demand,
      },
    ];
  }
}

/// 像服务端那样把一次 issue-plans 写回快照: 顶层行累加到产品行自己的计划, 候选行建
/// (或增量)锚点子件行; 排满即 canSchedule=false、余量 0。
void _applyIssuePlansToFixture(
  Map<String, dynamic> data,
  Map<String, dynamic> body,
) {
  final products = (data['products'] as List).cast<Map<String, dynamic>>();
  for (final raw in (body['lines'] as List? ?? const [])) {
    final line = raw as Map;
    final qty = _num(line['qty']);
    final surplusOnly = line['publicSurplusOnly'] == true;
    final analysisLineId = line['analysisLineId'] as String?;
    final materialLineId = line['materialLineId'] as String?;
    Map<String, dynamic> product;
    if (analysisLineId != null) {
      product = products.firstWhere(
        (p) => p['analysisLineId'] == analysisLineId,
      );
    } else {
      final material = _fixtureMaterial(data, materialLineId!);
      final anchorId = 'anchor-$materialLineId';
      material['planAnchorAnalysisLineId'] = anchorId;
      product = products.firstWhere(
        (p) => p['analysisLineId'] == anchorId,
        orElse: () {
          final created = <String, dynamic>{
            'analysisLineId': anchorId,
            'sourceType': 'MAKE_COMPONENT',
            'parentAnalysisLineId': 'product-1',
            'goodsId': material['goodsId'],
            'goodsCode': material['goodsCode'],
            'goodsName': material['goodsName'],
            'requestedQty': _num(material['additionalSupplyRecommendedQty']),
            'remainingQty': _num(material['additionalSupplyRecommendedQty']),
            'issuedPlanQty': 0,
            'canSchedule': true,
            'canIssueSurplus': true,
            'unitName': '个',
          };
          products.add(created);
          return created;
        },
      );
    }
    final remaining = _num(product['remainingQty']);
    final demand = surplusOnly ? 0.0 : (qty < remaining ? qty : remaining);
    product['issuedPlanQty'] = _num(product['issuedPlanQty']) + qty;
    product['remainingQty'] = remaining - demand;
    product['canSchedule'] = remaining - demand > 0;
    product['canIssueSurplus'] = true;
    product['latestPlanId'] = 'plan-${requests.length}';
  }
}

/// 一条已建锚点且计划排满(需求 2000 全部转入计划)的自制行。
Map<String, dynamic> _withIssuedMakeRow(
  Map<String, dynamic> data, {
  bool canIssueSurplus = true,
}) {
  (data['flatMaterials'] as List).add(
    _material(
      line: 'm-7',
      name: '已排满的自制件',
      confirmed: 'MAKE',
      netShortageQty: 2000,
      planAnchorAnalysisLineId: 'anchor-7',
    ),
  );
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  (data['products'] as List).add({
    'analysisLineId': 'anchor-7',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-1',
    'goodsId': 'g-m-7',
    'goodsCode': 'M-m-7',
    'goodsName': '已排满的自制件',
    'requestedQty': 2000,
    'submittedQty': 0,
    'approvedQty': 2000,
    'remainingQty': 0,
    'issuedPlanQty': 2000,
    'canSchedule': false,
    'canIssueSurplus': canIssueSurplus,
    'unitName': '个',
  });
  return data;
}

Map<String, dynamic> _material({
  required String line,
  required String name,
  required String? confirmed,
  required double netShortageQty,
  double? grossQty,
  double sharedFutureAvailableQty = 0,
  double inboundQty = 0,
  String nodeRole = 'BOM_NODE',
  int level = 1,
  List<Map<String, dynamic>> downstream = const [],
  String? parentLine,
  String? subcontractOutboundForm,
  String? planAnchorAnalysisLineId,
  // 本批分到的合格现货(默认 200)；已下达的父件给 0 = 「下了 1000 刚好覆盖需求 1000」。
  double stockQty = 200,
  // 同一物料挂在别棵产品树上的兄弟行：需求量记在需求行上，这里整个是 0。
  double requiredQty = 1000,
  // 2026-09-25 确认路线退役：夹具默认主档建议=采购（有建议的行进页自动确认）；
  // 要测「红框待选」形态的行传 null（服务端 REVIEW）。
  String? suggestion = 'BUY',
}) => {
  'subcontractOutboundForm': ?subcontractOutboundForm,
  'planAnchorAnalysisLineId': ?planAnchorAnalysisLineId,
  'materialLineId': line,
  'analysisLineId': 'product-1',
  'nodeRole': nodeRole,
  'nodeKey': 'n-$line',
  if (parentLine != null) 'parentNodeKey': 'n-$parentLine',
  'actionGroupKey': 'a-$line',
  'goodsId': 'g-$line',
  'goodsCode': 'M-$line',
  'goodsName': name,
  'colorName': '本色',
  'unitName': '个',
  'unitId': 'unit-1',
  'level': level,
  'path': ['智能多功能插座', name],
  'requiredQty': requiredQty,
  'sourceRequiredQty': requiredQty,
  'allocatedAvailableQty': stockQty,
  'availableQty': stockQty,
  'shortageQty': requiredQty - stockQty > 0 ? requiredQty - stockQty : 0,
  'demandSupplyGapQty': requiredQty - stockQty > 0 ? requiredQty - stockQty : 0,
  'inboundQty': inboundQty,
  'additionalSupplyRecommendedQty': grossQty ?? netShortageQty,
  'netShortageQty': netShortageQty,
  'sharedFutureAvailableQty': sharedFutureAvailableQty,
  'sourceSuggestion': suggestion,
  'sourceConfirmed': confirmed,
  'routeConfirmed': confirmed != null,
  'controlStage': 'START',
  'hardGate': true,
  'actionable': true,
  'downstreamReferences': downstream,
};

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs next) => state = next;
}
