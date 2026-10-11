// ADR-143 §4.2 委外领料页(2026-10-10 口径：只显示「本次出仓物料」表，数量按服务端
// 默认全量提交，不再逐任务编辑)：默认联合分配、幂等提交、409 回填、结果未确认时
// 同键重试；有了确定结果 / 重新进页换新键(撤回后再领同样数量不算重放)；
// 预览整批 409 只给「返回委外任务中心」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
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

/// 仓库里物料A 的实时库存(kg)，409 场景用来模拟别人先领走一部分。
class _Stock {
  _Stock(this.kg);
  int kg;
}

/// 两个任务共用物料A(仓库共 [capacity] kg，每个委外件 2 kg)：按顺序联合分配，
/// item-1 自身最多可领 40，item-2 自身最多可领 80。item-1 另需物料B(每件 1 个)。
(FakeSubcontractDrawGateway, _Stock) _gateway({int capacity = 200}) {
  final gateway = FakeSubcontractDrawGateway();
  final stock = _Stock(capacity);
  gateway.onPreview = (items) async {
    var left = stock.kg / 2;
    final tasks = <Map<String, dynamic>>[];
    final lines = <Map<String, dynamic>>[];
    for (final item in items) {
      final own = item.orderItemId == 'item-1' ? 40 : 80;
      final batch = own < left ? own : left;
      final qty = item.qty ?? batch;
      if (qty > batch + 0.0001) {
        throw ApiException(
          'CONFLICT',
          '${item.orderItemId} 本批最多可领 $batch',
          httpStatus: 409,
        );
      }
      left -= qty;
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
      if (qty > 0) {
        lines.add(previewLineJson(item.orderItemId, 'plan-a', qty: qty * 2));
        if (item.orderItemId == 'item-1') {
          lines.add(
            previewLineJson(
              item.orderItemId,
              'plan-b',
              goodsId: 'material-b',
              goodsName: '物料B',
              qty: qty,
            ),
          );
        }
      }
    }
    return SubcontractDrawPreview.fromJson(<String, dynamic>{
      'tasks': tasks,
      'lines': lines,
      'documentCount': tasks.where((task) => (task['qty'] as num) > 0).length,
    });
  };
  return (gateway, stock);
}

