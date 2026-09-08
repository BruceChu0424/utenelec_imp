// 委外订货单「批准后改量」测试（对齐采购/销售）：
//  - 财务批准（status=1 且 financeApproval 无 PENDING）+ subcontract_order:change_qty
//    权限 → 动作区出现「改量」按钮；弹窗逐行改数量，提交 POST change-qty；
//  - 在审（PENDING）或无权限 → 按钮不出现。
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

Map<String, dynamic> _approvedOrderDetail() => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'WO-2026-001',
  'billDate': '2026-09-05',
  'makerName': '张三',
  'createdAt': '2026-09-05T10:00:00+08:00',
  'supplierId': 'sup-1',
  'currencyId': 'cny',
  'status': 1,
  'totalLocal': 50.0,
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
  'items': [
    {'id': 'i1', 'goodsId': 'g1', 'colorId': 'c1', 'unitId': 'u1', 'qty': 10},
  ],
};

class _RecordingApi extends ApiClient {
  _RecordingApi()
    : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  final List<({String path, Object? body})> posts = [];
  String approvalStatus = 'APPROVED';

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/subcontract/orders/order-1')) {
      final detail = _approvedOrderDetail();
      (detail['financeApproval'] as Map<String, dynamic>)['status'] =
          approvalStatus;
      return detail;
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
    return _approvedOrderDetail();
  }
}

Future<void> _pump(
  WidgetTester tester,
  _RecordingApi api, {
  Set<String> permissions = const {
    Perm.subcontractOrderView,
    Perm.subcontractOrderChangeQty,
  },
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
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
  testWidgets('approved subcontract order can change qty', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    expect(
      find.byKey(const Key('subcontract-order-change-qty')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('subcontract-order-change-qty')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('subcontract-order-change-qty-dialog')),
      findsOneWidget,
    );
    expect(find.text('订单改量'), findsOneWidget);
    expect(find.textContaining('批准后改量立即生效'), findsOneWidget);
    expect(find.textContaining('现 10.00'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('subcontract-order-change-qty-i1')),
      '8',
    );
    await tester.tap(
      find.byKey(const Key('subcontract-order-change-qty-submit')),
    );
    await tester.pumpAndSettle();

    expect(api.posts, hasLength(1));
    expect(api.posts.single.path, '/subcontract/orders/order-1/change-qty');
    expect(api.posts.single.body, {
      'items': [
        {'orderItemId': 'i1', 'newQty': 8.0},
      ],
    });
    expect(find.textContaining('已重回财务复核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending approval hides the change-qty action', (tester) async {
    final api = _RecordingApi()..approvalStatus = 'PENDING';
    await _pump(tester, api);
    expect(find.byKey(const Key('subcontract-order-change-qty')), findsNothing);
  });

  testWidgets('without permission the action stays hidden', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api, permissions: const {Perm.subcontractOrderView});
    expect(find.byKey(const Key('subcontract-order-change-qty')), findsNothing);
  });
}
