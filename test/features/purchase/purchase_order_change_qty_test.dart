import '../../support/native_detail_reader_overrides.dart';
// 采购订货单「批准后改量」测试（对齐销售 V482）：
//  - 财务批准（status=1 且 financeApproval 无 PENDING）+ purchase_order:change_qty
//    权限 → 动作区出现「改量」按钮；弹窗逐行改数量，提交 POST change-qty；
//  - 在审（PENDING）或无权限 → 按钮不出现；
//  - 行内校验：非正数数量被拦截，不提交。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

Map<String, dynamic> _orderDetail({int status = 1}) => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'PO-2026-001',
  'billDate': '2026-09-05',
  'makerName': '采购李四',
  'createdAt': '2026-09-05T10:00:00+08:00',
  'supplierId': 'sup-1',
  'currencyId': 'cny',
  'exchangeRate': 1,
  'status': status,
  'totalLocal': 50.0,
  'canEdit': false,
  'canDelete': false,
  'canReverse': false,
  'financeApproval': {
    'caseId': 'case-1',
    'status': 'APPROVED',
    'attempt': 1,
    'version': 3,
    'allowedActions': const <String>[],
  },
  'items': [
    {'id': 'i1', 'goodsId': 'g1', 'colorId': 'c1', 'unitId': 'u1', 'qty': 10},
    {'id': 'i2', 'goodsId': 'g2', 'colorId': 'c1', 'unitId': 'u1', 'qty': 6},
  ],
};

class _RecordingApi extends ApiClient {
  _RecordingApi()
    : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  final List<({String path, Object? body})> posts = [];
  String approvalStatus = 'APPROVED';
  int orderStatus = 1;
  String? qtyExact;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/orders/order-1')) {
      final detail = _orderDetail(status: orderStatus);
      if (qtyExact != null) {
        final line =
            (detail['items'] as List<Object?>).first as Map<String, dynamic>;
        line['qtyExact'] = qtyExact;
        line['qty'] = double.parse(qtyExact!);
      }
      (detail['financeApproval'] as Map<String, dynamic>)['status'] =
          approvalStatus;
      return detail;
    }
    return <String, dynamic>{'items': <Object?>[]};
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
    return _orderDetail();
  }
}

