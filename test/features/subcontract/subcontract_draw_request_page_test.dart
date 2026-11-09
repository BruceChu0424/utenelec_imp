// 委外领料页(2026-11-09 第三轮单表改版)：行内按(计划行×仓库)填写领料数量、
// 分批领料、联合分配默认量、库存核对(按行契约)、行级 409 标红与幂等提交。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_draw.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_draw_request_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'fake_subcontract_draw_gateway.dart';

const _submitKey = Key('subcontract-draw-request-submit');
const _checkKey = Key('subcontract-draw-request-stock-check');
const _linesKey = Key('subcontract-draw-request-lines');
const _errorKey = Key('subcontract-draw-request-error');
const _fillKey = Key('subcontract-draw-request-fill-maximum');

Finder _inLines(Finder matching) =>
    find.descendant(of: find.byKey(_linesKey), matching: matching);

Finder _quantity(String identity) =>
    find.byKey(ValueKey('subcontract-draw-request-qty-$identity'));

const _rowA1 = 'item-1|plan-a|wh-1';
const _rowB1 = 'item-1|plan-b|wh-1';
const _rowA2 = 'item-2|plan-a|wh-1';

/// 仓库 wh-1 里物料A 的实时库存(kg)，409 场景用来模拟别人先领走一部分。
class _Stock {
  _Stock(this.kg);
  int kg;
}

/// 两个任务共用物料A(仓库共 [capacity] kg，每个委外件 2 kg)：item-1 另需物料B(每件 1 个)。
/// 候选行 = 计划行 × 仓；默认量来自联合分配，按行提交(lines)时原样回显并扣减共享库存。
(FakeSubcontractDrawGateway, _Stock) _gateway({int capacity = 200}) {
  final gateway = FakeSubcontractDrawGateway();
  final stock = _Stock(capacity);
  gateway.onPreview = (items) async {
    var left = stock.kg / 2;
    final tasks = <Map<String, dynamic>>[];
    final lines = <Map<String, dynamic>>[];
    var documents = 0;
    for (final item in items) {
      final own = item.orderItemId == 'item-1' ? 40 : 80;
      final batch = own < left ? own : left;
      double aQty;
      double bQty = 0;
      if (item.lines == null) {
        aQty = batch * 2;
        if (item.orderItemId == 'item-1') bQty = batch.toDouble();
      } else {
        double requested(
          String planItemId, {
          String warehouseId = 'wh-1',
        }) => item.lines!
            .where((line) =>
                line.planItemId == planItemId && line.warehouseId == warehouseId)
            .fold(0, (sum, line) => sum + num.parse(line.qty.toString()));
        aQty = requested('plan-a');
        bQty = requested('plan-b');
        if (aQty > stock.kg + 0.0001) {
          throw ApiException(
            'CONFLICT',
            '物料A 本批最多可领 ${stock.kg}',
            httpStatus: 409,
            details: <String, dynamic>{
              'kind': 'SUBCONTRACT_DRAW_QUANTITY_EXCEEDED',
              'quantities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'orderItemId': item.orderItemId,
                  'planItemId': 'plan-a',
                  'warehouseId': 'wh-1',
                  'maximumQtyExact': stock.kg.toString(),
                },
              ],
            },
          );
        }
      }
      // 套数以约束物料(A, 每件2kg)折算；物料B 每件1个同套。
      final qty = aQty / 2;
      num plain(double value) =>
          value == value.roundToDouble() ? value.toInt() : value;
      tasks.add(
        previewTaskJson(
          item.orderItemId,
          batchDrawableQty: batch,
          qty: qty,
          drawableQty: own,
          orderBillNo: item.orderItemId == 'item-1' ? 'WD-001' : 'WD-002',
          goodsName: item.orderItemId == 'item-1' ? '委外件A' : '委外件B',
        ),
      );
      lines.add(
        previewLineJson(
          item.orderItemId,
          'plan-a',
          qty: plain(aQty),
          warehouseAvailableQty: stock.kg,
        ),
      );
      if (item.orderItemId == 'item-1') {
        lines.add(
          previewLineJson(
            item.orderItemId,
            'plan-b',
            goodsId: 'material-b',
            goodsName: '物料B',
            qty: plain(bQty),
            warehouseAvailableQty: 999,
          ),
        );
      }
      if (aQty + bQty > 0) documents++;
      left -= qty;
    }
    return SubcontractDrawPreview.fromJson(<String, dynamic>{
      'tasks': tasks,
      'lines': lines,
      'documentCount': documents,
    });
  };
  return (gateway, stock);
}

