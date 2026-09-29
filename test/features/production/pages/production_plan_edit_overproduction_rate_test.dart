// ADR-129 §2.10：计划编辑页的允许超产比例只记人确认过的值。
//
// 读回的行随行带 sourceItemId(原计划明细 id)，服务端据此认出「同一行」；来源是
// 人定的(EXPLICIT)比例照原值回传，来源是系统默认(DEFAULT)且没人改过的送空值——
// 删行、插行让它换了位置也一样；人改过的按所填值明确提交。
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_goods_identity_cell.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_plan_edit_page.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_field.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _rateFields = find.descendant(
  of: find.byType(ProductionOverproductionRateField),
  matching: find.byType(TextField),
);

Future<_PlanApi> _open(
  WidgetTester tester, {
  required double secondRate,
}) async {
  final api = _PlanApi(secondRate: secondRate);
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        documentScopeCapabilityProvider.overrideWith(
          (ref, scope) async => DocumentScopeCapability(
            scope: scope.apiValue,
            writeAll: true,
            writableOwnerIds: const {},
          ),
        ),
      ],
      child: const MaterialApp(home: ProductionPlanEditPage(id: 'plan-1')),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<List<Map<String, dynamic>>> _save(
  WidgetTester tester,
  _PlanApi api,
) async {
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  return (api.saved!['items'] as List).cast<Map<String, dynamic>>();
}

void main() {
  testWidgets('编辑草稿：人定的比例照原值回传，默认比例改过按所填值提交', (tester) async {
    final api = await _open(tester, secondRate: 0);
    expect(_rateFields, findsNWidgets(2));
    expect(tester.widget<TextField>(_rateFields.at(0)).controller!.text, '25');
    expect(tester.widget<TextField>(_rateFields.at(1)).controller!.text, '0');
    await tester.enterText(_rateFields.at(1), '7.5');
    await tester.pump();

    final items = await _save(tester, api);
    expect(items.map((item) => item['allowedOverproductionRate']), [
      0.25,
      0.075,
    ]);
    expect(items.map((item) => item['sourceItemId']), ['item-1', 'item-2']);
  });

  testWidgets('删掉前一行后，没人改过的默认比例仍送空值，不被当成人定的比例', (tester) async {
    final api = await _open(tester, secondRate: 0.1);
    expect(tester.widget<TextField>(_rateFields.at(1)).controller!.text, '10');

    // 右击第一行弹行菜单，删除这一行(确认后才删)。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(UtenGoodsIdentityCell).first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除选中 (1)').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(_rateFields, findsOneWidget);
    expect(tester.widget<TextField>(_rateFields).controller!.text, '10');

    final item = (await _save(tester, api)).single;
    expect(item['goodsId'], 'goods-2');
    expect(item['sourceItemId'], 'item-2');
    expect(item.containsKey('allowedOverproductionRate'), isFalse);
  });
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _PlanApi extends ApiClient {
  _PlanApi({required double secondRate})
    : _detail = {
        'id': 'plan-1',
        'billNo': 'SJ-1',
        'billDate': '2026-09-27',
        'makerId': 'maker-1',
        'status': 0,
        'allowedActions': ['EDIT'],
        'items': [
          {
            'id': 'item-1',
            'goodsId': 'goods-1',
            'qty': 10,
            'allowedOverproductionRate': 0.25,
            'allowedOverproductionRateSource': 'EXPLICIT',
          },
          {
            'id': 'item-2',
            'goodsId': 'goods-2',
            'qty': 5,
            'allowedOverproductionRate': secondRate,
            'allowedOverproductionRateSource': 'DEFAULT',
          },
        ],
      },
      super(Dio());

  Map<String, dynamic>? saved;

  final Map<String, dynamic> _detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/plan-1') return _detail;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    saved = (body! as Map).cast<String, dynamic>();
    return _detail;
  }
}
