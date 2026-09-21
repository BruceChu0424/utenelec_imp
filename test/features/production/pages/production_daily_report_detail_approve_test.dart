// 生产日报详情页「审核」回归(2026-09-21 事故)。
//
// 事故复盘：服务端 15.094 秒返回 200 并已提交，浏览器 15 秒就掐了连接，页面因此停在草稿，
// 「审核」按钮还在，用户 45 秒后又点了一次，服务端回「仅草稿单据可审核」400。
// 这里钉住三件事：
//   1) 拿到 200 就必须翻成已审核，且不再多发一次详情请求；
//   2) 写请求失败(结果未知)时必须重读服务端权威状态——真成了就据实告诉用户，按钮跟着换掉；
//   3) 服务端明确拒绝且状态确实没变时，仍旧报错、不乱改页面。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_detail_page.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/document_scope_capability_overrides.dart';

/// 服务端替身：状态是它自己的事实，post 只决定「客户端这次拿不拿得到结果」。
class _DailyReportApi extends ApiClient {
  _DailyReportApi({required this.onApprove}) : super(Dio());

  /// 返回 null 表示这次审核正常拿到响应；返回异常表示响应丢了(超时/断连)或被拒。
  final Object? Function(_DailyReportApi server) onApprove;

  int serverStatus = 0;
  int detailReads = 0;

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': 'dr-1',
    'billNo': 'SR20260922000005',
    'billDate': '2026-09-22',
    'makerName': '朱振炜',
    'createdAt': '2026-09-22T05:49:19+08:00',
    'status': serverStatus,
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'di-1',
        'qty': 1000,
        'planNo': 'SJ20260922000016',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    detailReads++;
    return _detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final failure = onApprove(this);
    if (failure != null) throw failure;
    return _detail;
  }
}

Future<(_DailyReportApi, List<String>)> _pump(
  WidgetTester tester, {
  required Object? Function(_DailyReportApi server) onApprove,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final api = _DailyReportApi(onApprove: onApprove);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      apiClientProvider.overrideWithValue(api),
      // 本地服务可达性探针带 60 秒周期 Timer，测试收尾会判「Timer 未清」。
      // 按 Web 形态构造就整体不起探针(它在 Web 上本来也不跑)。
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(preferences, web: true),
      ),
      productionWriteAllDocumentScope(),
      masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      currentPermissionsProvider.overrideWithValue(const <String>{
        Perm.productionDailyReportView,
        Perm.productionDailyReportApprove,
        Perm.productionDailyReportReverse,
        Perm.attachmentView,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      businessAttachmentsProvider.overrideWith(
        (ref, owner) async => const <Attachment>[],
      ),
    ],
  );
  addTearDown(container.dispose);

  // 通知条自带停留计时，pumpAndSettle 会把它推过期；边产生边记，断言才稳。
  final notices = <String>[];
  container.listen<List<AppNotification>>(
    appNotificationProvider,
    (previous, next) => notices.addAll(next.map((item) => item.message)),
    fireImmediately: true,
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: ProductionDailyReportDetailPage(id: 'dr-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api, notices);
}

Future<void> _tapApprove(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(UtenButton, '审核'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('审核拿到 200：按钮换成红冲，且不再多发一次详情请求', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) {
        server.serverStatus = 1;
        return null;
      },
    );
    final readsAfterLoad = api.detailReads;
    expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);

    await _tapApprove(tester);

    expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
    expect(find.widgetWithText(UtenButton, '红冲'), findsOneWidget);
    expect(api.detailReads, readsAfterLoad, reason: '成功路径不该再回读详情');
    expect(notices, contains('已审核'));
  });

  testWidgets('审核超时但服务端其实已提交：页面自动重读并告诉用户成功', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) {
        // 事故原样：事务提交了，响应被客户端的建连计时器掐掉。
        server.serverStatus = 1;
        return NetworkTimeoutException();
      },
    );
    final readsAfterLoad = api.detailReads;

    await _tapApprove(tester);

    expect(
      find.widgetWithText(UtenButton, '审核'),
      findsNothing,
      reason: '状态已是已审核，再画审核按钮就是在邀请用户重复提交',
    );
    expect(find.widgetWithText(UtenButton, '红冲'), findsOneWidget);
    expect(api.detailReads, readsAfterLoad + 1, reason: '失败路径必须重读一次');
    expect(
      notices.any((message) => message.contains('本次提交服务端已完成')),
      isTrue,
      reason: '不能把一次已经成功的审核报成失败',
    );
  });

  testWidgets('服务端明确拒绝且状态没变：照常报错，页面不乱改', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) =>
          ApiException('BUSINESS', '明细为空，不可审核', httpStatus: 400),
    );
    final readsAfterLoad = api.detailReads;

    await _tapApprove(tester);

    expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
    expect(find.widgetWithText(UtenButton, '红冲'), findsNothing);
    expect(api.detailReads, readsAfterLoad + 1);
    expect(notices, contains('明细为空，不可审核'));
  });
}