Future<List<Object?>> _pump(
  WidgetTester tester,
  FakeSubcontractDrawGateway gateway, {
  List<String> ids = const ['item-1', 'item-2'],
  List<String>? planItemIds,
  Size size = const Size(1600, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final results = <Object?>[];
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await context.push<bool>(
                  RouteName.operationsSubcontractDrawRequestFor(
                    ids,
                    planItemIds: planItemIds,
                  ),
                ),
              ),
              child: const Text('打开领料页'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: RouteName.operationsSubcontractDrawRequest,
        builder: (_, state) => SubcontractDrawRequestPage(
          orderItemIds: state.uri.queryParameters['orderItemIds']!.split(','),
          planItemIds:
              state.uri.queryParameters['planItemIds']?.split(',') ?? const [],
          repository: gateway,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        // 未登录作用域：提交成功后的徽章重拉是空操作，不触发真实网络。
        authenticatedScopeProvider.overrideWithValue(null),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.subcontractOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开领料页'));
  await tester.pumpAndSettle();
  return results;
}

UtenButton _submit(WidgetTester tester) =>
    tester.widget<UtenButton>(find.byKey(_submitKey));

/// 首次提交现在先弹二次确认（防误触）：点提交 → 点「确认提交」。
/// 「重试领料」（结果未确认的续传）不弹，直接 tap 即可。
Future<void> _tapSubmitAndConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(_submitKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认提交'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('single table renders candidate rows with defaults', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    // 第三轮改版：一张表，列序 = 领料仓库|物料名称|编号|颜色|领料数量|仓库可用|委外单号|委外件名称。
    expect(find.text('出仓分配（按仓库）'), findsNothing);
    expect(find.byKey(const Key('subcontract-draw-request-tasks')), findsNothing);
    for (final label in [
      '领料仓库',
      '物料名称',
      '编号',
      '颜色',
      '领料数量',
      '仓库可用',
      '委外单号',
      '委外件名称',
    ]) {
      expect(_inLines(find.text(label)), findsOneWidget, reason: '缺列 $label');
    }
    // 默认量 = 联合分配：item-1 领 40(物料A 80kg、物料B 40 个)，item-2 领 60(物料A 120kg)。
    expect(
      tester.widget<UtenInput>(_quantity(_rowA1)).controller!.text,
      '80',
    );
    expect(
      tester.widget<UtenInput>(_quantity(_rowB1)).controller!.text,
      '40',
    );
    expect(
      tester.widget<UtenInput>(_quantity(_rowA2)).controller!.text,
      '120',
    );
    // 委外单号与委外件名称已拆列，不再拼成「EO · 名称」。
    expect(_inLines(find.text('WD-001')), findsWidgets);
    expect(_inLines(find.text('委外件A')), findsWidgets);
    expect(find.textContaining('·'), findsNothing);
    expect(_submit(tester).onPressed, isNotNull);
  });

  testWidgets('editing a row keeps the table and marks availability stale', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    await tester.enterText(_quantity(_rowA1), '30');
    await tester.pump();

    // 行不消失(输入面)，可用量提示为上次核对，提交让位给核对。
    expect(_quantity(_rowA1), findsOneWidget);
    expect(_inLines(find.text('上次核对 200 kg')), findsWidgets);
    expect(_submit(tester).onPressed, isNull);
    expect(find.byKey(_checkKey), findsOneWidget);
    expect(find.byKey(_fillKey), findsOneWidget);
  });

  testWidgets('typing keeps the focused row and controller state', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    await tester.showKeyboard(_quantity(_rowB1));
    final editable = find.descendant(
      of: _quantity(_rowB1),
      matching: find.byType(EditableText),
    );
    final before = tester.state<EditableTextState>(editable);
    await tester.enterText(_quantity(_rowB1), '25');
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editable),
      same(before),
      reason: '输入时不能重建输入框',
    );
    expect(tester.widget<EditableText>(editable).controller.text, '25');
  });

  testWidgets('check stock sends directed lines and refreshes availability', (
    tester,
  ) async {
    final (gateway, stock) = _gateway();
    await _pump(tester, gateway);

    // 分批：item-1 的物料A 只领 30kg(15 套)，物料B 领 15 个。
    await tester.enterText(_quantity(_rowA1), '30');
    await tester.enterText(_quantity(_rowB1), '15');
    // item-2 本次不领。
    await tester.enterText(_quantity(_rowA2), '');
    await tester.tap(find.byKey(_checkKey));
    await tester.pumpAndSettle();

    expect(gateway.previews.last, hasLength(1));
    final item = gateway.previews.last.single;
    expect(item.orderItemId, 'item-1');
    expect(item.lines, hasLength(2));
    expect(
      item.lines,
      contains(
        predicate<SubcontractDrawRequestLine>(
          (line) =>
              line.planItemId == 'plan-a' &&
              line.warehouseId == 'wh-1' &&
              line.qty == '30',
        ),
      ),
    );

    // 核对通过后可提交；可用量回到当前口径(不带「上次核对」)。
    expect(_submit(tester).onPressed, isNotNull);
    expect(_inLines(find.text('上次核对 200 kg')), findsNothing);
    expect(stock.kg, 200, reason: '核对是只读的，不扣库存');
  });

  testWidgets('submit sends grouped directed items per task', (tester) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    expect(find.textContaining('提交领料(2)'), findsOneWidget);
    await _tapSubmitAndConfirm(tester);

    expect(gateway.submits, hasLength(1));
    final (items, key) = gateway.submits.single;
    expect(items, hasLength(2));
    final first = items.singleWhere((item) => item.orderItemId == 'item-1');
    expect(
      first.lines!.map((line) => '${line.planItemId}:${line.qty}'),
      containsAll(['plan-a:80', 'plan-b:40']),
    );
    final second = items.singleWhere((item) => item.orderItemId == 'item-2');
    expect(
      second.lines!.map((line) => '${line.planItemId}:${line.qty}'),
      ['plan-a:120'],
    );
    expect(key, isNotEmpty);
  });

  testWidgets('row level stock error marks the row and keeps typed value', (
    tester,
  ) async {
    final (gateway, stock) = _gateway();
    await _pump(tester, gateway);

    // 别人先把共享的物料A 领到只剩 50：行级 409 带回 (计划行, 仓) 的上限。
    stock.kg = 50;
    await tester.enterText(_quantity(_rowA1), '70');
    await tester.pump();
    await tester.tap(find.byKey(_checkKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_errorKey), findsOneWidget);
    expect(_inLines(find.text('上次核对 200 kg')), findsWidgets);
    expect(
      tester.widget<UtenInput>(_quantity(_rowA1)).controller!.text,
      '70',
      reason: '手填量保留，等用户改小',
    );
    expect(_submit(tester).onPressed, isNull, reason: '超限后必须重新核对');
  });

  testWidgets('blank rows skip their task in the submission', (tester) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    await tester.enterText(_quantity(_rowA1), '');
    await tester.enterText(_quantity(_rowB1), '');
    await tester.tap(find.byKey(_checkKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('提交领料(1)'), findsOneWidget);
    await _tapSubmitAndConfirm(tester);
    final (items, _) = gateway.submits.single;
    expect(items, hasLength(1));
    expect(items.single.orderItemId, 'item-2');
  });

  testWidgets('invalid input shows an error and blocks submit', (tester) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    await tester.enterText(_quantity(_rowA1), '12.34567');
    await tester.pump();

    expect(_inLines(find.text('请输入非负数，最多 4 位小数')), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);
  });

  testWidgets('unassigned warehouse row stays visible but not editable', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    // item-2 的物料A 四处无库存：服务端出一条未定仓 0 行，任务不消失。
    gateway.onPreview = (items) async {
      final tasks = <Map<String, dynamic>>[];
      const lines = <Map<String, dynamic>>[
        {
          'orderItemId': 'item-2',
          'planItemId': 'plan-a',
          'warehouseId': null,
          'warehouseName': null,
          'goodsId': 'material-a',
          'goodsCode': 'M-material-a',
          'goodsName': '物料A',
          'colorId': 'color-1',
          'colorName': '本色',
          'unitId': 'unit-kg',
          'unitName': 'kg',
          'qty': 0,
          'qtyExact': '0',
          'warehouseAvailableQty': 0,
        },
      ];
      tasks.add(previewTaskJson('item-2', batchDrawableQty: 0, qty: 0));
      return SubcontractDrawPreview.fromJson(<String, dynamic>{
        'tasks': tasks,
        'lines': lines,
        'documentCount': 0,
      });
    };
    await _pump(tester, gateway, ids: const ['item-2']);

    expect(_inLines(find.text('未确定')), findsOneWidget);
    expect(_inLines(find.text('该物料暂无可用库存')), findsOneWidget);
    expect(tester.widget<UtenInput>(_quantity('item-2|plan-a|')).enabled, isFalse);
    expect(find.textContaining('提交领料(0)'), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);
  });

  testWidgets('fill maximum restores the server defaults', (tester) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);

    await tester.enterText(_quantity(_rowA1), '7');
    await tester.pump();
    await tester.tap(find.byKey(_fillKey));
    await tester.pumpAndSettle();

    expect(tester.widget<UtenInput>(_quantity(_rowA1)).controller!.text, '80');
    expect(find.byKey(_checkKey), findsNothing);
    expect(_submit(tester).onPressed, isNotNull);
  });

  testWidgets('uncertain submit retries the same directed items', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    var attempts = 0;
    gateway.onSubmit = (items, key) async {
      attempts++;
      if (attempts == 1) {
        throw NetworkException();
      }
      return SubcontractDrawSubmitResult.fromJson(const <String, dynamic>{
        'issueIds': ['issue-1'],
        'issueBillNos': ['SL-001'],
        'documentCount': 1,
        'replayed': false,
      });
    };
    await _pump(tester, gateway);

    await _tapSubmitAndConfirm(tester);
    expect(find.text('重试领料'), findsOneWidget);

    await tester.tap(find.byKey(_submitKey));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(gateway.submits, hasLength(2));
    final first = gateway.submits.first.$1;
    final second = gateway.submits.last.$1;
    expect(
      [
        for (final item in second)
          '${item.orderItemId}:${[
                for (final line in item.lines ?? const <SubcontractDrawRequestLine>[])
                '${line.planItemId}=${line.qty}',
              ].join(',')}',
      ],
      equals([
        for (final item in first)
          '${item.orderItemId}:${[
                for (final line in item.lines ?? const <SubcontractDrawRequestLine>[])
                '${line.planItemId}=${line.qty}',
              ].join(',')}',
      ]),
      reason: '续传保持原提交内容',
    );
  });

  testWidgets('whole batch conflict offers only going back', (tester) async {
    final gateway = FakeSubcontractDrawGateway();
    gateway.onPreview = (items) async => throw ApiException(
      'CONFLICT',
      '所选委外任务已领满、已结束领料或已不在您的可见范围内',
      httpStatus: 409,
    );
    await _pump(tester, gateway);

    expect(
      find.byKey(const Key('subcontract-draw-request-load-error')),
      findsOneWidget,
    );
    expect(find.text('返回委外任务中心'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
  });

  // 2026-11-09 任务中心「物料」列 → 物料弹窗选中物料 → 领料页只带所选物料。
  testWidgets(
    'material dialog selection previews per material and lists only chosen rows',
    (tester) async {
      final gateway = FakeSubcontractDrawGateway();
      gateway.onPreview = (items) async {
        final item = items.single;
        final lines = item.lines;
        // 按物料预览默认量 = 物料B 自己的可领上限 30；物料A 不在所选里，服务端仍回候选行(0)。
        final bQty = lines == null
            ? (item.planItemIds?.contains('plan-b') == true ? 30 : 0)
            : lines
                  .where((line) => line.planItemId == 'plan-b')
                  .fold<num>(0, (sum, line) => sum + num.parse('${line.qty}'));
        return SubcontractDrawPreview.fromJson(<String, dynamic>{
          'tasks': [previewTaskJson('item-1', batchDrawableQty: 0, qty: 0)],
          'lines': [
            previewLineJson('item-1', 'plan-a', qty: 0),
            previewLineJson(
              'item-1',
              'plan-b',
              goodsId: 'material-b',
              goodsName: '物料B',
              qty: bQty,
              warehouseAvailableQty: 30,
            ),
          ],
          'documentCount': bQty > 0 ? 1 : 0,
        });
      };
      await _pump(tester, gateway, ids: const ['item-1'], planItemIds: ['plan-b']);

      final first = gateway.previews.first.single;
      expect(first.planItemIds, ['plan-b'], reason: '首次预览按所选物料取默认量');
      expect(first.lines, isNull);
      expect(_quantity(_rowB1), findsOneWidget);
      expect(_quantity(_rowA1), findsNothing, reason: '没选中的物料A 不显示');
      expect(tester.widget<UtenInput>(_quantity(_rowB1)).controller!.text, '30');

      // 分批：本次只领 10，核对库存后提交——只提交物料B 这一行。
      await tester.enterText(_quantity(_rowB1), '10');
      await tester.pump();
      await tester.tap(find.byKey(_checkKey));
      await tester.pumpAndSettle();
      expect(gateway.previews.last.single.planItemIds, isNull);
      expect(
        [
          for (final line in gateway.previews.last.single.lines!)
            '${line.planItemId}@${line.warehouseId}=${line.qty}',
        ],
        ['plan-b@wh-1=10'],
      );
      expect(_quantity(_rowA1), findsNothing, reason: '核对后仍只显示所选物料');
      await _tapSubmitAndConfirm(tester);
      expect(gateway.submits, hasLength(1));
      final submitted = gateway.submits.single.$1.single;
      expect(submitted.planItemIds, isNull, reason: '提交只用按行契约');
      expect(
        [
          for (final line in submitted.lines!)
            '${line.planItemId}@${line.warehouseId}=${line.qty}',
        ],
        ['plan-b@wh-1=10'],
      );
    },
  );

  testWidgets('material selection is ignored for a multi-task batch', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway, planItemIds: ['plan-b']);

    expect(
      gateway.previews.first.every((item) => item.planItemIds == null),
      isTrue,
      reason: '批量领料按任务整套，不带单任务的物料选择',
    );
    expect(_quantity(_rowA1), findsOneWidget);
    expect(_quantity(_rowB1), findsOneWidget);
  });
}
