// 编辑既有销售订货单保存后的落点与返回（2026-09-25 修复）：
//  - 从详情编辑后保存 pop 回宿主，避免叠一层新详情；
//  - 从草稿列表直接编辑后保存进入本单详情，显示后续审核入口；
//  - 详情页点一次左上角返回即回列表页（此前要先经过保存前的旧详情快照）；
//  - 保存的写操作让宿主详情「返回即刷新」(ADR-108) 重取新数据。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

import '../../../helpers/finance_claim_fixture.dart';

const _detail = {
  'id': 'order-1',
  'status': 0,
  'writable': true,
  'clientId': 'client-1',
  'sellerId': 'seller-1',
  'currencyId': 'cny',
  'settlementMethodId': 'settlement-net30',
  'deliverDate': '2026-09-30',
  'shipmentPolicy': 'ALLOW_PARTIAL',
  'items': [
    {
      'id': 'order-item-1',
      'goodsId': 'goods-1',
      'unitId': 'unit-box',
      'unitRate': 1,
      'qty': 10,
      'price': 10,
      'discount': 0.8,
    },
  ],
};

void main() {
  testWidgets('编辑保存 pop 回宿主详情；返回一次回列表；宿主重取新数据', (tester) async {
    final (:router, :api) = await _pumpFlow(tester);

    // 列表 → 详情 V1（GET #1）。
    await tester.tap(find.text('打开订货单'));
    await tester.pumpAndSettle();
    expect(api.detailGets, 1);

    // 详情 → 编辑（GET #2 供编辑页回填）。
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(api.detailGets, 2);

    // 保存 → pop 回宿主详情（不再叠一层新详情）。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(api.puts, 1);
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/sales/orders/order-1',
    );

    // 保存的写操作让宿主详情「返回即刷新」重取（GET #3）。
    expect(api.detailGets, greaterThanOrEqualTo(3));

    // 详情左上角返回一次即回列表（此前会先落在保存前的旧详情快照上）。
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/list',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('草稿列表直接编辑保存后进入详情审核页；一次返回原草稿列表', (tester) async {
    final (:router, :api) = await _pumpFlow(tester, fromDraftList: true);

    // 与订货进度「草稿」行相同：直接 push 编辑页，栈下没有详情页。
    await tester.tap(find.text('编辑草稿'));
    await tester.pumpAndSettle();
    expect(api.detailGets, 1);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(api.puts, 1);
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/sales/orders/order-1',
      reason: '保存后应进入本单详情继续审核，不能因列表在栈下就退回列表',
    );
    expect(find.byType(SalesDocDetailPage), findsOneWidget);
    expect(find.text('审核'), findsOneWidget);
    expect(api.detailGets, greaterThanOrEqualTo(2));

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/drafts',
    );
    expect(find.text('草稿列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<({GoRouter router, _PopApi api})> _pumpFlow(
  WidgetTester tester, {
  bool fromDraftList = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  // fake PUT 推进真实的写修订号，详情返回后的刷新沿用生产接线。
  late final _PopApi api;
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWith((ref) => api),
      salesMasterNameServiceProvider.overrideWith(
        (ref) => SalesMasterNameService(api),
      ),
      taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
      sessionProvider.overrideWith(_TestSessionNotifier.new),
      currentPermissionsProvider.overrideWithValue(const {
        Perm.salesOrderView,
        Perm.salesOrderEdit,
        Perm.salesOrderApprove,
      }),
    ],
  );
  addTearDown(container.dispose);
  api = _PopApi(container);

  final listPath = fromDraftList ? '/drafts' : '/list';
  final router = GoRouter(
    initialLocation: listPath,
    routes: [
      GoRoute(
        path: listPath,
        builder: (context, _) => Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fromDraftList ? '草稿列表' : '订货列表'),
                FilledButton(
                  onPressed: () => context.push(
                    fromDraftList
                        ? '/sales/orders/order-1/edit'
                        : '/sales/orders/order-1',
                  ),
                  child: Text(fromDraftList ? '编辑草稿' : '打开订货单'),
                ),
              ],
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, state) => SalesDocDetailPage(
          docType: SalesDocType.order,
          id: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/sales/orders/:id/edit',
        builder: (_, state) => SalesDocEditPage(
          docType: SalesDocType.order,
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  final detach = attachPageResume(
    router,
    container.read(pageResumeProvider.notifier),
  );
  addTearDown(detach);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
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
  return (router: router, api: api);
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

/// PUT 成功时推进本端写修订号——线上由 Dio 拦截器做，测试 fake 绕过了网络层。
class _PopApi extends ApiClient {
  _PopApi(this._container) : super(Dio());

  final ProviderContainer _container;
  int detailGets = 0;
  int puts = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/order-1')) {
      detailGets++;
      return _detail;
    }
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
  }) async => const [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    puts++;
    _container.read(dataWriteRevisionProvider.notifier).state++;
    return _detail;
  }
}
