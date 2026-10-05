// ADR-102「一张表」：把分桶详情页与「父件 + 下层一起下单」弹窗的能力搬进主
// 物料表之后，这张表上新增的行为由本文件守着。
//
// 守的是**口径**不是像素：哪一行能填数、填的是「下单数量」还是「追加下单」、
// 哪一行的办理按钮该灰、没确认路线时表现成什么样。
import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_field.dart';
import 'package:uten_imp/features/production/widgets/material_preparation_status_style.dart';
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

/// 主表这一行的「允许超产比例」输入框。
Finder _rateField(String line) => find.descendant(
  of: find.byKey(
    ValueKey('material-analysis-overproduction-rate-${_groupKey(line)}'),
  ),
  matching: find.byType(TextField),
);
String _rateText(WidgetTester tester, String line) =>
    _qtyText(tester, _rateField(line));

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
  if (find.text('本次下单是否使用可用数量抵扣？').evaluate().isNotEmpty) {
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('继续')),
    );
    await tester.pumpAndSettle();
  }
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

List<({String method, String path, Map<String, dynamic>? body})>
_aggregateSubmits() => [
  for (final request in requests)
    if (request.path.endsWith('/aggregate-orders/submit')) request,
];

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
  Map<String, dynamic> withCoveredAppendPool(Map<String, dynamic> data) {
    _fixtureMaterial(data, 'm-3').addAll({
      'planningUncoveredQty': 0,
      'additionalSupplyRecommendedQty': 0,
      'netShortageQty': 0,
      'preparationPoolKey': 'append-public-pool',
      'preparationSharedAvailableQty': 300,
      'preparationOwnedAvailableQty': 0,
      'preparationUncoveredBeforeSharedQty': 0,
      'sharedFutureClaimableQty': 0,
      'mainWarehousePublicAvailableQty': 0,
    });
    return data;
  }

  Finder appendAvailable(String line, String quantity) => find.descendant(
    of: find.byKey(ValueKey('material-analysis-public-available-$line')),
    matching: find.text(quantity),
  );

  Future<void> finishAppend(WidgetTester tester, String quantity) async {
    await tester.enterText(_appendQty('m-3'), quantity);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settlePreview(tester);
  }

  Future<void> continueClaimChoice(
    WidgetTester tester, {
    required bool extra,
  }) async {
    await tester.tap(find.text(extra ? '保留余量，额外下单' : '优先使用可用余量'));
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('继续')),
    );
    await _settlePreview(tester);
  }

  for (final extra in [false, true]) {
    testWidgets('追加可用余量：需求已覆盖且仅权威公共池有量，选择${extra ? '额外下单' : '优先使用'}贯彻预览和提交', (
      tester,
    ) async {
      await _pump(
        tester,
        permissions: _overSupplyPermissions,
        overSupply: true,
        mutate: withCoveredAppendPool,
      );
      expect(_qtyText(tester, _appendQty('m-3')), '0');
      expect(appendAvailable('m-3', '300'), findsOneWidget);
      await finishAppend(tester, '100');
      expect(find.text('本次下单是否使用可用数量抵扣？'), findsOneWidget);
      expect(_submits(), isEmpty);
      expect(_aggregateSubmits(), isEmpty);
      await continueClaimChoice(tester, extra: extra);
      expect(appendAvailable('m-3', extra ? '300' : '200'), findsOneWidget);
      await _submitSelected(tester);
      expect(_aggregateSubmits(), hasLength(1));
      final submit = _aggregateSubmits().single.body!;
      expect(submit['skipAutoClaim'] == true, extra);
      expect(_records(submit['groups']).single['qty'], '100');
      final previews = requests.where(
        (request) => request.path.endsWith('/aggregate-orders/preview'),
      );
      expect(previews, isNotEmpty);
      expect(
        previews.every(
          (request) => (request.body?['skipAutoClaim'] == true) == extra,
        ),
        isTrue,
      );
      if (extra) {
        await finishAppend(tester, '50');
        expect(
          find.text('本次下单是否使用可用数量抵扣？'),
          findsOneWidget,
          reason: '上轮额外备货成功后，新一轮必须重新选择',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('追加可用余量：草稿已预扣到零仍询问，取消不写单且保留输入', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: withCoveredAppendPool,
    );
    await finishAppend(tester, '300');
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), isEmpty);
    expect(_qtyText(tester, _appendQty('m-3')), '300');
    expect(appendAvailable('m-3', '0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(
      find.text('本次下单是否使用可用数量抵扣？'),
      findsOneWidget,
      reason: '取消后提交兜底仍需取得本轮选择',
    );
    await continueClaimChoice(tester, extra: true);
    expect(appendAvailable('m-3', '300'), findsOneWidget);
    // 下达确认仍未同意，选择备货方式本身不得创建下游单。
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('追加可用余量：顶层自制已排满仍可保留余量追加，issue-plans带完整数量和跳过认领', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product = (data['products'] as List).first as Map;
        product.addAll(<String, dynamic>{
          'issuedPlanQty': 2000,
          'canSchedule': false,
          'canIssueSurplus': true,
          'remainingQty': 0,
          'latestPlanId': 'plan-1',
        });
        _fixturePlanAssignment(product);
        _fixtureMaterial(data, 'm-root').addAll({
          'preparationPoolKey': 'root-public-pool',
          'preparationSharedAvailableQty': 300,
          'preparationOwnedAvailableQty': 0,
          'preparationUncoveredBeforeSharedQty': 0,
          'sharedFutureClaimableQty': 0,
        });
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
    );
    await tester.enterText(_appendQty('m-root'), '100');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settlePreview(tester);
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsOneWidget);
    await continueClaimChoice(tester, extra: true);
    await _onlyRoot(tester);
    await _submitSelected(tester);
    expect(_submits(), hasLength(1));
    final submit = _submits().single;
    expect(submit.path, endsWith('/issue-plans'));
    expect(submit.body!['skipAutoClaim'], isTrue);
    expect(_records(submit.body!['lines']).single['qty'], 100);
  });

  testWidgets('追加可用余量：按物料汇总输入完成也询问，额外模式保留池余量并下足数量', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: withCoveredAppendPool,
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-3|本色|unit-1'),
    );
    await tester.enterText(field, '100');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settlePreview(tester);
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsOneWidget);
    await continueClaimChoice(tester, extra: true);
    expect(appendAvailable('AGGREGATE|g-m-3|本色|unit-1', '300'), findsOneWidget);
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    final submit = _aggregateSubmits().single.body!;
    expect(submit['skipAutoClaim'], isTrue);
    expect(_records(submit['groups']).single['qty'], '100');
  });

  testWidgets('追加可用余量：工具栏切换方式立即恢复或预扣余额，最终选择用于提交', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: withCoveredAppendPool,
    );
    await finishAppend(tester, '100');
    await continueClaimChoice(tester, extra: true);
    expect(appendAvailable('m-3', '300'), findsOneWidget);
    final switchUsage = find.byKey(
      const Key('material-preparation-supply-usage'),
    );
    expect(find.text('下单方式：保留余量，额外下单'), findsOneWidget);
    await tester.tap(switchUsage);
    await tester.pumpAndSettle();
    await continueClaimChoice(tester, extra: false);
    expect(appendAvailable('m-3', '200'), findsOneWidget);
    expect(find.text('下单方式：优先使用可用余量'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-3')), '100');
    await tester.tap(switchUsage);
    await tester.pumpAndSettle();
    await continueClaimChoice(tester, extra: true);
    expect(appendAvailable('m-3', '300'), findsOneWidget);
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), isEmpty);
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    expect(_aggregateSubmits().single.body!['skipAutoClaim'], isTrue);
    expect(
      _records(_aggregateSubmits().single.body!['groups']).single['qty'],
      '100',
    );
  });

  testWidgets('追加可用余量：旧编辑预览在途时切换方式，尾随预览重新读取当前选择', (tester) async {
    final firstPreview = Completer<void>();
    final previewModes = <bool>[];
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: withCoveredAppendPool,
      aggregatePreview: (body, data) async {
        previewModes.add(body['skipAutoClaim'] == true);
        if (previewModes.length == 1) await firstPreview.future;
        return _defaultAggregatePreview(body, data);
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-g-m-3|本色|unit-1')),
      '100',
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(previewModes, [false]);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留余量，额外下单'));
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('继续')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    firstPreview.complete();
    await _settlePreview(tester);
    expect(previewModes.length, greaterThan(1));
    expect(
      previewModes.skip(1),
      everyElement(isTrue),
      reason: '旧调用重试不能沿用旧模式覆盖本轮额外下单选择',
    );
    expect(appendAvailable('AGGREGATE|g-m-3|本色|unit-1', '300'), findsOneWidget);
  });

  testWidgets('追加可用余量：提交结果未确认时锁住方式并原样重试额外下单', (tester) async {
    final failures = <String, int>{'/aggregate-orders/submit': 503};
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: withCoveredAppendPool,
      failOn: failures,
    );
    await finishAppend(tester, '100');
    await continueClaimChoice(tester, extra: true);
    await _submitSelected(tester);
    final submitted = _aggregateSubmits().single.body!;
    expect(submitted['skipAutoClaim'], isTrue);
    expect(_records(submitted['groups']).single['qty'], '100');
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('material-preparation-supply-usage')),
          )
          .onPressed,
      isNull,
      reason: '结果未确认时不能改意图，否则界面方式会与原键重试内容不一致',
    );
    failures.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsNothing);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
    );
    await _settlePreview(tester);
    expect(_aggregateSubmits(), hasLength(2));
    expect(_aggregateSubmits().last.body, submitted);
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsNothing);
    expect(
      find.byKey(const Key('material-preparation-supply-usage')),
      findsNothing,
    );
  });

  for (final scenario in [
    (blocked: false, mandatory: false),
    (blocked: true, mandatory: false),
    (blocked: false, mandatory: true),
  ]) {
    final blocked = scenario.blocked, mandatory = scenario.mandatory;
    testWidgets(
      '提交性能：整树每层应用回包，辅助读取在结束后一次 blocked=$blocked mandatory=$mandatory',
      (tester) async {
        await _pump(
          tester,
          permissions: {
            ..._permissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          mutate: (data) {
            _deepProductAnalysis(data);
            (data['allowedActions'] as List).add('VIEW_FUTURE_TRANSFERS');
            return data;
          },
          defaultWorkshops: _workshopDefaultsFor(const [
            'parent-0',
            'parent-1',
            'parent-2',
            'deep-make',
            'deep-subcontract',
            'deep-inner',
          ]),
          afterWrite: (data) {
            for (final row in _records(data['flatMaterials'])) {
              if (row['goodsId'] != (mandatory ? 'deep-make' : 'deep-raw')) {
                continue;
              }
              row['owningWorkshopId'] = 'ws-1';
              row['owningWorkshopName'] = '学习车间${data['version']}';
            }
            return data;
          },
          aggregatePreview: (body, data) =>
              _deepProductPreview(body, data, blocked: blocked),
          aggregateSubmit: _deepProductSubmit,
          delayMs: 450,
        );
        for (var i = 0; i < 3; i++) {
          await _check(tester, _productCheckbox('product-$i'));
        }
        await _submitSelected(tester);
        expect(
          _aggregateSubmits(),
          hasLength(blocked ? 1 : 4),
          reason: ProviderScope.containerOf(
            tester.element(find.byType(ProductionMaterialAnalysisPage)),
          ).read(appNotificationProvider).map((n) => n.message).join('\n'),
        );
        final writes = requests
            .where(
              (r) =>
                  r.path.endsWith('/aggregate-orders/submit') ||
                  r.path.endsWith('/issue-plans'),
            )
            .toList();
        final lastWrite = requests.indexOf(writes.last);
        for (final suffix in ['/future-transfers', '/default-workshops']) {
          final reads = requests.where((r) => r.path.endsWith(suffix)).toList();
          final needsSetting = mandatory && suffix == '/default-workshops';
          expect(
            reads,
            hasLength(needsSetting ? 2 : 1),
            reason: '$suffix 辅助读取尾随一次，必需指派不得延后',
          );
          // Records compare by value: both GETs have equal method/path/body,
          // so indexOf(reads.last) would incorrectly find the first one.
          expect(
            requests.lastIndexWhere((r) => r.path.endsWith(suffix)),
            greaterThan(lastWrite),
          );
          if (needsSetting) {
            expect(
              requests.indexWhere((r) => r.path.endsWith(suffix)),
              lessThan(requests.indexOf(_aggregateSubmits().first)),
            );
            expect(
              _records(
                _aggregateSubmits().first.body!['groups'],
              ).single['workerId'],
              'w-1',
            );
          }
        }
        expect(
          requests.where((r) => r.path.endsWith('/issue-plans/preview')),
          isEmpty,
        );
        expect(_records(writes.first.body!['lines']), hasLength(3));
        if (blocked) {
          final shortage = find.byKey(const Key('child-shortage-dialog'));
          expect(shortage, findsOneWidget);
          final completed = _records(
            _aggregateSubmits().single.body!['groups'],
          ).single;
          expect(completed['route'], 'MAKE');
          expect(completed['materialLineIds'], [
            'shared-0',
            'shared-1',
            'shared-2',
          ]);
          expect(completed['qty'], '3000');
          for (final material in ['保护门', '压板', '底层铜件', '分支采购件']) {
            expect(
              find.descendant(of: shortage, matching: find.text(material)),
              findsWidgets,
              reason: '已下达功能件对应的未完成子料必须明确列出',
            );
          }
          expect(
            find.descendant(of: shortage, matching: find.text('待认领 1000个')),
            findsWidgets,
          );
        } else {
          expect(find.byType(AlertDialog), findsNothing);
        }
      },
    );
  }

  for (final obsolete in [true, false]) {
    testWidgets('提交性能：旧编辑预览取消不阻塞，当前同签名预览复用 obsolete=$obsolete', (tester) async {
      final first = Completer<void>();
      final previewOptions = <RequestOptions>[];
      var calls = 0;
      await _pump(
        tester,
        overSupply: true,
        permissions: _overSupplyPermissions,
        mutate: _threeSharedBuySources,
        requestObserver: (request) {
          if (request.path.endsWith('/aggregate-orders/preview')) {
            previewOptions.add(request);
          }
        },
        aggregatePreview: (body, data) async {
          final result = _sharedAggregatePreview(body, data);
          if (++calls == 1) await first.future;
          return result;
        },
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
      await tester.pump();
      expect(previewOptions, hasLength(1));
      if (obsolete) await tester.enterText(field, '3200');
      await tester.tap(
        find.byKey(const Key('material-analysis-submit-orders')),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (obsolete) {
        expect(previewOptions.first.cancelToken!.isCancelled, isTrue);
        expect(previewOptions, hasLength(2));
        expect(
          find.byType(AlertDialog),
          findsOneWidget,
          reason: '无需等旧请求回来才能确认',
        );
      } else {
        expect(previewOptions.first.cancelToken!.isCancelled, isFalse);
        expect(previewOptions, hasLength(1));
        expect(find.byType(AlertDialog), findsNothing);
        first.complete();
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('下达'),
        ),
      );
      await tester.pumpAndSettle();
      if (obsolete) first.complete();
      await tester.pumpAndSettle();
      expect(_aggregateSubmits(), hasLength(1));
      expect(
        _records(_aggregateSubmits().single.body!['groups']).single['qty'],
        obsolete ? '3200' : '3100',
      );
      expect(previewOptions, hasLength(obsolete ? 2 : 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('提交性能：主表旧层级读取实际取消，迟到回包不能恢复已下达输入', (tester) async {
    final pending = <RequestOptions>[];
    await _pump(
      tester,
      mutate: _withSubcontractPair,
      previewDelayMs: 3000,
      requestObserver: (request) {
        if (request.path.endsWith('/issue-plans/preview')) pending.add(request);
      },
    );
    await tester.enterText(_orderQty('m-s'), '700');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(pending, hasLength(1));
    expect(pending.single.cancelToken!.isCancelled, isFalse);
    await _submitSelected(tester);
    expect(pending.single.cancelToken!.isCancelled, isTrue);
    final parent = _aggregateSubmits()
        .expand((r) => _records(r.body!['groups']))
        .singleWhere((g) => (g['materialLineIds'] as List).contains('m-s'));
    expect(parent['qty'], '700');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(_orderQty('m-s'), findsNothing);
    expect(_appendQty('m-s'), findsOneWidget);
    expect(_nodeSelected(tester, 'm-s'), isFalse);
    expect(pending, hasLength(1));
  });

  testWidgets('准备最新：各产品独立填写并明确显示相同货品合计12000', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: _threeSharedBuySources,
    );
    await tester.enterText(_orderQty('shared-0'), '10000');
    await _settleRebuild(tester);
    expect(_qtyText(tester, _orderQty('shared-1')), '1000');
    expect(_qtyText(tester, _orderQty('shared-2')), '1000');
    await _check(tester, _rowCheckbox('shared-1'));
    await _check(tester, _rowCheckbox('shared-2'));
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(find.textContaining('同货品填写合计'), findsOneWidget);
    expect(find.textContaining('12000'), findsOneWidget);
    expect(find.textContaining('10000 + 1000 + 1000'), findsOneWidget);
    expect(_aggregateSubmits(), isEmpty);
  });

  testWidgets('准备最新：已下达根产品锁定真实指派，主档新归属不冒充工单指派', (tester) async {
    await _pump(
      tester,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      overSupply: true,
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root']),
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        ((data['products'] as List).first as Map).addAll(<String, Object>{
          'issuedPlanQty': 2000,
          'latestPlanId': 'actual-plan',
          'remainingQty': 0,
          'canSchedule': false,
          'canIssueSurplus': true,
          'planExecutionWorkshopId': 'actual-department',
          'planExecutionWorkshopName': '实际计划车间',
          'planExecutionResponsibleId': 'actual-worker',
          'planExecutionResponsibleName': '实际计划负责人',
        });
        _fixtureMaterial(data, 'm-root').addAll({
          'owningWorkshopId': 'new-master-department',
          'owningWorkshopName': '最新主档归属',
        });
        return data;
      },
    );
    final workshop = find.byKey(
      ValueKey('material-analysis-workshop-${_groupKey('m-root')}'),
    );
    final worker = find.byKey(
      ValueKey('material-analysis-worker-${_groupKey('m-root')}'),
    );
    expect(tester.widget(workshop), isA<Tooltip>());
    expect(tester.widget(worker), isA<Tooltip>());
    expect(
      find.descendant(of: workshop, matching: find.text('实际计划车间')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: worker, matching: find.text('实际计划负责人')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workshop, matching: find.byType(InkWell)),
      findsNothing,
    );
    // 2026-09-29「归属车间」列并入「生产车间」：主档车间名不再单独展示，
    // 只在无计划时作为生产车间列的默认带出（本例有计划，显示的是实际计划车间）。
    expect(find.text('最新主档归属'), findsNothing);
    await tester.enterText(_appendQty('m-root'), '200');
    await _settlePreview(tester);
    await _onlyRoot(tester);
    await _submitSelected(tester);
    final lines = _submits().single.body!['lines'] as List;
    expect((lines.single as Map)['departmentId'], 'actual-department');
    expect((lines.single as Map)['workerId'], 'actual-worker');
  });

  testWidgets('准备最新：选中输入期间同版本外部可用和主档变化仍刷新但不改输入选择', (tester) async {
    var reads = 0;
    await _pump(
      tester,
      mutate: (data) {
        _fixtureMaterial(data, 'm-2').addAll({
          'preparationPoolKey': 'pool',
          'preparationSharedAvailableQty': 10000,
          'preparationOwnedAvailableQty': 200,
          'preparationUncoveredBeforeSharedQty': 500,
          'owningWarehouseId': 'warehouse-1',
          'owningWarehouseName': '旧主档归属',
        });
        return data;
      },
      detailResponse: (data, count) {
        reads = count;
        if (count > 1) {
          _fixtureMaterial(data, 'm-2').addAll({
            'preparationSharedAvailableQty': 8000,
            'owningWarehouseId': 'new-warehouse',
            'owningWarehouseName': '新主档归属',
            'flowStage': 'BUY_WAIT_STOCK_IN',
          });
        }
        return data;
      },
    );
    await tester.enterText(_orderQty('m-2'), '123');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-2'), isTrue);
    await tester.pump(const Duration(seconds: 45));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_qtyText(tester, _orderQty('m-2')), '123');
    expect(_rowChecked(tester, 'm-2'), isTrue);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('material-analysis-public-available-m-2'),
        ),
        matching: find.text('7877'),
      ),
      findsOneWidget,
    );
    expect(find.text('新主档归属'), findsWidgets);
    expect(find.text('品质已通过 · 等待入库'), findsWidgets);
  });

  testWidgets('准备最新：晚到旧GET不回滚刚保存的主档，后续新主档变化能替换临时覆盖', (tester) async {
    final oldRead = Completer<Map<String, dynamic>>();
    Map<String, dynamic>? stale;
    var reads = 0;
    await _pump(
      tester,
      mutate: (data) {
        _fixtureMaterial(data, 'm-2').addAll({
          'owningWarehouseId': 'warehouse-1',
          'owningWarehouseName': '旧主档归属',
        });
        return data;
      },
      detailResponse: (data, count) {
        reads = count;
        if (count == 2) {
          stale = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          return oldRead.future;
        }
        if (count >= 3) {
          _fixtureMaterial(data, 'm-2').addAll({
            'owningWarehouseId': count == 3 ? 'main' : 'later-warehouse',
            'owningWarehouseName': count == 3 ? '综合主仓' : '入库后的最新归属',
          });
        }
        return data;
      },
    );
    await tester.enterText(_orderQty('m-2'), '123');
    await _settleRebuild(tester);
    await tester.pump(const Duration(seconds: 45));
    await tester.pump();
    expect(reads, 2);
    final field = find.byKey(
      const ValueKey('material-owning-warehouse-MATERIAL|m-2'),
    );
    tester.widget<InkWell>(field).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('综合主仓').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: field, matching: find.text('综合主仓')),
      findsOneWidget,
    );
    oldRead.complete(stale!);
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(
      find.descendant(of: field, matching: find.text('综合主仓')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 45));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: field, matching: find.text('入库后的最新归属')),
      findsOneWidget,
    );
    expect(_qtyText(tester, _orderQty('m-2')), '123');
    expect(_rowChecked(tester, 'm-2'), isTrue);
  });
  testWidgets('准备主表与采购桶同一待入库状态使用整格背景和配对前景', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _fixtureMaterial(data, 'm-2')['flowStage'] = 'BUY_WAIT_STOCK_IN';
        return data;
      },
    );
    final mainLabel = find.byKey(
      const ValueKey('material-preparation-status-MATERIAL|m-2'),
    );
    final style = tester
        .widget<MaterialPreparationStatusLabel>(mainLabel)
        .style;
    expect(style.phase, MaterialPreparationStatusPhase.awaitingReceipt);
    final background = find.ancestor(
      of: mainLabel,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color == style.background,
      ),
    );
    expect(
      background,
      findsWidgets,
      reason: '整格背景由MasterColumnDef.cellColor铺满',
    );
    final entry = find.byKey(const Key('material-analysis-entry-buy'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final bucketLabel = find.byKey(
      ValueKey('material-preparation-progress-${_groupKey('m-2')}'),
    );
    final bucketStyle = tester
        .widget<MaterialPreparationStatusLabel>(bucketLabel)
        .style;
    expect(bucketStyle.background, style.background);
    expect(bucketStyle.foreground, style.foreground);
    expect(bucketStyle.icon, style.icon);
  });
  testWidgets('精确供给片预算不把其它行用剩但本行不可采用的量当作覆盖', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        for (var i = 0; i < 3; i++) {
          _fixtureMaterial(data, 'shared-$i').addAll({
            'preparationPoolKey': 'xy-pool',
            'preparationSharedAvailableQty': 200,
            'preparationOwnedAvailableQty': 0,
            'preparationUncoveredBeforeSharedQty': 100,
            'preparationAdoptableSharedQty': 100,
            'preparationSharedSupplySlices': [
              {'key': 'X', 'availableQty': 100, 'adoptable': false},
              {'key': 'Y', 'availableQty': 100, 'adoptable': true},
            ],
            'additionalSupplyRecommendedQty': 100,
          });
        }
        return data;
      },
    );
    await _check(tester, _rowCheckbox('shared-1'));
    await _settleRebuild(tester);
    final available = find.byKey(
      const ValueKey('material-analysis-public-available-shared-0'),
    );
    final shortage = find.byKey(
      const ValueKey('material-analysis-net-shortage-shared-0'),
    );
    expect(
      find.descendant(of: available, matching: find.text('100')),
      findsOneWidget,
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还缺 100'));
    await _toggle(tester, _rowCheckbox('shared-1'));
    await _settleRebuild(tester);
    expect(
      find.descendant(of: available, matching: find.text('200')),
      findsOneWidget,
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还缺 0'));
  });
  testWidgets('草稿预算汇总输入4500在三个原来源只预占一次', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      aggregatePreview: _sharedAggregatePreview,
      mutate: (data) {
        _threeSharedBuySources(data);
        for (var i = 0; i < 3; i++) {
          _fixtureMaterial(data, 'shared-$i').addAll({
            'preparationPoolKey': 'same-pool',
            'preparationSharedAvailableQty': 10000,
            'preparationOwnedAvailableQty': 0,
            'preparationUncoveredBeforeSharedQty': 1000,
          });
        }
        return data;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1')),
      '4500',
    );
    await _settlePreview(tester);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey(
            'material-analysis-public-available-AGGREGATE|g-m-2|本色|unit-1',
          ),
        ),
        matching: find.text('5500'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      expect(
        find.descendant(
          of: find.byKey(
            ValueKey('material-analysis-public-available-shared-$i'),
          ),
          matching: find.text('5500'),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('缺追加权限的父行未选中，保留输入但不展开也不送预览', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await _settlePreview(tester);
    expect(_qtyText(tester, _appendQty('m-p')), '1500');
    expect(_rowChecked(tester, 'm-p'), isFalse);
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
    expect(previews, isEmpty);
  });
  testWidgets('草稿预算只扣选中有效输入，取消和清空恢复同料余额，私有量不外借', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (data) {
        _threeSharedBuySources(data);
        for (var i = 0; i < 3; i++) {
          _fixtureMaterial(data, 'shared-$i').addAll({
            'preparationPoolKey': 'same-goods|color|unit|warehouse',
            'preparationSharedAvailableQty': 10000,
            'preparationOwnedAvailableQty': i == 2 ? 200 : 0,
            'preparationUncoveredBeforeSharedQty': 1000,
          });
        }
        return data;
      },
    );
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
    expect(available('shared-0'), '10000');
    await tester.enterText(_orderQty('shared-0'), '1000');
    await _check(tester, _rowCheckbox('shared-0'));
    await _settleRebuild(tester);
    expect(available('shared-1'), '9000');
    expect(available('shared-2'), '9000');
    await _toggle(tester, _rowCheckbox('shared-0'));
    await _settleRebuild(tester);
    expect(_qtyText(tester, _orderQty('shared-0')), '1000');
    expect(available('shared-1'), '10000');
    await tester.enterText(_orderQty('shared-1'), '10000');
    await _settleRebuild(tester);
    expect(available('shared-0'), '0');
    expect(available('shared-2'), '0');
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(
              const ValueKey('material-analysis-net-shortage-shared-0'),
            ),
          )
          .message,
      contains('还缺 1000'),
    );
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(
              const ValueKey('material-analysis-net-shortage-shared-1'),
            ),
          )
          .message,
      contains('还缺 0'),
    );
    await tester.enterText(_orderQty('shared-1'), '');
    await _settleRebuild(tester);
    expect(available('shared-0'), '10000');
    expect(previews, isEmpty);
  });

  testWidgets('草稿预算只扣追加量，不把锁定的历史下单重复扣掉', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (data) {
        final line = _fixtureMaterial(data, 'm-3');
        line.addAll({
          'preparationPoolKey': 'm-3-pool',
          'preparationSharedAvailableQty': 10000,
          'preparationOwnedAvailableQty': 0,
          'preparationUncoveredBeforeSharedQty': 0,
        });
        return data;
      },
    );
    String available() => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('material-analysis-public-available-m-3'),
                ),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;
    expect(_orderQty('m-3'), findsNothing);
    expect(available(), '10000');
    await tester.enterText(_appendQty('m-3'), '1000');
    await _settleRebuild(tester);
    expect(available(), '9000');
    await _toggle(tester, _rowCheckbox('m-3'));
    await _settleRebuild(tester);
    expect(_qtyText(tester, _appendQty('m-3')), '1000');
    expect(available(), '10000');
  });

  testWidgets('取消父件选择保留手输但立即停止展开，预览也只传有效选择', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    await tester.enterText(_appendQty('m-p'), '2000');
    await _settlePreview(tester);
    expect(_qtyText(tester, _orderQty('m-pc')), '2000');
    await _toggle(tester, _rowCheckbox('m-p'));
    await _settlePreview(tester);
    expect(_qtyText(tester, _appendQty('m-p')), '2000');
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
    expect(_rowChecked(tester, 'm-pc'), isFalse);
    final count = previews.length;
    await _check(tester, _rowCheckbox('m-p'));
    await _settlePreview(tester);
    expect(previews.length, greaterThan(count));
    expect(
      (previews.last['typedOutputs'] as List).map(
        (value) => (value as Map)['materialLineId'],
      ),
      contains('m-p'),
    );
    expect(_qtyText(tester, _orderQty('m-pc')), '2000');
  });

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

  testWidgets('汇总输入6000未下单切回按产品：每行平分2000，撤销恢复1000(2026-09-27)', (tester) async {
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
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1')),
      '6000',
    );
    // 敲键当场平分：不等 300ms 去抖与服务端预览往返，立刻切视图也要看得到。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    // 三条来源行被汇总草稿接管并锁住，显示平分值(需要1000 + 公共3000平分1000)。
    expect(_orderQty('shared-0'), findsNothing);
    for (var i = 0; i < 3; i++) {
      final row = find.byKey(ValueKey('material-table-row-shared-$i'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('2000')),
        findsOneWidget,
        reason: '汇总总量 6000 必须平分回每条来源行(连通口径)',
      );
    }
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
  });

  testWidgets('汇总总量低于合计还需安排：输入即红框且拦下下单(2026-09-27)', (tester) async {
    await _pump(
      tester,
      overSupply: true,
      permissions: _overSupplyPermissions,
      mutate: _threeSharedBuySources,
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
    );
    final frame = find
        .ancestor(of: field, matching: find.byType(RequiredCellFrame))
        .first;
    await tester.enterText(field, '1000');
    await tester.pump();
    expect(
      tester.widget<RequiredCellFrame>(frame).isEmpty(),
      isTrue,
      reason: '总量低于三来源合计还需安排 3000，必须边输入边标红',
    );
    await tester.enterText(field, '3100');
    await tester.pump();
    expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isFalse);
    await tester.enterText(field, '1000');
    await tester.pump();
    expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isTrue);
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    expect(
      requests.where(
        (request) => request.path.endsWith('/aggregate-orders/preview'),
      ),
      isEmpty,
      reason: '低于下限的总量不能发出预览/下单请求',
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      ProviderScope.containerOf(
            tester.element(find.byType(ProductionMaterialAnalysisPage)),
          )
          .read(appNotificationProvider)
          .map((notice) => notice.message)
          .join('\n'),
      contains('不能低于'),
    );
  });

  testWidgets('已下达汇总追加900：平分进各来源追加格，撤销恢复0(2026-09-27)', (tester) async {
    await _pump(
      tester,
      overSupply: true,
      permissions: _overSupplyPermissions,
      mutate: (data) {
        _threeSharedBuySources(data);
        for (final material in _records(data['flatMaterials'])) {
          if (!(material['materialLineId'] as String).startsWith('shared-')) {
            continue;
          }
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
          material['aggregatePreparation'] = {
            'requiredQty': material['requiredQty'],
            'orderedQty': 1000,
            'allocatedOrderedQty': 1000,
            'totalOrderedQty': 3000,
            'orderedQtyExact': true,
            'planningUncoveredQty': 0,
            'netShortageQty': 0,
            'targetMaterialLineIds': <String>[],
            'actionable': true,
          };
          material['additionalSupplyRecommendedQty'] = 0;
          material['netShortageQty'] = 0;
        }
        data['supplyActions'] = [
          {
            'actionId': 'aggregate-action',
            'route': 'BUY',
            'operationType': 'AGGREGATE_SUPPLY',
            'requestedQty': 3000,
            'publicSurplusQty': 0,
          },
        ];
        return data;
      },
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    const aggregate = 'g-m-2|本色|unit-1';
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('material-aggregate-order-$aggregate')),
          )
          .data,
      '3000',
      reason: '已下达汇总行的下单数量锁成累计已下单',
    );
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-$aggregate')),
      '900',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    // 追加总量 900 在三来源间均分(各行已无缺口，纯追加=纯公共)。
    expect(_appendQty('shared-0'), findsNothing);
    for (var i = 0; i < 3; i++) {
      final row = find.byKey(ValueKey('material-table-row-shared-$i'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('300')),
        findsOneWidget,
        reason: '追加总量必须平分回每条来源行的追加格',
      );
    }
    await tester.tap(find.byKey(const Key('material-aggregate-cancel-drafts')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤销草稿'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_qtyText(tester, _appendQty('shared-0')), '0');
  });

  testWidgets('左上角全选连折叠分支一起选上；清全选也连折叠一起撤(2026-09-27)', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return data;
      },
    );
    // 折叠产品树：子件行整棵不渲染，但点左上角全选仍要选上它们(用户口径
    // 「即使列表是收起的，点左上角也是全选，包括收起的」)。
    final toggle = find.byKey(
      const ValueKey('material-table-toggle-PRODUCT|product-1'),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('material-table-row-m-6')),
      findsNothing,
      reason: '折叠后子件行不再渲染',
    );
    final headerSelectAll = find.byKey(
      const Key('master-data-table-select-all'),
    );
    await _check(tester, headerSelectAll);
    await tester.pumpAndSettle();
    // 展开回来：折叠期间被全选的子件必须已经勾上。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(_rowChecked(tester, 'm-6'), isTrue, reason: '收起的层级也要被全选覆盖');
    // 清全选同样要覆盖收起层级：再折叠 → 表头清空 → 展开 → 子件已撤勾。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    tester.widget<Checkbox>(headerSelectAll).onChanged!(false);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(_rowChecked(tester, 'm-6'), isFalse, reason: '清全选也要撤掉收起层级的勾');
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
    expect(find.textContaining('1 种组件按来源一次下达'), findsOneWidget);
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
    expect(group['sourceRequestedQtyByMaterialLineId'], {
      'shared-0': '1000',
      'shared-1': '1000',
      'shared-2': '1000',
    });
    expect(find.text('下单(0)'), findsOneWidget);
  });

  testWidgets('同料合单保留每行10000和1000的真实输入，公共可用随回执刷新', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: _threeSharedBuySources,
      aggregatePreview: _sharedAggregatePreview,
      aggregateSubmit: (body, data) {
        final result = _sharedAggregateSubmit(body, data);
        for (final material in _records(
          (result['analysis'] as Map)['flatMaterials'],
        )) {
          material['preparationAvailableQty'] = 9000;
        }
        return result;
      },
    );
    await tester.enterText(_orderQty('shared-0'), '10000');
    for (final line in const ['shared-1', 'shared-2']) {
      await _check(tester, _rowCheckbox(line));
    }
    await _settleRebuild(tester);
    await _submitSelected(tester);
    final input = _records(_aggregateSubmits().single.body!['groups']).single;
    expect(input['qty'], '12000');
    expect(input['sourceRequestedQtyByMaterialLineId'], {
      'shared-0': '10000',
      'shared-1': '1000',
      'shared-2': '1000',
    });
    for (final entry in const {
      'shared-0': '10000',
      'shared-1': '1000',
      'shared-2': '1000',
    }.entries) {
      expect(_orderQty(entry.key), findsNothing);
      expect(_appendQty(entry.key), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('material-table-row-${entry.key}')),
          matching: _issuedTooltip(entry.value),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            ValueKey('material-analysis-public-available-${entry.key}'),
          ),
          matching: find.text('9000'),
        ),
        findsOneWidget,
      );
    }
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
    (blocked: false, proof: true),
    (blocked: true, proof: true),
    (blocked: false, proof: false),
  ]) {
    final blockedSecondRound = scenario.blocked;
    testWidgets(
      '三产品四层混合全选保留原身份走完整DAG，第二轮阻断=$blockedSecondRound proof=${scenario.proof}',
      (tester) async {
        var block = blockedSecondRound;
        await _pump(
          tester,
          permissions: {
            ..._permissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          mutate: _deepProductAnalysis,
          defaultWorkshops: _workshopDefaultsFor(const [
            'parent-0',
            'parent-1',
            'parent-2',
            'deep-make',
            'deep-subcontract',
            'deep-inner',
          ]),
          aggregatePreview: (body, data) => _deepProductPreview(
            body,
            data,
            blocked: block,
            includeProof: scenario.proof,
          ),
          aggregateSubmit: _deepProductSubmit,
        );
        for (var i = 0; i < 3; i++) {
          await _check(tester, _productCheckbox('product-$i'));
        }
        await _submitSelected(tester);
        final firstWrites = List.of(_aggregateSubmits());
        expect(
          _submits().where((r) => r.path.endsWith('/issue-plans')),
          hasLength(1),
        );
        if (blockedSecondRound) {
          expect(firstWrites, hasLength(1));
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('下达'),
            ),
            findsNothing,
            reason: '第二轮不得丢失confirmed后暗中再弹确认',
          );
          final shortage = find.byKey(const Key('child-shortage-dialog'));
          expect(shortage, findsOneWidget);
          for (final material in ['保护门', '压板', '底层铜件', '分支采购件']) {
            expect(
              find.descendant(of: shortage, matching: find.text(material)),
              findsWidgets,
              reason: '部分成功后应明确提醒已下父件对应的未完成子料',
            );
          }
          for (final prefix in [
            'deep-sc',
            'deep-inner',
            'deep-raw',
            'deep-branch',
          ]) {
            for (var i = 0; i < 3; i++) {
              expect(
                _nodeSelected(tester, '$prefix-$i'),
                isTrue,
                reason: '未下达来源须保留选择和输入',
              );
            }
          }
          await tester.tap(find.byKey(const Key('child-shortage-later')));
          await tester.pumpAndSettle();
          block = false;
          await _submitSelected(tester);
          expect(
            _aggregateSubmits(),
            hasLength(3),
            reason: '只重试未完成轮，已成功第一层不重下',
          );
        } else {
          expect(firstWrites, hasLength(4));
        }
        final writes = blockedSecondRound
            ? [...firstWrites, ..._aggregateSubmits()]
            : firstWrites;
        expect(writes.map((r) => _records(r.body!['groups']).length), [
          1,
          2,
          1,
          1,
        ]);
        final sourceIds = <String>[];
        for (final request in writes) {
          for (final group in _records(request.body!['groups'])) {
            final ids = (group['materialLineIds'] as List).cast<String>();
            expect(ids, hasLength(3));
            expect(ids.any((id) => id.startsWith('canonical-')), isFalse);
            expect(group['qty'], '3000');
            expect(group['sourceRequestedQtyByMaterialLineId'], {
              for (final id in ids) id: '1000',
            });
            sourceIds.addAll(ids);
          }
        }
        expect(sourceIds.toSet(), {
          for (final prefix in [
            'shared',
            'deep-sc',
            'deep-inner',
            'deep-raw',
            'deep-branch',
          ])
            for (var i = 0; i < 3; i++) '$prefix-$i',
        });
        expect(sourceIds, hasLength(15));
        expect(find.textContaining('汇总生产用料'), findsNothing);
        for (final id in sourceIds) {
          expect(_orderQty(id), findsNothing);
          expect(_appendQty(id), findsOneWidget);
          expect(_nodeSelected(tester, id), isFalse);
        }
        expect(find.text('下单(0)'), findsOneWidget);
      },
    );
  }

  for (final scenario in [
    (manual: false, remaining: 2),
    (manual: true, remaining: 2),
    (manual: false, remaining: 0),
  ]) {
    final manualChild = scenario.manual;
    testWidgets(
      '父件采用已有供给后逐来源重算自动子量，保留手填 $manualChild remaining=${scenario.remaining}',
      (tester) async {
        await _pump(
          tester,
          permissions: {
            ..._overSupplyPermissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          overSupply: true,
          mutate: (data) {
            _aggregateDagAnalysis(data);
            (data['flatMaterials'] as List).removeWhere(
              (raw) => (raw as Map)['materialLineId'] == 'p',
            );
            final parentKey = _fixtureMaterial(
              data,
              'raw-direct',
            )['parentNodeKey'];
            for (final id in ['raw-direct', 'raw-deep']) {
              final child = _fixtureMaterial(data, id);
              child['parentNodeKey'] = parentKey;
              child['requiredQty'] = 6;
              child['additionalSupplyRecommendedQty'] = 6;
              child['netShortageQty'] = 6;
            }
            return data;
          },
          defaultWorkshops: _workshopDefaultsFor(const ['g-h']),
          aggregatePreview: _defaultAggregatePreview,
          aggregateSubmit: (body, data) {
            final result = _defaultAggregateSubmit(body, data);
            final inputs = _records(body['groups']);
            if ((inputs.single['materialLineIds'] as List).contains('h')) {
              final next = result['analysis'] as Map<String, dynamic>;
              for (final id in ['raw-direct', 'raw-deep']) {
                final child = _fixtureMaterial(next, id);
                child['requiredQty'] = scenario.remaining;
                child['additionalSupplyRecommendedQty'] = scenario.remaining;
                child['netShortageQty'] = scenario.remaining;
                if (scenario.remaining == 0) {
                  child['requirementState'] = 'INACTIVE_PARENT_COVERED';
                  child['actionable'] = false;
                }
              }
              if (scenario.remaining == 0) {
                final parent = _fixtureMaterial(next, 'h');
                parent['preparationAdoptedQty'] = 3;
                final preparation = parent['aggregatePreparation'] as Map;
                preparation['orderedQty'] = 0;
                preparation['allocatedOrderedQty'] = 0;
              }
            }
            return result;
          },
        );
        if (manualChild) {
          await tester.enterText(_orderQty('raw-deep'), '9');
          await _settleRebuild(tester);
        }
        for (final id in ['h', 'raw-direct', 'raw-deep']) {
          await _check(tester, _rowCheckbox(id));
        }
        await _submitSelected(tester);
        final writes = _aggregateSubmits();
        if (scenario.remaining == 0) {
          expect(writes, hasLength(1));
          expect(_nodeSelected(tester, 'raw-direct'), isFalse);
          expect(_nodeSelected(tester, 'raw-deep'), isFalse);
          expect(find.text('下单(0)'), findsOneWidget);
          return;
        }
        expect(writes, hasLength(2));
        final raw = _records(writes.last.body!['groups']).single;
        expect(raw['qty'], manualChild ? '11' : '4');
        expect(raw['sourceRequestedQtyByMaterialLineId'], {
          'raw-direct': '2',
          'raw-deep': manualChild ? '9' : '2',
        });
      },
    );
  }

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

  testWidgets('汇总委外是外部批次：只展示进度，不把同批来源和公共份重复算下单', (tester) async {
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
        action['documentType'] = 'SUBCONTRACT_APPLICATION';
        for (final material in _records(
          next['flatMaterials'],
        ).where((m) => (m['materialLineId'] as String).startsWith('shared-'))) {
          material['sourceConfirmed'] = 'SUBCONTRACT';
          final target = _records(material['downstreamReferences']).single;
          target['route'] = 'SUBCONTRACT';
          target['documentType'] = 'SUBCONTRACT_APPLICATION';
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
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey('material-aggregate-cancel-aggregate-action'),
            ),
          )
          .onPressed,
      isNotNull,
      reason: '委外汇总只建外部委外申请(ADR-143)，有下达委外权限即可整批撤回',
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
      expect(find.textContaining('追加原单'), findsOneWidget);
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
    expect(find.text('表头设置 16/16'), findsOneWidget);
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
      '生产车间',
      '负责人',
      '进度 / 待办',
    ]) {
      expect(find.text(label), findsWidgets, reason: '表头缺少「$label」列');
    }
    // 退役的列不能再出现（「可用数量」2026-09-25 起按公共口径回归；
    // 「归属车间」2026-09-29 起并入「生产车间」）。
    for (final retired in const ['在途未到', '公共认领未实收', '在途调拨', '归属车间']) {
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
    original['sourceRequiredQty'] = 1000;
    original['allocatedAvailableQty'] = 0;
    original['availableQty'] = 0;
    original['shortageQty'] = 0;
    original['demandSupplyGapQty'] = 0;
    original['additionalSupplyRecommendedQty'] = 0;
    original['netShortageQty'] = 0;
    original['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
    original['delegatedToAnalysisLineId'] = 'shared-anchor';
    original['aggregateDelegatedQty'] = 1000;
    original['aggregatePreparation'] = {
      'requiredQty': 1000,
      'orderedQty': ordered ? 1000 : 0,
      'allocatedOrderedQty': ordered ? 1000 : 0,
      'planningUncoveredQty': ordered ? 0 : 1000,
      'netShortageQty': ordered ? 0 : 1000,
      'targetMaterialLineIds': ['m-6-shared'],
      'actionable': true,
    };
    return data;
  }

  testWidgets('合单已下达仍保留原产品树：下单量锁定且原子件能直接追加', (tester) async {
    await _pump(
      tester,
      mutate: (data) => delegatedFixture(data, ordered: true),
    );
    // 结构：产品视图只有产品顶层，「汇总生产用料」批次行不再出现。
    expect(find.textContaining('汇总生产用料'), findsNothing);
    // 原行：下单格没有输入框，锁成本行份额 1000。
    expect(_orderQty('m-6'), findsNothing);
    expect(_appendQty('m-6'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6')),
        matching: find.text('1000'),
      ),
      findsWidgets,
      reason: '原行实际下单 1000 应显示在下单数量格里',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').contains('累计已下单 1000'),
      ),
      findsWidgets,
    );
    // 追加格是「—」并指路按物料汇总，不再是可编辑的 0。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('追加或撤回到「按物料汇总」'),
      ),
      findsNothing,
    );
  });

  testWidgets('草稿预算排除同一原件的canonical镜像，不重复私有量和共用余额', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        delegatedFixture(data, ordered: false);
        _fixtureMaterial(data, 'm-6').addAll({
          'preparationPoolKey': 'original-pool',
          'preparationSharedAvailableQty': 10000,
          'preparationOwnedAvailableQty': 100,
          'preparationUncoveredBeforeSharedQty': 1000,
        });
        _fixtureMaterial(data, 'm-6-shared').addAll({
          'preparationPoolKey': 'original-pool',
          'preparationSharedAvailableQty': 0,
          'preparationOwnedAvailableQty': 9900,
          'preparationUncoveredBeforeSharedQty': 4000,
        });
        return data;
      },
    );
    expect(
      find.byKey(const ValueKey('material-table-row-m-6-shared')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('material-analysis-public-available-m-6'),
        ),
        matching: find.text('10000'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('合单父件的未下单子件仍在原树填写下单量，不把转交需求冒充已下单', (tester) async {
    await _pump(
      tester,
      mutate: (data) => delegatedFixture(data, ordered: false),
    );
    expect(_qtyText(tester, _orderQty('m-6')), '1000');
    expect(_appendQty('m-6'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').contains('需求已转入共享制造批次'),
      ),
      findsNothing,
    );
  });

  // 2026-09-26 二轮：#31 只锁了成员行的直接子层(别名行)，孙层及更深仍显示成可填的
  // 0、进度整列「未下达」。服务端转交投影(AggregateDelegationProjection)把份额按
  // BOM 数学分摊到任意深度并给出目标行(aggregateTargetMaterialLineId)，进度列报
  // 目标行的真实阶段。守四条口径：
  // 1) 任意深度都不再给输入框；2) 各行锁成本行份额(1000/500/100)；
  // 3) 进度 = 「并入共享批次 · 目标真实阶段」；4) 已并入的行允许超产比例只读。
  Map<String, dynamic> nestedDelegatedFixture(Map<String, dynamic> data) {
    delegatedFixture(data, ordered: true);
    // 共享批次树上的中间层目标行(已采购下单)与孙层目标行。
    (data['flatMaterials'] as List).addAll([
      {
        ..._material(
          line: 'm-6c-shared',
          name: '中间连接件',
          confirmed: 'BUY',
          netShortageQty: 0,
          requiredQty: 500,
          stockQty: 0,
        ),
        'goodsId': 'g-m-6c',
        'goodsCode': 'M-m-6c',
        'analysisLineId': 'shared-anchor',
        'flowStage': 'BUY_REQUESTED',
        'downstreamReferences': [
          {
            'actionId': 'act-agg-child',
            'route': 'BUY',
            'status': 'REQUESTED',
            'documentNo': 'REQ-06C',
            'allocatedQty': 500,
          },
        ],
      },
    ]);
    // 原产品树的子层与孙层：需求都已转走，份额按 BOM 折算，目标行由服务端给出。
    (data['flatMaterials'] as List).addAll([
      for (final spec in [
        ('m-6c', '中间连接件', 500, 'm-6', 'm-6c-shared', 'BUY_REQUESTED'),
        ('m-6g', '触点簧片', 100, 'm-6c', 'm-6g-shared', 'BUY_REQUESTED'),
      ])
        {
          ..._material(
            line: spec.$1,
            name: spec.$2,
            confirmed: 'BUY',
            netShortageQty: 0,
            requiredQty: 0,
            stockQty: 0,
            parentLine: spec.$4,
          ),
          'goodsId': 'g-${spec.$1}',
          'goodsCode': 'M-${spec.$1}',
          'requirementState': 'DELEGATED_TO_MAKE_CHILD',
          'delegatedToAnalysisLineId': 'shared-anchor',
          'aggregateDelegatedQty': spec.$3,
          'aggregateTargetMaterialLineId': spec.$5,
          'aggregatePreparation': {
            'requiredQty': spec.$3,
            'orderedQty': spec.$3,
            'allocatedOrderedQty': spec.$3,
            'planningUncoveredQty': 0,
            'netShortageQty': 0,
            'targetMaterialLineIds': [spec.$5],
            'actionable': true,
          },
          'flowStage': spec.$6,
        },
    ]);
    // 孙层目标行挂在共享批次树更深处(展示用；精确目标行查找不再依赖物料键匹配)。
    (data['flatMaterials'] as List).add({
      ..._material(
        line: 'm-6g-shared',
        name: '触点簧片',
        confirmed: 'BUY',
        netShortageQty: 0,
        requiredQty: 100,
        stockQty: 0,
      ),
      'goodsId': 'g-m-6g',
      'goodsCode': 'M-m-6g',
      'analysisLineId': 'shared-anchor',
      'flowStage': 'BUY_REQUESTED',
      'downstreamReferences': [
        {
          'actionId': 'act-agg-grandchild',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'REQ-06G',
          'allocatedQty': 100,
        },
      ],
    });
    final original = _fixtureMaterial(data, 'm-6');
    original['aggregateTargetMaterialLineId'] = 'm-6-shared';
    original['flowStage'] = 'MAKE_IN_PROGRESS';
    return data;
  }

  testWidgets('嵌套合单的子孙件分别保留追加入口，原树进度直接报告真实阶段', (tester) async {
    await _pump(tester, mutate: nestedDelegatedFixture);
    // 子层与孙层都没有输入框(#31 时代孙层是可编辑的 0)。
    expect(_orderQty('m-6c'), findsNothing);
    expect(_orderQty('m-6g'), findsNothing);
    expect(_appendQty('m-6c'), findsOneWidget);
    expect(_appendQty('m-6g'), findsOneWidget);
    // 各行锁成本行份额：子层 500、孙层 100(按 BOM 折算，不再是 0)。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6c')),
        matching: find.text('500'),
      ),
      findsWidgets,
      reason: '子层转交份额 500 应显示在下单数量格里',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6g')),
        matching: find.text('100'),
      ),
      findsWidgets,
      reason: '孙层转交份额 100 应显示在下单数量格里',
    );
    // 进度列报目标行的真实阶段(服务端 flowStage)，前缀点破进度挂在共享批次上——
    // 不再是「等待下发采购」这类未下达文案。
    expect(find.textContaining('并入共享批次 ·'), findsNothing);
    expect(find.textContaining('生产中 · 可报工'), findsOneWidget);
    expect(find.textContaining('等待采购下单'), findsWidgets);
    // 允许超产比例：已并入共享批次的行只读，不再渲染输入框。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6')),
        matching: find.byType(ProductionOverproductionRateField),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message ?? '').contains('允许超产比例随工单锁定'),
        ),
      ),
      findsOneWidget,
    );
  });

  // 已是共享批次来源的行(还有未撤回的 AGGREGATE_SUPPLY 引用)单独下达时也要走
  // 汇总通道——服务端会把这次的量并进那张还挂着的批次，而不是在按产品通道另起
  // 一条申请(2026-09-26)。
  for (final foreignOriginal in [false, true]) {
    testWidgets(
      'canonical预览必须同时证明原来源范围和精确目标 foreignOriginal=$foreignOriginal',
      (tester) async {
        await _pump(
          tester,
          permissions: _overSupplyPermissions,
          overSupply: true,
          mutate: nestedDelegatedFixture,
          aggregatePreview: (body, data) {
            final preview = _aggregateDagPreview(body, data);
            final group = _records(preview['groups']).single;
            group['sources'] = [
              <String, dynamic>{
                'materialLineId': foreignOriginal
                    ? 'm-6g-shared'
                    : 'm-6c-shared',
                'originalMaterialLineIds': [
                  foreignOriginal ? 'another-original' : 'm-6g',
                ],
                'allocatedQty': 0,
              },
            ];
            return preview;
          },
        );
        await tester.enterText(_appendQty('m-6g'), '200');
        await _settleRebuild(tester);
        await _submitSelected(tester);
        expect(_aggregateSubmits(), isEmpty);
        expect(_nodeSelected(tester, 'm-6g'), isTrue);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('material-table-row-m-6g')),
            matching: find.text('200'),
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('原树采购子件使用同一办理缺口应用起订建议并保留手填', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (data) {
        nestedDelegatedFixture(data);
        final material = _fixtureMaterial(data, 'm-6c');
        material['minOrderQty'] = 1000;
        material['orderMultipleQty'] = 100;
        material['flowStage'] = 'BUY_PENDING_ISSUE';
        (material['aggregatePreparation'] as Map).addAll(<String, Object>{
          'orderedQty': 0,
          'allocatedOrderedQty': 0,
          'planningUncoveredQty': 500,
          'netShortageQty': 500,
        });
        final target = _fixtureMaterial(data, 'm-6c-shared');
        target['downstreamReferences'] = <Object>[];
        target['flowStage'] = 'BUY_PENDING_ISSUE';
        return data;
      },
    );
    expect(_qtyText(tester, _orderQty('m-6c')), '1000');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('按起订量与整包装建议下单 1000'),
      ),
      findsOneWidget,
    );
    await tester.enterText(_orderQty('m-6c'), '600');
    await _settleRebuild(tester);
    expect(_qtyText(tester, _orderQty('m-6c')), '600');
  });

  testWidgets('旧预览缺proof且没有精确桥时拒绝canonical，不按相同货品猜来源', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (data) {
        nestedDelegatedFixture(data);
        (_fixtureMaterial(data, 'm-6g')['aggregatePreparation']
                as Map)['targetMaterialLineIds'] =
            <String>[];
        return data;
      },
      aggregatePreview: (body, data) {
        final preview = _aggregateDagPreview(body, data);
        _records(preview['groups']).single['sources'] = [
          <String, dynamic>{'materialLineId': 'm-6g-shared', 'allocatedQty': 0},
        ];
        return preview;
      },
    );
    await tester.enterText(_appendQty('m-6g'), '200');
    await _settleRebuild(tester);
    await _submitSelected(tester);
    expect(_aggregateSubmits(), isEmpty);
    expect(_nodeSelected(tester, 'm-6g'), isTrue);
  });

  testWidgets('合单后的孙件单独追加仍提交原行身份和逐行数量', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: nestedDelegatedFixture,
      aggregatePreview: _aggregateDagPreview,
      aggregateSubmit: (body, data) {
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        next['fingerprint'] = 'f' * 64;
        final preparation =
            _fixtureMaterial(next, 'm-6g')['aggregatePreparation'] as Map;
        preparation['orderedQty'] = 300;
        preparation['allocatedOrderedQty'] = 300;
        return {'analysis': next, 'batches': <Object>[]};
      },
    );
    await tester.enterText(_appendQty('m-6g'), '200');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-6g'), isTrue);
    await _submitSelected(tester);
    final submitted = requests.singleWhere(
      (request) => request.path.endsWith('/aggregate-orders/submit'),
    );
    final group = (submitted.body!['groups'] as List).single as Map;
    expect(group['materialLineIds'], ['m-6g']);
    expect(group['qty'], '200');
    expect(group['sourceRequestedQtyByMaterialLineId'], {'m-6g': '200'});
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('material-table-row-m-6g')),
        matching: _issuedTooltip('300'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('追加或撤回到「按物料汇总」'), findsNothing);
  });

  testWidgets('已是共享批次来源的单行单独下达也走汇总通道，不另起按产品申请(2026-09-26)', (tester) async {
    await _pump(
      tester,
      permissions: {
        ..._permissions,
        Perm.productionMaterialAnalysisGenerate,
        Perm.productionMaterialAnalysisNotify,
      },
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final root = Map<String, dynamic>.from(
          _fixtureMaterial(data, 'm-root'),
        );
        root['requiredQty'] = 0;
        root['sourceRequiredQty'] = 0;
        root['availableQty'] = 0;
        root['allocatedAvailableQty'] = 0;
        root['shortageQty'] = 0;
        root['demandSupplyGapQty'] = 0;
        root['additionalSupplyRecommendedQty'] = 0;
        root['netShortageQty'] = 0;
        data['flatMaterials'] = [
          root,
          {
            ..._material(
              line: 'm-merge',
              name: '已并入批次的共享料',
              confirmed: 'BUY',
              netShortageQty: 600,
              requiredQty: 600,
              stockQty: 0,
            ),
            'downstreamReferences': [
              {
                'actionId': 'aggregate-action',
                'route': 'BUY',
                'status': 'REQUESTED',
                'documentType': 'PURCHASE_REQUEST',
                'documentId': 'agg-req',
                'documentNo': 'CS-AGG-1',
                'allocatedQty': 1000,
              },
            ],
          },
        ];
        data['supplyActions'] = [
          {
            'actionId': 'aggregate-action',
            'route': 'BUY',
            'operationType': 'AGGREGATE_SUPPLY',
            'requestedQty': 1000,
            'publicSurplusQty': 0,
          },
        ];
        return data;
      },
      aggregatePreview: (body, data) {
        final group = (body['groups'] as List).single as Map;
        return {
          'analysisId': data['analysisId'],
          'version': data['version'],
          'fingerprint': data['fingerprint'],
          'previewFingerprint': 'e' * 64,
          'analysis': data,
          'groups': [
            {
              'clientGroupKey': group['clientGroupKey'],
              'compatibilityKey': 'shared-append',
              'route': 'BUY',
              'goodsId': 'g-m-merge',
              'goodsName': '已并入批次的共享料',
              'unitId': 'unit-1',
              'unitName': '个',
              'sourceRequiredQty': 1600,
              'orderedQty': 1000,
              'remainingQty': 600,
              'requestedQty': double.parse(group['qty'].toString()),
              'publicExtraQty': 0,
              'safetyQty': 0,
              'existingBatchId': 'shared-batch-1',
              'sources': [
                {
                  'materialLineId': 'm-merge',
                  'analysisLineId': 'product-1',
                  'sourceLabel': '智能多功能插座',
                  'allocationPriority': 1,
                  'sourceRequiredQty': 1600,
                  'remainingQty': 600,
                  'allocatedQty': double.parse(group['qty'].toString()),
                  'orderedQty': 1000,
                },
              ],
              'sharedBomChildren': <Object>[],
            },
          ],
        };
      },
      aggregateSubmit: (body, data) {
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        next['fingerprint'] = 'f' * 64;
        final material = _fixtureMaterial(next, 'm-merge');
        material['additionalSupplyRecommendedQty'] = 0;
        material['netShortageQty'] = 0;
        return {'analysis': next, 'replayed': false, 'batches': <Object>[]};
      },
    );
    // 已下达过 1000 的行：本次的量从「追加下单」列填(下单数量列已锁成累计量)，
    // 填完勾这一行(与叶子行下单测试同一交互顺序)。
    await tester.enterText(_appendQty('m-merge'), '600');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await _check(tester, _rowCheckbox('m-merge'));
    await tester.pumpAndSettle();
    requests.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    // 单行也要说明合并语义(追加并回共享批次)。
    expect(find.textContaining('相同物料自动合单'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    // 走汇总通道一次提交这一行；按产品通道的 /notify 一条都不发。
    final writes = requests
        .where((request) => request.path.endsWith('/aggregate-orders/submit'))
        .toList();
    expect(writes, hasLength(1));
    final group = _records(writes.single.body!['groups']).single;
    expect(group['materialLineIds'], ['m-merge']);
    expect(group['qty'], '600');
    expect(
      _submits().where((request) => request.path.endsWith('/notify')),
      isEmpty,
    );
  });

  testWidgets('主表追加格也带动子层：在已下达父件的追加格填数，子件按新数量重算', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      previewDelayMs: 3000,
    );
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
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
    await _pump(
      tester,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      overSupply: true,
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
    );
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

  for (final parentQty in ['2000', '1000']) {
    testWidgets('父件填同默认或部分量仍选中有缺口子件 $parentQty', (tester) async {
      await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
        mutate: _withConfirmedMakeSubtree,
        defaultWorkshops: _workshopDefaultsFor(const [
          'g-m-root',
          'g-m-hv5g001',
          'g-m-nested',
        ]),
        preview: _previewRootOnlySubtree,
      );
      await tester.enterText(_orderQty('m-root'), '');
      await tester.pump();
      await tester.enterText(_orderQty('m-root'), parentQty);
      await _settlePreview(tester);
      for (final line in ['m-hv5g001', 'm-nested', 'm-leaf']) {
        expect(_rowChecked(tester, line), isTrue);
      }
      await tester.enterText(_orderQty('m-root'), '');
      await _settlePreview(tester);
      for (final line in ['m-hv5g001', 'm-nested', 'm-leaf']) {
        expect(_rowChecked(tester, line), isFalse);
      }
    });
  }

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

  testWidgets('父件改量会选中尚未渲染的下一页子件', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        _withConfirmedMakeSubtree(data);
        final leaf = _fixtureMaterial(data, 'm-leaf');
        (data['flatMaterials'] as List).addAll(<Map<String, dynamic>>[
          for (var index = 0; index < 110; index++)
            {
              ...leaf,
              'materialLineId': 'm-extra-$index',
              'actionGroupKey': 'a-m-extra-$index',
              'nodeKey': 'node-extra-$index',
              'goodsId': 'goods-extra-$index',
              'goodsCode': 'ZZ${index.toString().padLeft(3, '0')}',
            },
        ]);
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const [
        'g-m-root',
        'g-m-hv5g001',
        'g-m-nested',
      ]),
      preview: _previewRootOnlySubtree,
    );
    expect(_orderQty('m-extra-109'), findsNothing);
    await tester.enterText(_orderQty('m-root'), '3000');
    await _settleRebuild(tester);
    expect(_nodeSelected(tester, 'm-extra-109'), isTrue);
    expect(find.text('下单(114)'), findsOneWidget);
    await _settlePreview(tester);
    expect(_nodeSelected(tester, 'm-extra-109'), isTrue);
  });

  testWidgets('部分下单后原格仍有缓存：追加预览只提交当前追加量', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: _withConfirmedMakeSubtree,
      defaultWorkshops: _workshopDefaultsFor(const [
        'g-m-root',
        'g-m-hv5g001',
        'g-m-nested',
      ]),
      preview: _previewRootOnlySubtree,
    );
    await tester.enterText(_orderQty('m-root'), '500');
    await _settleRebuild(tester);
    await _onlyRoot(tester);
    await _submitSelected(tester);
    expect(_orderQty('m-root'), findsNothing);
    expect(_qtyText(tester, _appendQty('m-root')), '1500');
    previews.clear();
    await tester.enterText(_appendQty('m-root'), '200');
    await _settlePreview(tester);
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-root', 'qty': 200.0},
    ]);
  });

  testWidgets('数量填少了 / 填错了当场冒红，改对了红框就消失；父行改大让子行缺了也冒红', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
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
      find.ancestor(
        of: _transferButton('m-3'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message ?? '').contains('没有别的计划锁着这个物料'),
        ),
      ),
      findsOneWidget,
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

  testWidgets('有直属物料的委外件照常下达委外：数量可改、可勾，不要求车间指派', (tester) async {
    // ADR-143：委外节点不管有没有下层都只下达委外申请，有「下达委外」权限即可；
    // 直属物料照常作为需求节点按各自路线准备。
    await _pump(tester, mutate: _withDrawSubcontract);
    final field = tester.widget<TextField>(_orderQty('m-u'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '800');
    // 还没下达过：追加格仍是只读的。
    expect(_appendQty('m-u'), findsNothing);
    expect(_nodeSelected(tester, 'm-u'), isFalse);
    expect(_rowCheckbox('m-u'), findsOneWidget);
    expect(
      find.byKey(ValueKey('material-analysis-workshop-${_groupKey('m-u')}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('material-analysis-worker-${_groupKey('m-u')}')),
      findsNothing,
    );
  });

  testWidgets('缺 BOM 的委外件：进度列显示已通知研发和任务号，下达委外的勾选框灰掉', (tester) async {
    // ADR-143 §二.3：委外件没有维护直属物料时不能下达(服务端同样拒绝)，系统已自动
    // 通知研发完善；研发保存后分析自动刷新，标记随之消失。
    await _pump(tester, mutate: _withBomMissingSubcontract);
    expect(find.text('缺 BOM·已通知研发(RD0042)'), findsWidgets);
    final box = tester.widget<Checkbox>(_rowCheckbox('m-nb'));
    expect(box.value, isFalse);
    expect(box.onChanged, isNull);
    expect(_nodeSelected(tester, 'm-nb'), isFalse);
    // 表头全选也带不上它。
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );
    expect(table.selectedIds.contains(_groupKey('m-nb')), isFalse);
    // 有直属物料的委外件照常可勾(只拦缺 BOM 的那一行)。
    final ok = tester.widget<Checkbox>(_rowCheckbox('m-u'));
    expect(ok.onChanged, isNotNull);
  });

  testWidgets('缺 BOM 的委外件：右键「下达委外」同样不可执行(与勾选框同一判定)', (tester) async {
    await _pump(tester, mutate: _withBomMissingSubcontract);
    Future<bool> issueEnabled(String line) async {
      final cell = find
          .descendant(
            of: find.byKey(ValueKey('material-table-row-$line')),
            matching: find.text(line == 'm-nb' ? '缺BOM的委外件' : '有直属物料的委外件'),
          )
          .first;
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(cell),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final item = find.ancestor(
        of: find.text('下达委外'),
        matching: find.byType(InkWell),
      );
      expect(item, findsWidgets);
      final enabled = tester.widget<InkWell>(item.first).onTap != null;
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      return enabled;
    }

    expect(await issueEnabled('m-nb'), isFalse);
    expect(await issueEnabled('m-u'), isTrue);
  });

  test('物料行读取缺 BOM 标记与研发任务号，缺省为未缺', () {
    final missing = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'm-1',
      'actionable': true,
      'bomMissing': true,
      'rdTaskNo': 'RD0042',
    });
    expect(missing.bomMissing, isTrue);
    expect(missing.rdTaskNo, 'RD0042');
    final normal = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'm-2',
      'actionable': true,
    });
    expect(normal.bomMissing, isFalse);
    expect(normal.rdTaskNo, isNull);
  });

  testWidgets('多下过的委外子件按委外申请算已下达(含同一行动的公共份)，没有车间锚点', (tester) async {
    // ADR-143：委外行的「已下达」= 归本需求的分摊量 + 同一条行动记的公共备货份，
    // 与采购同一口径；不再按前置自制锚点的计划量算。
    await _pump(tester, mutate: _withOverIssuedSubcontractChild);
    expect(_orderQty('m-vc'), findsNothing);
    expect(_issuedTooltip('1400'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-vc')), '0');
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

  testWidgets('委外行采用制造来源时显示来源进度，不加任何前缀', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _withDrawSubcontract(data);
        final material = _fixtureMaterial(data, 'm-u');
        material['preparationAdoptedQty'] = 2;
        material['flowStage'] = 'MAKE_WAIT_STOCK_IN';
        return data;
      },
    );
    expect(find.text('等待实收入库'), findsOneWidget);
    expect(find.textContaining('前置自制'), findsNothing);
  });

  testWidgets('纯采用供给显示真实下单0和采用量，锁定原格并可继续追加', (tester) async {
    await _pump(
      tester,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (data) {
        final material = _fixtureMaterial(data, 'm-5');
        material['preparationAdoptedQty'] = 2;
        material['additionalSupplyRecommendedQty'] = 0;
        material['netShortageQty'] = 0;
        return data;
      },
    );
    expect(_orderQty('m-5'), findsNothing);
    expect(_appendQty('m-5'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-5')), '0');
    expect(find.text('采用 2'), findsOneWidget);
    expect(_issuedTooltip('0'), findsOneWidget);
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

  testWidgets('全选下单的提交顺序：父先子后——委外父件先于它的采购子件，采购最后一次', (tester) async {
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
    final submits = _aggregateSubmits();
    expect(submits, hasLength(2));
    final first = _records(submits.first.body!['groups']);
    final parent = first.singleWhere(
      (group) => group['route'] == 'SUBCONTRACT',
    );
    expect(parent['materialLineIds'], ['m-s']);
    expect(parent['qty'], '700');
    final child = _records(submits.last.body!['groups']).single;
    expect(child['materialLineIds'], ['m-sc']);
    // 子件按父件填的 700 换算(还需安排 800 → 700)，父件落地后照样送 700，不翻倍。
    expect(first.singleWhere((group) => group['route'] == 'BUY')['qty'], '500');
    expect(child['qty'], '700');
    // 提交期间与提交之后都不再补发层级预览：填过的数已随下达交还系统。
    // 假后端每段等 350ms，300ms 的去抖若没被挡住早就发出去了。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
    expect(
      requests.where(
        (request) => request.path.endsWith('/issue-plans/preview'),
      ),
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
        _fixturePlanAssignment(product);
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
    expect(_submits(), isEmpty);
    final submits = _aggregateSubmits();
    expect(submits, hasLength(1));
    expect(_records(submits.single.body!['groups']).single['route'], 'BUY');
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
        _fixturePlanAssignment(product);
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

  testWidgets('已下达根产品缺实际指派回包：锁定且明确阻止错误追加', (tester) async {
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
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
    );
    await tester.enterText(_appendQty('m-root'), '1000');
    await tester.pump();
    await _settleRebuild(tester);
    expect(_nodeSelected(tester, 'm-root'), isFalse);
    expect(_rowChecked(tester, 'm-6'), isFalse);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionMaterialAnalysisPage)),
    );
    bool blockedNotice(AppNotification notice) =>
        notice.message.contains('填了数但本次还下不了单') &&
        notice.message.contains('实际指派');
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
    final submits = _aggregateSubmits();
    expect(submits, hasLength(1));
    final quantity = _records(submits.single.body!['groups']).single;
    expect(quantity['materialLineIds'], ['m-2']);
    expect(quantity['qty'], '450');
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
    final submits = _aggregateSubmits();
    expect(submits, hasLength(2));
    final first = _records(submits.first.body!['groups']);
    final make = first.singleWhere((group) => group['route'] == 'MAKE');
    expect(make['materialLineIds'], ['m-6']);
    expect(make['qty'], '400');
    expect(make['allowedOverproductionRate'], 0.123456);
    expect(first.any((group) => group['route'] == 'SUBCONTRACT'), isTrue);
    expect(_records(submits.last.body!['groups']).single['route'], 'BUY');
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
    expect(_aggregateSubmits(), hasLength(1));
    final line = _records(_aggregateSubmits().single.body!['groups']).single;
    expect(line['allowedOverproductionRate'], 0);
  });

  // ADR-129 §2.10：只有人确认过的比例才记住。没人改过的格子送空值，由服务端
  // 按货品默认填写(DEFAULT)；人改过的按所填值明确提交(EXPLICIT)。
  testWidgets('允许超产比例没人改过：汇总下单不带比例，由服务端按货品默认填写', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
    );
    expect(_rateText(tester, 'm-6'), '10');
    await _check(tester, _rowCheckbox('m-6'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final group = _records(_aggregateSubmits().single.body!['groups']).single;
    expect(group['materialLineIds'], ['m-6']);
    expect(group['route'], 'MAKE');
    expect(group.containsKey('allowedOverproductionRate'), isFalse);
  });

  for (final typed in const [null, '12.5']) {
    testWidgets('顶层自制下达车间：比例${typed == null ? '没人改过不带' : '改过按所填值明确提交'}', (
      tester,
    ) async {
      await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
        mutate: (data) {
          (data['allowedActions'] as List).add('GENERATE_PLAN');
          return data;
        },
        defaultWorkshops: _workshopDefaultsFor(const ['g-m-root']),
      );
      expect(_rateText(tester, 'm-root'), '0');
      if (typed != null) {
        await tester.enterText(_rateField('m-root'), typed);
        await tester.pumpAndSettle();
      }
      await _onlyRoot(tester);
      await tester.pumpAndSettle();
      await _submitSelected(tester);
      final plans = _submits()
          .where((request) => request.path.endsWith('/issue-plans'))
          .toList();
      final line = _records(plans.single.body!['lines']).single;
      expect(line['analysisLineId'], 'product-1');
      if (typed == null) {
        expect(line.containsKey('allowedOverproductionRate'), isFalse);
      } else {
        expect(line['allowedOverproductionRate'], 0.125);
      }
    });
  }

  testWidgets('同料两来源比例按数值比较：10 与 10.0 是同一比例，按人改过的明确提交', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        (data['flatMaterials'] as List).add({
          ..._fixtureMaterial(data, 'm-6'),
          'materialLineId': 'm-6-copy',
          'nodeKey': 'n-m-6-copy',
          'actionGroupKey': 'a-m-6-copy',
        });
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
    );
    await tester.enterText(_rateField('m-6-copy'), '10.0');
    await tester.pumpAndSettle();
    await _check(tester, _rowCheckbox('m-6'));
    await _check(tester, _rowCheckbox('m-6-copy'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final group = _records(_aggregateSubmits().single.body!['groups']).single;
    expect(group['materialLineIds'], ['m-6', 'm-6-copy']);
    expect(group['allowedOverproductionRate'], 0.1);
    expect(find.textContaining('各来源超产比例不同'), findsNothing);
  });

  // 汇总草稿开着时新快照带来新的默认比例：汇总比例格跟着没人改过的来源刷新(提交
  // 按来源送空值，服务端填的就是新默认)；撤销草稿时预填的来源回到当前默认，仍不带比例。
  // 草稿里先在汇总比例格改过(来源成了人填的、不跟着刷新)再撤销，也回到当前默认，
  // 而不是草稿前的旧默认。
  for (final typedInDraft in const [false, true]) {
    testWidgets(
      '汇总草稿期间默认比例变了：${typedInDraft ? '汇总比例格改过的' : '汇总比例格跟着刷新'}，撤销后仍按当前默认不带比例',
      (tester) async {
        var newDefaults = false;
        await _pump(
          tester,
          permissions: {
            ..._permissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          mutate: (data) {
            (data['allowedActions'] as List).add('GENERATE_PLAN');
            (data['flatMaterials'] as List).add({
              ..._fixtureMaterial(data, 'm-6'),
              'materialLineId': 'm-6-copy',
              'nodeKey': 'n-m-6-copy',
              'actionGroupKey': 'a-m-6-copy',
            });
            return data;
          },
          detailResponse: (data, _) {
            if (newDefaults) {
              data['overproductionDefaults'] = {
                ...(data['overproductionDefaults'] as Map),
                'g-m-6': 0.15,
              };
            }
            return data;
          },
          defaultWorkshops: _workshopDefaultsFor(const ['g-m-6']),
        );
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-material')),
        );
        await tester.pumpAndSettle();
        final aggregateRate = find.descendant(
          of: find.byKey(
            const ValueKey('material-aggregate-rate-g-m-6|本色|unit-1'),
          ),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(aggregateRate).controller!.text, '10');
        await tester.enterText(
          find.byKey(const ValueKey('material-aggregate-qty-g-m-6|本色|unit-1')),
          '500',
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        if (typedInDraft) {
          await tester.enterText(aggregateRate, '12');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }

        newDefaults = true;
        await tester.pump(const Duration(seconds: 46));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(aggregateRate).controller!.text,
          typedInDraft ? '12' : '15',
        );

        await tester.tap(
          find.byKey(const Key('material-aggregate-cancel-drafts')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('撤销草稿'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        expect(_rateText(tester, 'm-6'), '15');
        expect(_rateText(tester, 'm-6-copy'), '15');
        await _check(tester, _rowCheckbox('m-6'));
        await _check(tester, _rowCheckbox('m-6-copy'));
        await tester.pumpAndSettle();
        await _submitSelected(tester);
        final group = _records(
          _aggregateSubmits().single.body!['groups'],
        ).single;
        expect(group['materialLineIds'], ['m-6', 'm-6-copy']);
        expect(group.containsKey('allowedOverproductionRate'), isFalse);
      },
    );
  }

  for (final typed in const [false, true]) {
    testWidgets('新快照带来新的默认比例：${typed ? '改过的格子不动' : '没改过的格子跟着刷新'}，已下达的不动', (
      tester,
    ) async {
      await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
        mutate: _withIssuedMakeRow,
        afterWrite: (data) => data
          ..['overproductionDefaults'] = {
            'g-m-root': 0,
            'g-m-6': 0.15,
            'g-m-7': 0.2,
          },
        defaultWorkshops: _workshopDefaultsFor(const ['g-m-6', 'g-m-7']),
      );
      Finder locked() => find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message?.startsWith('这一行已下达，允许超产比例随工单锁定') == true,
        ),
        matching: find.byType(Text),
      );
      expect(tester.widget<Text>(locked()).data, '10%');
      if (typed) {
        await tester.enterText(_rateField('m-6'), '12');
        await tester.pumpAndSettle();
      }
      // 只下一条采购行：回包是带新默认比例的新快照。
      await _check(tester, _rowCheckbox('m-2'));
      await tester.pumpAndSettle();
      await _submitSelected(tester);
      expect(
        _records(_aggregateSubmits().single.body!['groups']).single['route'],
        'BUY',
      );
      expect(_rateText(tester, 'm-6'), typed ? '12' : '15');
      expect(tester.widget<Text>(locked()).data, '10%');
    });
  }

  testWidgets('需要数量悬停说明本行按哪个用量算；表头仍不加说明', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _fixtureMaterial(data, 'm-6').addAll({
          'bomQty': 0.105,
          'designBomQty': 0.1,
          'actualBomQty': 0.105,
          'usageBasis': 'ACTUAL',
          'usageSampleCount': 12,
          'usageDefectRate': 0.0325,
        });
        _fixtureMaterial(data, 'm-2').addAll({
          'bomQty': 2,
          'designBomQty': 2,
          'usageBasis': 'DESIGN',
          'usageReason': 'NO_DATA',
        });
        _fixtureMaterial(data, 'm-root')['bomQty'] = 1;
        return data;
      },
    );
    String usage(String rowKey) => tester
        .widget<Tooltip>(
          find.byKey(ValueKey('material-analysis-usage-basis-$rowKey')),
        )
        .message!;
    expect(
      usage('MATERIAL|m-6'),
      '每件按真实使用数量 0.105 计算(12 批累计，设计 0.1，不良率 3.25%)',
    );
    // 原因文案与组装信息页同一份多语言映射。
    expect(
      usage('MATERIAL|m-2'),
      '每件按设计使用数量 2 计算：'
      '${lookupAppLocalizations(const Locale('zh')).bomDesignReasonNoData}',
    );
    // 顶层供给行没有 BOM 边，不给用量说明；数字本身照旧。
    expect(
      find.byKey(
        const ValueKey('material-analysis-usage-basis-PRODUCT|product-1'),
      ),
      findsNothing,
    );
    expect(_sourceRequiredText(tester, 'MATERIAL|m-6'), '1000');
    final required = tester
        .widget<MasterDataTableView<dynamic>>(
          find.byKey(const Key('material-analysis-material-table')),
        )
        .columns
        .singleWhere((column) => column.key == 'requiredQty');
    expect(required.info, isNull, reason: 'ADR-102 §12.8：需要数量表头只显示那几个字');
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
        _fixturePlanAssignment(product);
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
    ]);
    final rootLine = (submits.first.body?['lines'] as List).single as Map;
    expect(rootLine['analysisLineId'], 'product-1');
    expect(rootLine['qty'], 1500);
    // 第一段落地后快照里顶层已下 1500，而顶层填的 1500 还挂在 typedOutputs 上——原来
    // 这一刻的重估会把子树翻倍，m-7 的还需安排被估成正数，纯公共备货就被判成 false，
    // 服务端 409「当前分析需求已全部转入生产计划」整批停下(2026-09-23 对抗复查)。
    final childLine = _records(
      _aggregateSubmits().single.body!['groups'],
    ).single;
    expect(childLine['materialLineIds'], ['m-7']);
    expect(childLine['qty'], '500');
    expect(childLine['allowPublicExtra'], isTrue);
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
      failOn: const {'/aggregate-orders/submit': 409},
    );
    await _check(tester, _rowCheckbox('m-6'));
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), hasLength(1));
    final firstRequest = _aggregateSubmits().single.body;
    // 停在第一段：勾选一个都不撤，让人改了再试。
    expect(find.text('下单(2)'), findsOneWidget);
    // 当前页可以直接重试同一批，原来源与数量没有消失，也不强制切换视图。
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    expect(_aggregateSubmits().single.body!['groups'], firstRequest!['groups']);
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
        _fixturePlanAssignment(product);
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

  // ===== ADR-120 §8「该分开的分开」：同料来源做法不同自动分成几张工单 =====

  testWidgets('来源车间不同：全选下单自动分成两张工单，下层照父先子后并各接自己那张父单', (tester) async {
    final previewLog = <Map<String, dynamic>>[];
    await _pumpSplit(
      tester,
      mutate: _deepProductAnalysis,
      secondWorkshopLines: const {'shared-0'},
      goods: const ['deep-make', 'deep-subcontract', 'deep-inner'],
      aggregatePreview: (body, data) {
        final result = _deepProductPreview(body, data);
        previewLog.add(result);
        return result;
      },
      aggregateSubmit: _deepProductSubmit,
    );
    const draftKey = 'deep-make|本色|unit-1';
    // 汇总视图仍是一行，办理列直接写明按车间 / 负责人分成两张，悬浮逐张列数量。
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final note = find.byKey(
      const ValueKey('material-aggregate-split-$draftKey'),
    );
    expect(tester.widget<Text>(note).data, '按车间/负责人分成 2 张工单');
    final detail = _splitDetail(tester, note);
    expect(detail, contains('第 1 张  装配二车间 / 李四 / 超产 0%：1000 个'));
    expect(detail, contains('第 2 张  装配一车间 / 张三 / 超产 0%：2000 个'));

    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await _check(tester, _productCheckbox('product-$i'));
    }
    await _submitSelected(tester);
    final submits = _aggregateSubmits();
    expect(submits, hasLength(4), reason: _notices(tester));
    // 第一轮只有父件，分成两组一次提交；各组只带自己的来源和逐行数量。
    final parent = _records(submits.first.body!['groups']);
    expect(parent, hasLength(2));
    final byWorkshop = {
      for (final group in parent) group['departmentId']: group,
    };
    expect(byWorkshop['ws-2']!['materialLineIds'], ['shared-0']);
    expect(byWorkshop['ws-2']!['workerId'], 'w-2');
    expect(byWorkshop['ws-2']!['qty'], '1000');
    expect(byWorkshop['ws-2']!['sourceRequestedQtyByMaterialLineId'], {
      'shared-0': '1000',
    });
    expect(byWorkshop['ws-1']!['materialLineIds'], ['shared-1', 'shared-2']);
    expect(byWorkshop['ws-1']!['workerId'], 'w-1');
    expect(byWorkshop['ws-1']!['qty'], '2000');
    expect(byWorkshop['ws-1']!['sourceRequestedQtyByMaterialLineId'], {
      'shared-1': '1000',
      'shared-2': '1000',
    });
    for (final group in parent) {
      expect(group['clientGroupKey'], startsWith('$draftKey|part-'));
    }
    expect(
      parent.map((group) => group['clientGroupKey']).toSet(),
      hasLength(2),
    );
    // 下层在父件那轮之后才提交，原行身份不变、不按车间再拆(下层自己做法相同)；
    // 服务端按精确对应把 deep-sc-0 接到装配二车间那张父单的共享子行，其余两条
    // 接到装配一车间那张——父件不进合并键，只决定接在哪张父单下。
    final child = _records(
      submits[1].body!['groups'],
    ).firstWhere((group) => group['route'] == 'SUBCONTRACT');
    expect(child['clientGroupKey'], 'deep-subcontract|本色|unit-1');
    expect(child['materialLineIds'], ['deep-sc-0', 'deep-sc-1', 'deep-sc-2']);
    bool isChild(Map<String, dynamic> group) =>
        group['clientGroupKey'] == child['clientGroupKey'];
    final childPreview = _records(
      previewLog.lastWhere(
        (preview) => _records(preview['groups']).any(isChild),
      )['groups'],
    ).firstWhere(isChild);
    expect(
      {
        for (final source in _records(childPreview['sources']))
          source['materialLineId']: source['originalMaterialLineIds'],
      },
      {
        'canonical-${byWorkshop['ws-2']!['clientGroupKey']}-deep-sc': [
          'deep-sc-0',
        ],
        'canonical-${byWorkshop['ws-1']!['clientGroupKey']}-deep-sc': [
          'deep-sc-1',
          'deep-sc-2',
        ],
      },
    );
    expect(
      _records(submits.last.body!['groups']).map((group) => group['route']),
      everyElement('BUY'),
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final scenario in [
    (rates: const ['10', '10.0', '10'], parts: 1),
    (rates: const ['5', '10', '10.0'], parts: 2),
  ]) {
    testWidgets(
      '超产比例按数值比：${scenario.rates.join(' / ')} 分成 ${scenario.parts} 张工单',
      (tester) async {
        await _pumpSplit(tester, mutate: _threeSharedMakeSources);
        for (var i = 0; i < 3; i++) {
          tester
              .widget<ProductionOverproductionRateField>(
                find.byKey(
                  ValueKey(
                    'material-analysis-overproduction-rate-${_groupKey('shared-$i')}',
                  ),
                ),
              )
              .controller
              .text = scenario
              .rates[i];
        }
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-material')),
        );
        await tester.pumpAndSettle();
        final note = find.byKey(
          const ValueKey('material-aggregate-split-split-make|本色|unit-1'),
        );
        if (scenario.parts == 1) {
          expect(note, findsNothing, reason: '10 与 10.0 是同一个比例，不拆');
        } else {
          expect(tester.widget<Text>(note).data, '按比例分成 2 张工单');
        }
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          await _check(tester, _productCheckbox('product-$i'));
        }
        await _submitSelected(tester);
        final parent = _records(_aggregateSubmits().single.body!['groups']);
        expect(parent, hasLength(scenario.parts), reason: _notices(tester));
        if (scenario.parts == 1) {
          expect(parent.single['clientGroupKey'], 'split-make|本色|unit-1');
          expect(parent.single['allowedOverproductionRate'], 0.1);
          expect(parent.single['materialLineIds'], [
            'shared-0',
            'shared-1',
            'shared-2',
          ]);
          expect(parent.single['qty'], '3000');
        } else {
          expect(
            {
              for (final group in parent)
                group['allowedOverproductionRate']: group['materialLineIds'],
            },
            {
              0.05: ['shared-0'],
              0.1: ['shared-1', 'shared-2'],
            },
          );
          expect(parent.map((group) => group['departmentId']).toSet(), {
            'ws-1',
          });
        }
      },
    );
  }

  testWidgets('汇总视图手输总量分成两张：预览逐张回来归回同一汇总行，确认框逐张列出后一次提交', (tester) async {
    await _pumpSplit(
      tester,
      mutate: _threeSharedMakeSources,
      secondWorkshopLines: const {'shared-0'},
      aggregatePreview: _aggregateDagPreview,
    );
    const draftKey = 'split-make|本色|unit-1';
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    requests.clear();
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-$draftKey')),
      '4500',
    );
    await _settlePreview(tester);
    final previewBodies = [
      for (final request in requests)
        if (request.path.endsWith('/aggregate-orders/preview')) request.body!,
    ];
    expect(previewBodies, isNotEmpty);
    // 总量 4500 = 需要 3000 + 富余 1500：富余按两视图同一平分规则落到三行
    // (各 500)，所以装配二车间那张 1500、装配一车间那张 3000，合计不差。
    final groups = _records(previewBodies.last['groups']);
    expect(groups, hasLength(2));
    final byWorkshop = {
      for (final group in groups) group['departmentId']: group,
    };
    expect(byWorkshop['ws-2']!['qty'], '1500');
    expect(byWorkshop['ws-1']!['qty'], '3000');
    expect(
      byWorkshop['ws-2']!.containsKey('sourceRequestedQtyByMaterialLineId'),
      isFalse,
    );
    // 两张预览回来后仍是同一汇总行、同一草稿。
    final note = find.byKey(
      const ValueKey('material-aggregate-split-$draftKey'),
    );
    expect(tester.widget<Text>(note).data, '按车间/负责人分成 2 张工单');
    expect(_splitDetail(tester, note), contains('装配二车间 / 李四 / 超产 0%：1500 个'));
    expect(_splitDetail(tester, note), contains('装配一车间 / 张三 / 超产 0%：3000 个'));
    expect(find.text('撤销汇总草稿(1)'), findsOneWidget);

    requests.clear();
    await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget, reason: _notices(tester));
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining(
          '(第 1 张，共 2 张：装配二车间 / 李四 / 超产 0%)：本次 1500',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining(
          '(第 2 张，共 2 张：装配一车间 / 张三 / 超产 0%)：本次 3000',
        ),
      ),
      findsOneWidget,
    );
    await _confirmAggregateRound(tester);
    final submitted = _records(_aggregateSubmits().single.body!['groups']);
    expect(
      {for (final group in submitted) group['departmentId']: group['qty']},
      {'ws-2': '1500', 'ws-1': '3000'},
    );
    // 两张一起落地，草稿随之清掉(不会因第二张找不到草稿而残留)。
    expect(find.textContaining('撤销汇总草稿'), findsNothing);
  });

  testWidgets('编辑中轮询换了需要量：手输总量的汇总草稿按新快照重新平分拆出的工单数', (tester) async {
    var arrived = false;
    await _pumpSplit(
      tester,
      mutate: _threeSharedMakeSources,
      secondWorkshopLines: const {'shared-0'},
      aggregatePreview: _aggregateDagPreview,
      detailResponse: (data, count) {
        if (!arrived) return data;
        // 别人办了到货：装配二车间那条来源只剩 400 还需安排，版本进位。
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        next['fingerprint'] = '${next['version']}'.padLeft(64, 'c');
        _fixtureMaterial(next, 'shared-0')
          ..['availableQty'] = 600
          ..['allocatedAvailableQty'] = 600
          ..['shortageQty'] = 400
          ..['demandSupplyGapQty'] = 400
          ..['additionalSupplyRecommendedQty'] = 400
          ..['netShortageQty'] = 400;
        return next;
      },
    );
    const draftKey = 'split-make|本色|unit-1';
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('material-aggregate-qty-$draftKey')),
      '4500',
    );
    await _settlePreview(tester);
    final note = find.byKey(
      const ValueKey('material-aggregate-split-$draftKey'),
    );
    expect(_splitDetail(tester, note), contains('装配二车间 / 李四 / 超产 0%：1500 个'));

    arrived = true;
    await tester.pump(const Duration(seconds: 46));
    await _settlePreview(tester);
    // 4500 = 需要 400 + 1000 + 1000 + 富余 2100 (三行各 700)。
    final detail = _splitDetail(tester, note);
    expect(detail, contains('装配二车间 / 李四 / 超产 0%：1100 个'));
    expect(detail, contains('装配一车间 / 张三 / 超产 0%：3400 个'));
    // 按产品视图逐行同步平分数属于「汇总与按产品两视图连通」那项在途改动，
    // 未进 main 前这里只验分单数量随新快照重算。
    expect(tester.takeException(), isNull);
  });

  testWidgets('分单父件的下层经身份桥换到新共享行：各自的车间随桥带过去，下层照样分两张', (tester) async {
    await _pumpSplit(
      tester,
      mutate: (data) => _threeSharedMakeSources(data, children: true),
      secondWorkshopLines: const {'shared-0', 'split-child-0'},
      goods: const ['split-make', 'split-child'],
      aggregateSubmit: (body, data) =>
          (_records(body['groups']).first['materialLineIds'] as List).first
              .toString()
              .startsWith('shared-')
          ? _splitParentSubmit(body, data)
          : _defaultAggregateSubmit(body, data),
    );
    for (var i = 0; i < 3; i++) {
      await _check(tester, _productCheckbox('product-$i'));
    }
    await _submitSelected(tester);
    final submits = _aggregateSubmits();
    expect(submits, hasLength(2), reason: _notices(tester));
    expect(_records(submits.first.body!['groups']), hasLength(2));
    // 旧子件 split-child-0 在装配二车间，经桥换成第一张父单下的共享行；
    // 另两条在装配一车间，换成第二张父单下的共享行。新行没有主档归属，
    // 不继承的话都会落到学习默认的装配一车间、并成一张。
    final child = _records(submits.last.body!['groups']);
    expect(
      {
        for (final group in child)
          group['departmentId']: group['materialLineIds'],
      },
      {
        'ws-2': ['canonical-0-child'],
        'ws-1': ['canonical-1-child'],
      },
    );
    expect(
      {for (final group in child) group['departmentId']: group['workerId']},
      {'ws-2': 'w-2', 'ws-1': 'w-1'},
    );
    expect(
      {for (final group in child) group['departmentId']: group['qty']},
      {'ws-2': '1000', 'ws-1': '2000'},
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  // 2026-09-29 用户实机：物料分析准备页按产品视图，子层里带下级的父行（委外/自制）
  // 勾选框消失。根因：货品主档 min_qty（安全库存）>0 且公共可用为 0 时，安全补库
  // 缺口>0，非采购路线整行不可下达（`_routeBlockedBySafetyGap`），勾选框随之退役。
  // 老库重导(2026-09-28)把组装件的 min_qty 带了进来，此前全为 0 从不触发。
  testWidgets('安全补库缺口>0 的自制/委外父行无勾选框，采购子件不受影响', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        (data['flatMaterials'] as List).addAll([
          {
            ..._material(
              line: 'f-sc',
              name: '委外父行',
              confirmed: 'SUBCONTRACT',
              netShortageQty: 800,
            ),
            'mainWarehouseSafetyReplenishmentGapQty': 5000,
          },
          _material(
            line: 'f-sc-c',
            name: '委外父行的子件',
            confirmed: 'BUY',
            netShortageQty: 800,
            level: 2,
            parentLine: 'f-sc',
          ),
          {
            ..._material(
              line: 'f-mk',
              name: '自制父行',
              confirmed: 'MAKE',
              netShortageQty: 800,
            ),
            'mainWarehouseSafetyReplenishmentGapQty': 3000,
          },
          _material(
            line: 'f-mk-c',
            name: '自制父行的子件',
            confirmed: 'BUY',
            netShortageQty: 800,
            level: 2,
            parentLine: 'f-mk',
          ),
        ]);
        return data;
      },
    );
    for (final line in ['f-sc', 'f-mk']) {
      expect(
        find.byKey(ValueKey('material-table-row-$line')),
        findsOneWidget,
        reason: '父行 $line 应渲染出来',
      );
      expect(
        find
            .descendant(
              of: find.byKey(ValueKey('material-table-row-$line')),
              matching: find.byType(Checkbox),
            )
            .evaluate(),
        isEmpty,
        reason: '安全缺口>0 的非采购父行 $line 不该有勾选框',
      );
    }
    // 采购子件与安全缺口无关，照常有框可勾。
    await _check(tester, _rowCheckbox('f-sc-c'));
    await _settleRebuild(tester);
    expect(_nodeSelected(tester, 'f-sc-c'), isTrue);
  });

  // 同一场景的安全水位归零后（2026-09-29 数据修复口径：老库报警水位不继承为
  // 安全库存），自制/委外父行勾选框必须恢复——缺车间/负责人只是可豁免拦截。
  testWidgets('安全补库缺口=0 的自制/委外父行勾选框恢复且勾上生效', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        (data['flatMaterials'] as List).addAll([
          _material(
            line: 'f-sc',
            name: '委外父行',
            confirmed: 'SUBCONTRACT',
            netShortageQty: 800,
          ),
          _material(
            line: 'f-mk',
            name: '自制父行',
            confirmed: 'MAKE',
            netShortageQty: 800,
          ),
        ]);
        return data;
      },
    );
    for (final line in ['f-sc', 'f-mk']) {
      final checkbox = _rowCheckbox(line);
      expect(checkbox, findsWidgets, reason: '父行 $line 应有勾选框');
      expect(
        tester.widget<Checkbox>(checkbox).onChanged,
        isNotNull,
        reason: '父行 $line 的勾选框应可点',
      );
      await _check(tester, checkbox);
      await _settleRebuild(tester);
      expect(_nodeSelected(tester, line), isTrue, reason: '父行 $line 应可选中');
    }
  });
}

