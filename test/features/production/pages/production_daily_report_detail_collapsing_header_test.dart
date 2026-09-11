// 生产日报详情页 2026-09-11 折叠头改版回归：
// 「先滚页面收头部（提示条/表头卡/附件）、再滚明细表内部」+ 三视口叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_detail_page.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/collapsing_header_harness.dart';
import '../../../support/document_scope_capability_overrides.dart';

class _DailyReportApi extends ApiClient {
  _DailyReportApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{
    'id': 'dr-1',
    'billNo': 'RB-2026-001',
    'billDate': '2026-09-11',
    'makerName': '车间甲',
    'createdAt': '2026-09-11T08:00:00+08:00',
    'status': 0,
    'remark': '折叠头回归用日报',
    'items': <Map<String, dynamic>>[
      for (var i = 0; i < 18; i++)
        <String, dynamic>{
          'id': 'di-$i',
          'qty': i + 1,
          'weight': (i + 1) * 0.5,
          'planNo': 'PP-2026-$i',
        },
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  final api = _DailyReportApi();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        productionWriteAllDocumentScope(),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.productionDailyReportView,
          Perm.attachmentView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        businessAttachmentsProvider.overrideWith(
          (ref, owner) async => const <Attachment>[],
        ),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const ProductionDailyReportDetailPage(id: 'dr-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('生产日报详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pump(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(find.text('明细 (18)'), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(MasterDataTableView<ProductionDailyReportItem>),
    );
    expect(find.text('明细 (18)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('生产日报详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pump(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(MasterDataTableView<ProductionDailyReportItem>),
      );
    });
  }
}
