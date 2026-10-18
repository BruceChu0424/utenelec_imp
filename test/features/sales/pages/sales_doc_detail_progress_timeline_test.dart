import '../../../support/native_detail_reader_overrides.dart';
// 销售订货单详情页履约进度折叠卡（2026-10-18 订单进度详情整页并入本页）：
// 时间线放明细表上方、默认折叠只露「最新」状态胶囊，尾部动作即原右下
// 「进度追踪」按钮的替代口径——「展开查看全部进度」/「收起」；草稿单不渲染。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _TimelineApi extends ApiClient {
  _TimelineApi(this.status) : super(Dio());

  final int status;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/order-1') {
      return <String, dynamic>{
        'id': 'order-1',
        'billNo': 'SO-1',
        'billDate': '2026-09-09',
        'makerName': '李销售',
        'status': status,
        'writable': true,
        'financeConfirmed': false,
        'financeRejected': false,
        'stopped': false,
        'closed': false,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'line-1', 'qty': 10, 'price': 10},
        ],
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('progress-timeline')) {
      // 服务端口径：未开始的 PENDING 整块置顶，已发生事件按时间倒序、下单垫底。
      return const <Map<String, dynamic>>[
        {
          'seq': 70,
          'code': 'PRODUCTION_PROGRESS',
          'title': '生产开工',
          'state': 'PENDING',
          'detail': '已产 0 / 订货 10',
        },
        {
          'seq': 3,
          'code': 'FINANCE_CONFIRMED',
          'title': '财务审核通过',
          'state': 'DONE',
          'occurredAt': '2026-09-10T02:30:00Z',
        },
        {
          'seq': 1,
          'code': 'ORDER_CREATED',
          'title': '销售下单',
          'state': 'DONE',
          'occurredAt': '2026-09-09T02:00:00Z',
        },
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}

Future<void> _pump(WidgetTester tester, {required int status}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _TimelineApi(status);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.salesOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        home: SalesDocDetailPage(
          docType: SalesDocType.order,
          id: 'order-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('已审订单：表格上方默认折叠，点「展开查看全部进度」见完整时间线', (tester) async {
    await _pump(tester, status: 1);

    // 右下「进度追踪」按钮已退役，进度就在本页。
    expect(find.text('进度追踪'), findsNothing);

    // 折叠卡在明细表上方，默认只露标题 + 最新状态胶囊。
    expect(find.text('履约进度'), findsOneWidget);
    expect(find.textContaining('最新：财务审核通过'), findsOneWidget);
    expect(find.text('展开查看全部进度'), findsOneWidget);
    // AnimatedCrossFade 折叠子树仍在树中但被裁剪，不可点。
    expect(find.text('销售下单').hitTestable(), findsNothing);
    final timelineTop = tester.getTopLeft(find.text('履约进度')).dy;
    final tableTop = tester.getTopLeft(
      find.byType(MasterDataTableView<SalesDocItem>),
    ).dy;
    expect(timelineTop, lessThan(tableTop), reason: '履约进度必须在明细表上方');

    // 展开动作换成「收起」，完整时间线可见（置顶 PENDING 在最新节点之上）。
    await tester.tap(find.text('展开查看全部进度'));
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('展开查看全部进度'), findsNothing);
    expect(find.text('销售下单').hitTestable(), findsOneWidget);
    expect(find.text('生产开工').hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('生产开工')).dy,
      lessThan(tester.getTopLeft(find.text('销售下单')).dy),
      reason: '未开始阶段整块置顶、下单垫底（服务端口径）',
    );

    // 再点「收起」回到折叠态。
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('展开查看全部进度'), findsOneWidget);
    expect(find.text('销售下单').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('草稿订单没有履约链可看，不渲染进度折叠卡', (tester) async {
    await _pump(tester, status: 0);
    expect(find.text('履约进度'), findsNothing);
    expect(find.text('展开查看全部进度'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
