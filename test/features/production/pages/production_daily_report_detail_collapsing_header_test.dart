// 生产日报详情页 2026-09-11 折叠头改版回归：
// 「先滚页面收头部（提示条/表头卡/附件）、再滚明细表内部」+ 三视口叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_detail_page.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/collapsing_header_harness.dart';
import '../../../support/document_scope_capability_overrides.dart';
import '../../../support/memory_cas_storage.dart';

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
          if (i != 2) 'weight': (i + 1) * 0.5,
          if (i == 0) 'weightExact': '0.500000000000000001',
          if (i == 0 || i == 2) 'unitWeightKgExact': '0.00123456789',
          'planNo': 'PP-2026-$i',
        },
    ],
    // 服务端一定随详情给 outputBatches；未拆分行自成一批一组（合并行数据源）。
    'outputBatches': <Map<String, dynamic>>[
      for (var i = 0; i < 18; i++)
        <String, dynamic>{
          'batchKey': 'di-$i',
          'itemIds': <String>['di-$i'],
          'qty': i + 1,
          'summary': '服务端摘要 di-$i',
          'groups': <Map<String, dynamic>>[
            <String, dynamic>{
              'itemIds': <String>['di-$i'],
              'destination': 'WAREHOUSE',
              'qty': i + 1,
              'summary': '送入仓库 ${i + 1}',
            },
          ],
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
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'daily-report-tester'),
        ),
        apiBaseUrlProvider.overrideWithValue(
          'https://daily-report.example/api',
        ),
        formDraftStorageProvider.overrideWithValue(MemoryCasStorage()),
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: utenTextScaleBuilder(textScale),
        home: const ProductionDailyReportDetailPage(id: 'dr-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('日报详情并列显示保存的实称总重量与单重，旧单仍可查看', (tester) async {
    await _pump(tester, size: const Size(1280, 900));
    final table = tester
        .widget<MasterDataTableView<ProductionDailyReportDetailGroupRow>>(
          find.byType(MasterDataTableView<ProductionDailyReportDetailGroupRow>),
        );
    final weightIndex = table.columns.indexWhere(
      (column) => column.key == 'weight',
    );
    final weight = table.columns[weightIndex];
    final unitWeight = table.columns[weightIndex + 1];
    expect(weight.label, '实称总重量');
    expect(unitWeight.key, 'unitWeight');
    expect(unitWeight.label, '单重');
    expect(weight.value(table.items[0]), '0.500000000000000001 kg');
    expect(unitWeight.value(table.items[0]), '1.23456789 g');
    expect(weight.value(table.items[1]), '1 kg');
    expect(unitWeight.value(table.items[1]), '未知');
    expect(weight.value(table.items[2]), '未称');
    expect(unitWeight.value(table.items[2]), '1.23456789 g');
  });

  testWidgets('生产日报详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pump(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    // 2026-09-25 起纯计数「明细 (N)」标题退役，明细表本体即 body 锚点。
    expect(
      find.byType(MasterDataTableView<ProductionDailyReportDetailGroupRow>),
      findsOneWidget,
    );
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(
        MasterDataTableView<ProductionDailyReportDetailGroupRow>,
      ),
    );
    expect(
      find.byType(MasterDataTableView<ProductionDailyReportDetailGroupRow>),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('生产日报详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pump(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(
          MasterDataTableView<ProductionDailyReportDetailGroupRow>,
        ),
      );
    });
  }
}