/// 两个车间的组织树：装配一车间(负责人张三)、装配二车间(负责人李四)。
const _twoWorkshopTree = <Map<String, dynamic>>[
  {
    'id': 'dept-prod',
    'code': 'DEPT_PROD',
    'name': '生产部',
    'level': '一级部门',
    'children': <Map<String, dynamic>>[
      {
        'id': 'ws-1',
        'code': 'WS-1',
        'name': '装配一车间',
        'level': '二级班组',
        'parentId': 'dept-prod',
        'managerId': 'w-1',
        'managerName': '张三',
      },
      {
        'id': 'ws-2',
        'code': 'WS-2',
        'name': '装配二车间',
        'level': '二级班组',
        'parentId': 'dept-prod',
        'managerId': 'w-2',
        'managerName': '李四',
      },
    ],
  },
];

/// 分单用例的页面：带两个车间的组织树；[secondWorkshopLines] 这些来源主档归属
/// 装配二车间(负责人李四)，其余按学习记忆落在装配一车间(张三)。
Future<void> _pumpSplit(
  WidgetTester tester, {
  required Map<String, dynamic> Function(Map<String, dynamic> data) mutate,
  Set<String> secondWorkshopLines = const {},
  List<String> goods = const ['split-make'],
  FutureOr<Map<String, dynamic>> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregatePreview,
  Map<String, dynamic> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregateSubmit,
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> data, int count)?
  detailResponse,
}) => _pump(
  tester,
  permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
  mutate: (data) {
    mutate(data);
    for (final line in secondWorkshopLines) {
      _fixtureMaterial(data, line)
        ..['owningWorkshopId'] = 'ws-2'
        ..['owningWorkshopName'] = '装配二车间';
    }
    return data;
  },
  defaultWorkshops: _workshopDefaultsFor([
    'parent-0',
    'parent-1',
    'parent-2',
    ...goods,
  ]),
  departmentTree: _twoWorkshopTree,
  aggregatePreview: aggregatePreview,
  aggregateSubmit: aggregateSubmit,
  detailResponse: detailResponse,
);