Future<List<Object?>> _pump(
  WidgetTester tester,
  FakeSubcontractDrawGateway gateway, {
  List<String> ids = const ['item-1', 'item-2'],
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
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
                  RouteName.operationsSubcontractDrawRequestFor(ids),
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
  testWidgets(
    'first preview allocates shared material and defaults to batch drawable',
    (tester) async {
      final (gateway, _) = _gateway();
      await _pump(tester, gateway);
      expect(gateway.previews, hasLength(1));
      expect(
        gateway.previews.single.map((item) => (item.orderItemId, item.qty)),
        [('item-1', null), ('item-2', null)],
      );
      // 共 100 套物料A：item-1 先占 40，item-2 只剩 60。
      // 2026-10-10 口径：页面只有「本次出仓物料」表，数量按默认全量提交、
      // 单位内联在数量后(无任务表、无独立单位列)。
      expect(find.byKey(const Key('subcontract-draw-request-tasks')), findsNothing);
      expect(find.text('2 个委外任务 · 2 种物料 · 预计 2 张出仓单'), findsOneWidget);
      expect(find.text('领料仓库'), findsOneWidget);
      expect(find.text('本次领料数量'), findsOneWidget);
      expect(find.text('80 kg'), findsOneWidget, reason: 'item-1 的物料A按数量+单位内联');
      expect(find.text('单位'), findsNothing);
      expect(find.text('本次出仓物料'), findsNothing);
      expect(_submit(tester).onPressed, isNotNull);
      expect(find.text('提交领料(2)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submit sends quantities with an idempotency key and returns to the task center',
    (tester) async {
      final (gateway, _) = _gateway();
      final results = await _pump(tester, gateway);
      await _tapSubmitAndConfirm(tester);
      final (items, key) = gateway.submits.single;
      expect(items.map((item) => (item.orderItemId, item.qty)), [
        ('item-1', 40),
        ('item-2', 60),
      ]);
      expect(key, startsWith('subcontract-draw-'));
      expect(results, [true]);
      expect(find.text('打开领料页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('409 re-previews and refills with the live batch drawable', (
    tester,
  ) async {
    final (gateway, stock) = _gateway();
    gateway.onSubmit = (items, key) async {
      // 别人先领走了一部分物料A：实时只剩 180 kg。
      stock.kg = 180;
      throw ApiException('CONFLICT', '委外件B 实时本批可领 50', httpStatus: 409);
    };
    final results = await _pump(tester, gateway);
    await _tapSubmitAndConfirm(tester);
    expect(gateway.submits, hasLength(1));
    expect(gateway.previews, hasLength(2));
    expect(gateway.previews.last.map((item) => item.qty), everyElement(isNull));
    expect(
      find.byKey(const Key('subcontract-draw-request-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('已按实时本批可领重新填写'), findsOneWidget);
    expect(results, isEmpty);
    expect(_submit(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reopening the page with the same quantities submits with a new key',
    (tester) async {
      // 撤回 / 退料后已领、可领回到原值：同样的数量再领也是一次新的领料。
      final (gateway, _) = _gateway();
      final results = await _pump(tester, gateway);
      await _tapSubmitAndConfirm(tester);
      expect(results, [true]);
      await tester.tap(find.text('打开领料页'));
      await tester.pumpAndSettle();
      await _tapSubmitAndConfirm(tester);
      expect(gateway.submits, hasLength(2));
      expect(
        gateway.submits.first.$1.map((item) => (item.orderItemId, item.qty)),
        gateway.submits.last.$1.map((item) => (item.orderItemId, item.qty)),
      );
      expect(gateway.submits.first.$2, isNot(gateway.submits.last.$2));
      expect(gateway.submits.last.$2, startsWith('subcontract-draw-'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a definitive rejection rotates the key for the next attempt', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    var attempts = 0;
    gateway.onSubmit = (items, key) async {
      attempts++;
      if (attempts == 1) {
        throw ApiException('VALIDATION', '委外商已停用', httpStatus: 400);
      }
      return const SubcontractDrawSubmitResult(
        issueIds: ['issue-1'],
        issueBillNos: ['WF-1'],
        documentCount: 2,
        replayed: false,
      );
    };
    final results = await _pump(tester, gateway);
    await _tapSubmitAndConfirm(tester);
    expect(find.text('委外商已停用'), findsOneWidget);
    expect(results, isEmpty);
    await _tapSubmitAndConfirm(tester);
    expect(gateway.submits, hasLength(2));
    expect(gateway.submits.first.$2, isNot(gateway.submits.last.$2));
    expect(results, [true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a 409 preview offers only the way back to the task center and refreshes it',
    (tester) async {
      final gateway = FakeSubcontractDrawGateway();
      gateway.onPreview = (items) async => throw ApiException(
        'CONFLICT',
        '所选委外任务已领满、已结束领料或已不在您的可见范围内，请刷新后重新选择',
        httpStatus: 409,
      );
      final results = await _pump(tester, gateway);
      expect(
        find.byKey(const Key('subcontract-draw-request-load-error')),
        findsOneWidget,
      );
      expect(find.text('重新加载'), findsNothing);
      expect(gateway.previews, hasLength(1));
      await tester.tap(find.text('返回委外任务中心'));
      await tester.pumpAndSettle();
      expect(gateway.previews, hasLength(1), reason: '不再重试同一批');
      expect(results, [true]);
      expect(find.text('打开领料页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a non-conflict preview failure still offers reload', (
    tester,
  ) async {
    final gateway = FakeSubcontractDrawGateway();
    var calls = 0;
    gateway.onPreview = (items) async {
      calls++;
      throw ApiException('INTERNAL', '服务暂时不可用', httpStatus: 500);
    };
    await _pump(tester, gateway);
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('返回委外任务中心'), findsNothing);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unconfirmed result keeps the batch and retries with the same key',
    (tester) async {
      final (gateway, _) = _gateway();
      var attempts = 0;
      gateway.onSubmit = (items, key) async {
        attempts++;
        if (attempts == 1) throw NetworkException();
        return const SubcontractDrawSubmitResult(
          issueIds: ['issue-1'],
          issueBillNos: ['WF-1'],
          documentCount: 2,
          replayed: true,
        );
      };
      final results = await _pump(tester, gateway);
      await _tapSubmitAndConfirm(tester);
      expect(find.text('重试领料'), findsOneWidget);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(gateway.submits, hasLength(2));
      expect(gateway.submits.first.$2, gateway.submits.last.$2);
      expect(results, [true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('submit asks for confirmation first; cancel keeps the batch', (
    tester,
  ) async {
    final (gateway, _) = _gateway();
    await _pump(tester, gateway);
    await tester.tap(find.byKey(_submitKey));
    await tester.pumpAndSettle();
    expect(find.text('提交领料'), findsOneWidget);
    expect(find.textContaining('将提交 2 个委外任务的领料'), findsOneWidget);
    expect(find.textContaining('预计生成 2 张出仓单'), findsOneWidget);
    expect(gateway.submits, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.submits, isEmpty);
    expect(find.text('提交领料(2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
