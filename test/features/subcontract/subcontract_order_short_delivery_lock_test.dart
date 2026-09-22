// ADR-098 修订「等待委外判定期间先锁住」：仓库登记发现回厂比订货少并通知委外后，
// 订货单详情要摆明「等待委外判定、本单已锁定」，改量按钮变灰但点得动并说明原因，
// 横幅上给出去判定的入口；判定完成（服务端不再返回 shortDeliveryHold）即恢复原样。
//
// 锁本身由服务端拦截（入库与改量都拦），本用例锁的是「界面必须解释清楚」这一半：
// 后端拦了而前端不解释，现场就是「点了报错、看不懂为什么」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart' as mn;

import '../../support/document_scope_capability_overrides.dart';

const _holdSummary =
    '「委外件A FG-1」回厂比订货少 8 个(订 20 个, 累计到 12 个)。'
    '仓库已登记并通知委外, 正等委外判定是分批到货继续等还是接受损耗结案; '
    '判定完成前这批货先不入库, 本单也不改量。';

Map<String, dynamic> _orderDetail({Map<String, dynamic>? hold}) => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'EO-2026-001',
  'billDate': '2026-09-22',
  'makerName': '张三',
  'createdAt': '2026-09-22T10:00:00+08:00',
  'supplierId': 'sup-1',
  'currencyId': 'cny',
  'status': 1,
  'totalLocal': 200.0,
  'canEdit': false,
  'canDelete': false,
  'canReverse': false,
  'financeApproval': {
    'caseId': 'case-1',
    'status': 'APPROVED',
    'attempt': 1,
    'version': 3,
    'allowedActions': <String>[],
  },
  'shortDeliveryHold': ?hold,
  'items': [
    {'id': 'i1', 'goodsId': 'g1', 'colorId': 'c1', 'unitId': 'u1', 'qty': 20},
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  /// null = 已判定完成（服务端不再返回锁定块）。
  Map<String, dynamic>? hold = {
    'caseId': 'case-9',
    'caseCount': 1,
    'summary': _holdSummary,
    'overdue': false,
  };
  final List<({String path, Object? body})> posts = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/subcontract/orders/order-1')) {
      return _orderDetail(hold: hold);
    }
    return <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path: path, body: body));
    return _orderDetail(hold: hold);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Api api, {
  Set<String> permissions = const {
    Perm.subcontractOrderView,
    Perm.subcontractOrderChangeQty,
    Perm.subcontractShortDeliveryDecide,
  },
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subcontractWriteAllDocumentScope(),
        currentPermissionsProvider.overrideWithValue(permissions),
        subcontractRepositoryProvider(
          SubcontractDocType.order,
        ).overrideWithValue(
          SubcontractRepository(api, SubcontractDocType.order),
        ),
        mn.masterNameServiceProvider.overrideWithValue(
          mn.MasterNameService(api),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Column(
          children: [
            AppNotificationHost(),
            Expanded(
              child: SubcontractDocDetailPage(
                docType: SubcontractDocType.order,
                id: 'order-1',
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('等待委外判定：详情页摆明已锁定并给出去判定入口', (tester) async {
    final api = _Api();
    await _pump(tester, api);

    expect(find.textContaining('等待委外判定回厂短交'), findsOneWidget);
    expect(find.textContaining('本单已锁定'), findsOneWidget);
    expect(find.textContaining('先不入库'), findsWidgets);
    expect(
      find.byKey(const Key('subcontract-order-short-delivery-judge')),
      findsOneWidget,
    );
    expect(find.text('去判定'), findsOneWidget);
  });

  testWidgets('锁定期间改量按钮变灰，点一下说明为什么，不会发出改量请求', (tester) async {
    final api = _Api();
    await _pump(tester, api);

    final button = find.byKey(const Key('subcontract-order-change-qty'));
    expect(button, findsOneWidget, reason: '按钮要留在原地变灰，不是整颗消失');

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.textContaining('等待委外判定'), findsWidgets, reason: '灰态点击必须说明原因');
    expect(
      api.posts.where((p) => p.path.contains('change-qty')),
      isEmpty,
      reason: '锁定期间不得发出改量请求',
    );
    expect(find.text('订单改量'), findsNothing, reason: '改量弹窗不该打开');
  });

  testWidgets('分批到货逾期：标题改成要重新判定', (tester) async {
    final api = _Api()
      ..hold = {
        'caseId': 'case-9',
        'caseCount': 2,
        'summary': _holdSummary,
        'overdue': true,
      };
    await _pump(tester, api);

    expect(find.textContaining('分批到货已过预计到齐日'), findsOneWidget);
    expect(find.textContaining('本单已锁定'), findsOneWidget);
  });

  testWidgets('判定完成后恢复原样：没有横幅，改量按钮可用', (tester) async {
    final api = _Api()..hold = null;
    await _pump(tester, api);

    expect(find.textContaining('等待委外判定回厂短交'), findsNothing);
    expect(
      find.byKey(const Key('subcontract-order-short-delivery-judge')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('subcontract-order-change-qty')));
    await tester.pumpAndSettle();
    expect(find.text('订单改量'), findsOneWidget, reason: '解锁后改量弹窗照常打开');
  });

  testWidgets('无判定权限只能查看，横幅照样解释锁定原因', (tester) async {
    final api = _Api();
    await _pump(
      tester,
      api,
      permissions: const {
        Perm.subcontractOrderView,
        Perm.subcontractOrderChangeQty,
      },
    );

    expect(find.textContaining('本单已锁定'), findsOneWidget);
    expect(find.text('查看短交详情'), findsOneWidget);
    expect(find.text('去判定'), findsNothing);
  });
}
