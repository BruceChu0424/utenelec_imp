// 采购订货编辑页「保存并提交财务审核」二次确认（2026-10-06，防误触）：
//  - 有提交权限时点保存先弹确认，取消则整单不落库（PUT 未发）；
//  - 确认后才保存并提交财务（POST submit-finance）；
//  - 与详情页「提交财务审核」弹窗同款文案基线。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

class _SubmitSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'u1',
      code: 'E001',
      name: '采购员',
      permissions: [Perm.purchaseOrderSubmitFinance],
    ),
  );
}

class _ConfirmApi extends ApiClient {
  _ConfirmApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
  Map<String, dynamic>? lastPutBody;
  int submitFinanceCalls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/${detail['id']}')) return detail;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('reference-methods/settlement')) {
      return const [
        {'id': 'sm-1', 'code': 'M30', 'name': '月结30天'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('submit-finance')) {
      submitFinanceCalls++;
      return detail;
    }
    return const {};
  }
}

void main() {
  testWidgets('有提交权限：保存先弹确认，取消不落库，确认才保存并提交财务', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _ConfirmApi({
      'id': 'order-1',
      'makerId': 'maker-1',
      'billNo': 'PO-2026-101-001',
      'billDate': '2026-10-06',
      'status': 0,
      'canEdit': true,
      'supplierId': 'sup-1',
      'settlementMethodId': 'sm-1',
      'currencyId': 'cny',
      'exchangeRate': 1,
      'taxRate': 0,
      'items': [
        {'id': 'pi-1', 'goodsId': 'goods-1', 'qty': 10, 'price': 3.5},
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          purchaseRepositoryProvider(
            PurchaseDocType.order,
          ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          writeAllDocumentScope(DocumentDataScope.purchase),
          sessionProvider.overrideWith(_SubmitSession.new),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/edit',
            routes: [
              GoRoute(
                path: '/edit',
                builder: (_, _) => const PurchaseOrderEditPage(id: 'order-1'),
              ),
              GoRoute(
                path: '/:rest(.*)',
                builder: (_, _) => const SizedBox.shrink(),
              ),
            ],
          ),
          builder: (context, child) => Stack(
            children: [
              Positioned.fill(child: child!),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 取消路径：弹窗出现，PUT 未发。
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(find.text('提交财务审核'), findsOneWidget);
    expect(find.text('确认提交'), findsOneWidget);
    expect(api.lastPutBody, isNull);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认提交'), findsNothing);
    expect(api.lastPutBody, isNull);
    expect(api.submitFinanceCalls, 0);

    // 确认路径：保存 + 提交财务各一次。
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    expect(api.submitFinanceCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