/// 办理列「分成 N 张工单」的悬浮说明。
String _splitDetail(WidgetTester tester, Finder note) => tester
    .widget<Tooltip>(
      find.ancestor(of: note, matching: find.byType(Tooltip)).first,
    )
    .message!;

/// 页面上弹过的提示，断言失败时带出来看。
String _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ProductionMaterialAnalysisPage)),
).read(appNotificationProvider).map((notice) => notice.message).join('\n');

/// 三个产品各有一条「功能件」自制来源(同货品 / 颜色 / 单位，已确认自制)。
/// [children] 为真时每条来源下再挂一条自制子件 split-child-<i>(压板)。
Map<String, dynamic> _threeSharedMakeSources(
  Map<String, dynamic> data, {
  bool children = false,
}) {
  _threeSharedBuySources(data);
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  for (var i = 0; i < 3; i++) {
    final source = _fixtureMaterial(data, 'shared-$i');
    source['goodsId'] = 'split-make';
    source['goodsName'] = '功能件';
    source['sourceConfirmed'] = 'MAKE';
    source['sourceSuggestion'] = 'MAKE';
    if (!children) continue;
    (data['flatMaterials'] as List).add(<String, dynamic>{
      ..._material(
        line: 'split-child-$i',
        name: '压板',
        confirmed: 'MAKE',
        netShortageQty: 1000,
        stockQty: 0,
        level: 2,
        suggestion: 'MAKE',
      ),
      'analysisLineId': 'product-$i',
      'goodsId': 'split-child',
      'parentNodeKey': source['nodeKey'],
      'sourceRequiredQty': 1000,
    });
  }
  return data;
}