Future<void> _pump(
  WidgetTester tester,
  _RecordingApi api, {
  bool writable = true,
  Set<String> permissions = const {
    Perm.purchaseOrderView,
    Perm.purchaseOrderChangeQty,
  },
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        if (writable)
          writeAllDocumentScope(DocumentDataScope.purchase)
        else
          documentScopeCapabilityProvider(
            DocumentDataScope.purchase,
          ).overrideWith(
            (ref) async => const DocumentScopeCapability(
              scope: 'purchase',
              writeAll: false,
              writableOwnerIds: {},
            ),
          ),
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(
          PurchaseDocType.order,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Column(
          children: [
            AppNotificationHost(),
            Expanded(
              child: PurchaseDocDetailPage(
                docType: PurchaseDocType.order,
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
  testWidgets(
    'submitted purchase order changes quantity while the original finance review remains pending',
    (tester) async {
      final api = _RecordingApi()
        ..approvalStatus = 'PENDING'
        ..orderStatus = 0;
      await _pump(tester, api);
      await tester.tap(find.byKey(const Key('purchase-order-change-qty')));
      await tester.pumpAndSettle();
      expect(find.textContaining('继续等待财务审核'), findsOneWidget);
      expect(find.textContaining('批准后改量立即生效'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('purchase-order-change-qty-i1')),
        '8.1256',
      );
      await tester.tap(
        find.byKey(const Key('purchase-order-change-qty-submit')),
      );
      await tester.pumpAndSettle();
      expect(api.posts.single.path, '/purchase/orders/order-1/change-qty');
      expect(api.posts.single.body, {
        'items': [
          {'orderItemId': 'i1', 'newQty': '8.1256'},
        ],
      });
      expect(find.textContaining('待财务审核内容已更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unsubmitted draft has no controlled pending-quantity action',
    (tester) async {
      final api = _RecordingApi()
        ..approvalStatus = 'REJECTED'
        ..orderStatus = 0;
      await _pump(tester, api);
      expect(find.byKey(const Key('purchase-order-change-qty')), findsNothing);
      expect(api.posts, isEmpty);
    },
  );

  for (final confirm in [false, true]) {
    testWidgets(
      'change-qty ${confirm ? 'confirmation' : 'cancel'} retains input controllers until the dialog exits',
      (tester) async {
        final api = _RecordingApi();
        await _pump(tester, api);
        await tester.tap(find.byKey(const Key('purchase-order-change-qty')));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('purchase-order-change-qty-i1'));
        final controller = tester.widget<TextField>(field).controller!;
        await tester.enterText(field, '12.5');
        await tester.tap(
          confirm
              ? find.byKey(const Key('purchase-order-change-qty-submit'))
              : find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('取消'),
                ),
        );
        await tester.pump();
        void listener() {}
        expect(
          () => controller.addListener(listener),
          returnsNormally,
          reason: 'the closing overlay still owns the TextField',
        );
        controller.text = '999';
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(() => controller.addListener(listener), throwsFlutterError);
        if (confirm) {
          expect(
            api.posts.single.body,
            {
              'items': [
                {'orderItemId': 'i1', 'newQty': '12.5'},
              ],
            },
            reason: 'the confirmed quantity is frozen before reverse animation',
          );
        } else {
          expect(api.posts, isEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final status in ['APPROVED', 'REJECTED']) {
    testWidgets(
      'read-only owner has no quantity correction action for $status',
      (tester) async {
        final api = _RecordingApi()..approvalStatus = status;
        await _pump(tester, api, writable: false);
        expect(
          find.byKey(const Key('purchase-order-change-qty')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('document-scope-write-notice-readonly')),
          findsOneWidget,
        );
        expect(api.posts, isEmpty);
      },
    );
  }
  testWidgets(
    'opening and confirming without edits preserves all four decimal places',
    (tester) async {
      final api = _RecordingApi()..qtyExact = '10.1256';
      await _pump(tester, api);
      await tester.tap(find.byKey(const Key('purchase-order-change-qty')));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.byKey(const Key('purchase-order-change-qty-i1')),
      );
      expect(input.controller!.text, '10.1256');
      await tester.tap(
        find.byKey(const Key('purchase-order-change-qty-submit')),
      );
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('approved order with permission can change qty', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    expect(find.byKey(const Key('purchase-order-change-qty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('purchase-order-change-qty')));
    await tester.pumpAndSettle();

    // 弹窗：红色警示 + 逐行 旧数量 + 输入框。
    expect(
      find.byKey(const Key('purchase-order-change-qty-dialog')),
      findsOneWidget,
    );
    expect(find.text('订单改量'), findsOneWidget);
    expect(find.textContaining('批准后改量立即生效'), findsOneWidget);
    expect(find.textContaining('现 10'), findsOneWidget);
    expect(find.textContaining('现 6'), findsOneWidget);
    expect(
      find.byKey(const Key('purchase-order-change-qty-i1')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('purchase-order-change-qty-i1')),
      '12.5',
    );
    await tester.tap(find.byKey(const Key('purchase-order-change-qty-submit')));
    await tester.pumpAndSettle();

    expect(api.posts, hasLength(1));
    expect(api.posts.single.path, '/purchase/orders/order-1/change-qty');
    expect(api.posts.single.body, {
      'items': [
        {'orderItemId': 'i1', 'newQty': '12.5'},
      ],
    });
    // 成功后提示已重回财务复核并刷新详情。
    expect(find.textContaining('已重回财务复核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid qty is blocked before submit', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    await tester.tap(find.byKey(const Key('purchase-order-change-qty')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('purchase-order-change-qty-i1')),
      '0',
    );
    await tester.tap(find.byKey(const Key('purchase-order-change-qty-submit')));
    await tester.pumpAndSettle();

    expect(api.posts, isEmpty);
    expect(find.textContaining('必须大于 0'), findsOneWidget);
  });

  testWidgets('pending approval hides the change-qty action', (tester) async {
    final api = _RecordingApi()..approvalStatus = 'PENDING';
    await _pump(tester, api);
    expect(find.byKey(const Key('purchase-order-change-qty')), findsNothing);
  });

  testWidgets('without permission the action stays hidden', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api, permissions: const {Perm.purchaseOrderView});
    expect(find.byKey(const Key('purchase-order-change-qty')), findsNothing);
  });
}