/// 父件那一轮：每张父单(按请求顺序编号 0、1…)建一个共享锚点和一条共享子行
/// canonical-<序号>-child，原子件整体转交、不再可办理，只经身份桥换到新行
/// (新行没有主档归属车间)。
Map<String, dynamic> _splitParentSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = '${next['version']}'.padLeft(64, 'f');
  final bridges = <Map<String, dynamic>>[];
  final inputs = _records(body['groups']);
  for (var index = 0; index < inputs.length; index++) {
    final input = inputs[index];
    final ids = (input['materialLineIds'] as List).cast<String>();
    final anchor = 'anchor-$index';
    (next['products'] as List).add(<String, dynamic>{
      'analysisLineId': anchor,
      'sourceType': 'AGGREGATE_MAKE',
      'goodsId': 'split-make',
      'goodsName': '功能件',
      'requestedQty': double.parse(input['qty'].toString()),
      'issuedPlanQty': double.parse(input['qty'].toString()),
      'remainingQty': 0,
      'canSchedule': false,
      'canIssueSurplus': true,
    });
    final children = <Map<String, dynamic>>[];
    for (final id in ids) {
      final source = _fixtureMaterial(next, id);
      source['aggregatePreparation'] = <String, dynamic>{
        'requiredQty': 1000,
        'orderedQty': 1000,
        'allocatedOrderedQty': 1000,
        'totalOrderedQty': double.parse(input['qty'].toString()),
        'orderedQtyExact': true,
        'planningUncoveredQty': 0,
        'netShortageQty': 0,
        'targetMaterialLineIds': <String>[],
        'actionable': true,
      };
      source['additionalSupplyRecommendedQty'] = 0;
      source['netShortageQty'] = 0;
      children.addAll(
        _records(next['flatMaterials']).where(
          (row) =>
              row['analysisLineId'] == source['analysisLineId'] &&
              row['parentNodeKey'] == source['nodeKey'],
        ),
      );
    }
    final target = 'canonical-$index-child';
    final required = 1000.0 * children.length;
    (next['flatMaterials'] as List).add(<String, dynamic>{
      ...children.first,
      'materialLineId': target,
      'actionGroupKey': 'a-$target',
      'analysisLineId': anchor,
      'nodeKey': target,
      'parentNodeKey': null,
      'level': 1,
      'owningWorkshopId': null,
      'owningWorkshopName': null,
      'sourceRequiredQty': 0,
      'requiredQty': required,
      'shortageQty': required,
      'demandSupplyGapQty': required,
      'additionalSupplyRecommendedQty': required,
      'netShortageQty': required,
    });
    for (final original in children) {
      original['requiredQty'] = 0;
      original['additionalSupplyRecommendedQty'] = 0;
      original['netShortageQty'] = 0;
      original['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
      original['delegatedToAnalysisLineId'] = anchor;
      original['aggregateDelegatedQty'] = 1000;
    }
    bridges.add(<String, dynamic>{
      'fromMaterialLineIds': [
        for (final original in children) original['materialLineId'],
      ],
      'toMaterialLineId': target,
      'relativeBomPath': 'child',
      'requiredQty': required,
    });
  }
  return {
    'analysis': next,
    'replayed': false,
    'materialIdentityBridges': bridges,
    'batches': <Object>[],
  };
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
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> data, int count)?
  detailResponse,
  Map<String, dynamic> Function(
    Map<String, dynamic> data,
    Map<String, double> typed,
  )?
  preview,
  FutureOr<Map<String, dynamic>> Function(
    Map<String, dynamic> body,
    Map<String, dynamic> data,
  )?
  aggregatePreview,
  void Function(RequestOptions)? requestObserver,
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
  // 组织树(GET /org/departments/tree)：给了才接管部门仓库，各车间负责人从这里带出。
  List<Map<String, dynamic>>? departmentTree,
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
  var detailReads = 0;
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
        requestObserver?.call(request);
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
        } else if (departmentTree != null &&
            request.path == '/org/departments/tree') {
          result = departmentTree;
        } else if (request.path.contains('/aggregate-orders/actions/') &&
            request.path.endsWith('/cancel')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          result = aggregateCancel!(request.data as Map<String, dynamic>, data);
          data = Map<String, dynamic>.from(result as Map);
        } else if (request.path.endsWith('/aggregate-orders/preview')) {
          result = await (aggregatePreview ?? _defaultAggregatePreview)(
            request.data as Map<String, dynamic>,
            data,
          );
        } else if (request.path.endsWith('/aggregate-orders/submit')) {
          if (await _rejectIfConfigured(request, handler, failOn, delayMs)) {
            return;
          }
          result = (aggregateSubmit ?? _defaultAggregateSubmit)(
            request.data as Map<String, dynamic>,
            data,
          );
          data = Map<String, dynamic>.from((result as Map)['analysis'] as Map);
          if (afterWrite != null) {
            data = afterWrite(data);
            result = <String, dynamic>{
              ...Map<String, dynamic>.from(result),
              'analysis': data,
            };
          }
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
              // 多下过的委外子件：委外申请 1000 + 公共份 400 + 现货 200 盖住 1600。
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
          detailReads++;
          if (detailResponse != null) {
            data = await detailResponse(data, detailReads);
          }
          result = data;
        } else if (request.path.endsWith('/routes') &&
            request.method == 'PUT') {
          // 人工改供应方式走这条通道 (2026-09-27 起自动确认在服务端)——夹具
          // 对齐真实服务端，回写 confirmed(否则脏组永存，拖死后续下单拦截)。
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
        if (departmentTree != null)
          departmentRepositoryProvider.overrideWithValue(
            DioDepartmentRepository(api),
          ),
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

Map<String, dynamic> _deepProductAnalysis(Map<String, dynamic> data) {
  _threeSharedBuySources(data);
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  for (var i = 0; i < 3; i++) {
    final first = _fixtureMaterial(data, 'shared-$i');
    first['goodsId'] = 'deep-make';
    first['sourceConfirmed'] = 'MAKE';
    first['sourceSuggestion'] = 'MAKE';
    first['goodsName'] = '功能件';
    for (final spec in [
      ('deep-sc', '保护门', 'SUBCONTRACT', 'deep-subcontract', 'shared-$i', 2),
      ('deep-inner', '压板', 'MAKE', 'deep-inner', 'deep-sc-$i', 3),
      ('deep-raw', '底层铜件', 'BUY', 'deep-raw', 'deep-inner-$i', 4),
      ('deep-branch', '分支采购件', 'BUY', 'deep-branch', 'shared-$i', 2),
    ]) {
      final parent = _fixtureMaterial(data, spec.$5);
      (data['flatMaterials'] as List).add(<String, dynamic>{
        ..._material(
          line: '${spec.$1}-$i',
          name: spec.$2,
          confirmed: spec.$3,
          netShortageQty: 1000,
          stockQty: 0,
          level: spec.$6,
        ),
        'analysisLineId': 'product-$i',
        'goodsId': spec.$4,
        'parentNodeKey': parent['nodeKey'],
        'sourceRequiredQty': 1000,
      });
    }
  }
  return data;
}

Map<String, dynamic> _deepProductPreview(
  Map<String, dynamic> body,
  Map<String, dynamic> data, {
  bool blocked = false,
  bool includeProof = true,
}) {
  return {
    'analysisId': data['analysisId'],
    'version': data['version'],
    'fingerprint': data['fingerprint'],
    'previewFingerprint': 'deep-${data['version']}',
    'analysis': data,
    'groups': [
      for (final input in _records(body['groups']))
        (() {
          final ids = (input['materialLineIds'] as List).cast<String>();
          final first = _fixtureMaterial(data, ids.first);
          final effective = <String, List<String>>{};
          for (final id in ids) {
            final original = _fixtureMaterial(data, id);
            final targets =
                (original['aggregatePreparation']
                        as Map?)?['targetMaterialLineIds']
                    as List?;
            for (final target
                in targets?.isNotEmpty == true ? targets! : [id]) {
              effective.putIfAbsent(target as String, () => []).add(id);
            }
          }
          return <String, dynamic>{
            'clientGroupKey': input['clientGroupKey'],
            'goodsId': first['goodsId'],
            'goodsName': first['goodsName'],
            'route': input['route'],
            'requestedQty': double.parse(input['qty'].toString()),
            'publicExtraQty': 0,
            if (blocked && first['goodsId'] == 'deep-subcontract')
              'blockedReason': '本轮前置制造需重新核对',
            'sources': [
              for (final entry in effective.entries)
                {
                  'materialLineId': entry.key,
                  if (includeProof) 'originalMaterialLineIds': entry.value,
                  'allocatedQty': entry.value.fold<double>(
                    0,
                    (sum, id) =>
                        sum +
                        double.parse(
                          (input['sourceRequestedQtyByMaterialLineId']
                                  as Map)[id]
                              .toString(),
                        ),
                  ),
                  'sourceLabel': entry.value.join('/'),
                },
            ],
            'sharedBomChildren': <Object>[],
          };
        })(),
    ],
  };
}

Map<String, dynamic> _deepProductSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = '${next['version']}'.padLeft(64, 'f');
  final bridges = <Map<String, dynamic>>[];
  for (final input in _records(body['groups'])) {
    final ids = (input['materialLineIds'] as List).cast<String>();
    final amount = double.parse(input['qty'].toString());
    for (final id in ids) {
      final original = _fixtureMaterial(next, id);
      final previous = original['aggregatePreparation'] as Map?;
      original['aggregatePreparation'] = <String, dynamic>{
        'requiredQty': 1000,
        'orderedQty': 1000,
        'allocatedOrderedQty': 1000,
        'totalOrderedQty': amount,
        'orderedQtyExact': true,
        'planningUncoveredQty': 0,
        'netShortageQty': 0,
        'targetMaterialLineIds':
            previous?['targetMaterialLineIds'] ?? <String>[],
        'actionable': true,
      };
      original['additionalSupplyRecommendedQty'] = 0;
      original['netShortageQty'] = 0;
    }
    if (input['route'] == 'BUY') continue;
    final anchor = 'anchor-${input['clientGroupKey']}';
    (next['products'] as List).add(<String, dynamic>{
      'analysisLineId': anchor,
      'sourceType': 'AGGREGATE_MAKE',
      'goodsId': _fixtureMaterial(next, ids.first)['goodsId'],
      'goodsName': '内部执行',
      'requestedQty': amount,
      'issuedPlanQty': amount,
      'remainingQty': 0,
      'canSchedule': false,
      'canIssueSurplus': true,
    });
    final originals = _records(next['flatMaterials'])
        .where(
          (row) => (row['analysisLineId'] as String).startsWith('product-'),
        )
        .toList();
    final descendants = <String, List<Map<String, dynamic>>>{};
    for (final sourceId in ids) {
      final source = _fixtureMaterial(next, sourceId);
      final queue = <String>[source['nodeKey'] as String];
      for (var index = 0; index < queue.length; index++) {
        for (final child in originals.where(
          (row) =>
              row['analysisLineId'] == source['analysisLineId'] &&
              row['parentNodeKey'] == queue[index],
        )) {
          queue.add(child['nodeKey'] as String);
          final prefix = (child['materialLineId'] as String).replaceFirst(
            RegExp(r'-[0-2]$'),
            '',
          );
          descendants.putIfAbsent(prefix, () => []).add(child);
        }
      }
    }
    for (final entry in descendants.entries) {
      final target = 'canonical-${input['clientGroupKey']}-${entry.key}';
      final source = Map<String, dynamic>.from(entry.value.first);
      (next['flatMaterials'] as List).add(<String, dynamic>{
        ...source,
        'materialLineId': target,
        'actionGroupKey': 'action-$target',
        'analysisLineId': anchor,
        'nodeKey': target,
        'parentNodeKey': null,
        'sourceRequiredQty': 0,
        'requiredQty': 3000,
        'additionalSupplyRecommendedQty': 3000,
        'netShortageQty': 3000,
        'aggregatePreparation': null,
        'aggregateDelegatedQty': 0,
      });
      for (final original in entry.value) {
        original['requiredQty'] = 0;
        original['additionalSupplyRecommendedQty'] = 0;
        original['netShortageQty'] = 0;
        original['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
        original['delegatedToAnalysisLineId'] = anchor;
        original['aggregateDelegatedQty'] = 1000;
        original['aggregatePreparation'] = <String, dynamic>{
          'requiredQty': 1000,
          'orderedQty': 0,
          'allocatedOrderedQty': 0,
          'planningUncoveredQty': 1000,
          'netShortageQty': 1000,
          'targetMaterialLineIds': [target],
          'actionable': true,
        };
      }
      bridges.add(<String, dynamic>{
        'fromMaterialLineIds': [
          for (final original in entry.value) original['materialLineId'],
        ],
        'toMaterialLineId': target,
        'relativeBomPath': entry.key,
        'requiredQty': 3000,
      });
    }
  }
  return {
    'analysis': next,
    'materialIdentityBridges': bridges,
    'batches': <Object>[],
  };
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

Map<String, dynamic> _defaultAggregatePreview(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) => {
  'analysisId': data['analysisId'],
  'version': data['version'],
  'fingerprint': data['fingerprint'],
  'previewFingerprint': 'e' * 64,
  'analysis': data,
  'groups': [
    for (final group in _records(body['groups']))
      {
        'clientGroupKey': group['clientGroupKey'],
        'goodsId': _fixtureMaterial(
          data,
          (group['materialLineIds'] as List).cast<String>().first,
        )['goodsId'],
        'route': group['route'],
        'requestedQty': double.parse(group['qty'].toString()),
        'publicExtraQty': 0,
        'sources': [
          for (final id in (group['materialLineIds'] as List).cast<String>())
            {
              'materialLineId': id,
              'sourceLabel': id,
              'allocatedQty': double.parse(
                ((group['sourceRequestedQtyByMaterialLineId'] as Map?)?[id] ??
                        group['qty'])
                    .toString(),
              ),
            },
        ],
        'sharedBomChildren': <Object>[],
      },
  ],
};

Map<String, dynamic> _defaultAggregateSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = '${next['version']}'.padLeft(64, 'f');
  for (final group in _records(body['groups'])) {
    for (final id in (group['materialLineIds'] as List).cast<String>()) {
      final material = _fixtureMaterial(next, id);
      final quantity = double.parse(
        ((group['sourceRequestedQtyByMaterialLineId'] as Map?)?[id] ??
                group['qty'])
            .toString(),
      );
      final existing = material['aggregatePreparation'] as Map?;
      final residual = _num(
        existing?['planningUncoveredQty'] ??
            material['additionalSupplyRecommendedQty'],
      );
      final previous = existing != null
          ? _num(existing['orderedQty'])
          : _records(material['downstreamReferences']).fold<double>(
              0,
              (sum, target) => sum + _num(target['allocatedQty']),
            );
      final remaining = (residual - quantity).clamp(0.0, double.infinity);
      material['aggregatePreparation'] = {
        'requiredQty': existing?['requiredQty'] ?? material['requiredQty'],
        'orderedQty': previous + quantity,
        'allocatedOrderedQty': previous + quantity,
        'planningUncoveredQty': remaining,
        'netShortageQty': remaining,
        'targetMaterialLineIds':
            existing?['targetMaterialLineIds'] ?? <String>[],
        'actionable': true,
      };
      material['additionalSupplyRecommendedQty'] = remaining;
      material['netShortageQty'] = remaining;
      if (id == 'm-s') {
        // 父委外实际下达后，服务端快照把其我方供料子件按本次产量重算。
        final child = _fixtureMaterial(next, 'm-sc');
        child['requiredQty'] = quantity;
        child['additionalSupplyRecommendedQty'] = quantity;
        child['netShortageQty'] = quantity;
      }
    }
  }
  return {'analysis': next, 'batches': <Object>[]};
}

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
  final input = (body['groups'] as List).single as Map;
  final sourceQuantities = input['sourceRequestedQtyByMaterialLineId'] as Map?;
  final totalQuantity = double.parse((input['qty'] ?? 3100).toString());
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
    material['aggregatePreparation'] = {
      'requiredQty': material['requiredQty'],
      'orderedQty': sourceQuantities == null
          ? 1000
          : double.parse(
              sourceQuantities[material['materialLineId']].toString(),
            ),
      'allocatedOrderedQty': 1000,
      'totalOrderedQty': totalQuantity,
      'orderedQtyExact': sourceQuantities != null,
      'planningUncoveredQty': 0,
      'netShortageQty': 0,
      'targetMaterialLineIds': <String>[],
      'actionable': true,
    };
    material['additionalSupplyRecommendedQty'] = 0;
    material['netShortageQty'] = 0;
  }
  next['supplyActions'] = [
    {
      'actionId': 'aggregate-action',
      'route': 'BUY',
      'operationType': 'AGGREGATE_SUPPLY',
      'requestedQty': 3000,
      'publicSurplusQty': totalQuantity - 3000,
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
        'qty': totalQuantity,
        'publicExtraQty': totalQuantity - 3000,
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
      // 有直属物料的委外件照常下达委外申请(ADR-143)，所以追加格可填。
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

/// 已排满的自制父件(锚点 1000/1000) → **多下过**的委外子件(委外申请分摊 1000 + 同一
/// 行动的公共备货份 400) → 委外子件的自制直属物料(没下过)。
Map<String, dynamic> _withOverIssuedSubcontractChild(
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
  (data['supplyActions'] as List).add({
    'actionId': 'act-vc',
    'route': 'SUBCONTRACT',
    'operationType': 'SUPPLY',
    'requestedQty': 1000,
    'publicSurplusQty': 400,
  });
  (data['allowedActions'] as List).add('GENERATE_PLAN');
  final anchor = <String, dynamic>{
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
  };
  _fixturePlanAssignment(anchor);
  (data['products'] as List).add(anchor);
  return data;
}

/// 一个有直属物料(一个自制子件)的委外件，没下过单。ADR-143 起它与其它委外件
/// 一样只下达委外申请，直属物料按自己的路线准备。
Map<String, dynamic> _withDrawSubcontract(Map<String, dynamic> data) {
  (data['flatMaterials'] as List)
    ..add(
      _material(
        line: 'm-u',
        name: '有直属物料的委外件',
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

/// 有直属物料的委外件(可下达) + 一个缺 BOM 的委外件(服务端 bomMissing，研发任务
/// RD0042，ADR-143 §二.3)。
Map<String, dynamic> _withBomMissingSubcontract(Map<String, dynamic> data) {
  _withDrawSubcontract(data);
  (data['flatMaterials'] as List).add({
    ..._material(
      line: 'm-nb',
      name: '缺BOM的委外件',
      confirmed: 'SUBCONTRACT',
      netShortageQty: 500,
    ),
    'bomMissing': true,
    'rdTaskNo': 'RD0042',
  });
  return data;
}

/// 一对「委外父件 + 我方供料采购子件」，都还没下过单(提交顺序用例)。
Map<String, dynamic> _withSubcontractPair(Map<String, dynamic> data) {
  (data['flatMaterials'] as List)
    ..add(
      _material(
        line: 'm-s',
        name: '待外发委外父件',
        confirmed: 'SUBCONTRACT',
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
    product['planExecutionWorkshopId'] = line['departmentId'];
    product['planExecutionResponsibleId'] = line['workerId'];
    product['planExecutionWorkshopName'] =
        line['workshopName'] ?? product['planExecutionWorkshopName'] ?? '装配一车间';
    product['planExecutionResponsibleName'] ??= '张三';
  }
}

// These issued-plan fixtures explicitly belong to this actual workshop/worker.
void _fixturePlanAssignment(Map<dynamic, dynamic> product) =>
    product.addAll(<String, Object>{
      'planExecutionWorkshopId': 'ws-1',
      'planExecutionWorkshopName': '装配一车间',
      'planExecutionResponsibleId': 'w-1',
      'planExecutionResponsibleName': '张三',
    });

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
  for (final product
      in (data['products'] as List).cast<Map<String, dynamic>>()) {
    if (const ['anchor-7'].contains(product['analysisLineId'])) {
      _fixturePlanAssignment(product);
    }
  }
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
  String? planAnchorAnalysisLineId,
  // 本批分到的合格现货(默认 200)；已下达的父件给 0 = 「下了 1000 刚好覆盖需求 1000」。
  double stockQty = 200,
  // 同一物料挂在别棵产品树上的兄弟行：需求量记在需求行上，这里整个是 0。
  double requiredQty = 1000,
  // 2026-09-25 确认路线退役：夹具默认主档建议=采购(服务端建分析时按它自动
  // 确认, 2026-09-27 起页面不再补发)；要测「红框待选」形态的行传 null(服务端 REVIEW)。
  String? suggestion = 'BUY',
}) => {
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
