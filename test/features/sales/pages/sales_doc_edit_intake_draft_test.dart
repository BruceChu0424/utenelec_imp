// 新建报价「识别客户文件」后的本机草稿往返(ADR-121 + ADR-134): 草稿里有 aiIntake 与
// 行上的文件字段/学习标记/黄标, 硬关闭后恢复不重新识别, 保存仍提交 aiIntake;
// 以及订货单「改为新建报价单」带来的 aiJobId: 报价新建页打开即恢复同一次识别。
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/user.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';
import '../intake/sales_intake_fixture.dart';
import '../intake/sales_intake_test_support.dart';

typedef _Env = ({
  ProviderContainer container,
  GoRouter router,
  _Api api,
  FakeAiJobRunner runner,
});

Future<_Env> _pump(
  WidgetTester tester,
  MemoryFormDraftStorage storage, {
  String location = '/sales/quotes/new',
  bool impersonating = false,
  Object? extra,
  Set<String>? permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api();
  final runner = FakeAiJobRunner(result: intakeResultJson());
  final presenter = FakeProgressPresenter();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'sales-person'),
      ),
      formDraftStorageProvider.overrideWithValue(storage),
      currentPermissionsProvider.overrideWithValue(
        permissions ??
            const {
              Perm.salesQuoteView,
              Perm.salesQuoteCreate,
              Perm.salesQuoteEdit,
              Perm.salesOrderPriceView,
            },
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      salesMasterNameServiceProvider.overrideWithValue(
        SalesMasterNameService(api),
      ),
      sessionProvider.overrideWith(
        impersonating ? _ImpersonatingSession.new : _Session.new,
      ),
      aiJobRunnerProvider.overrideWithValue(runner),
      salesIntakeProgressPresenterProvider.overrideWithValue(
        presenterOf(presenter),
      ),
      aiStatusProvider.overrideWith((ref) async => AiStatus.unavailable),
      salesIntakeRepositoryProvider.overrideWithValue(
        FakeSalesIntakeRepository(),
      ),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    initialExtra: extra,
    routes: [
      DraftAwareGoRoute(
        path: '/sales/quotes/new',
        builder: (_, state) => SalesDocEditPage(
          key: state.pageKey,
          docType: SalesDocType.quote,
          initialAiJobId: state.uri.queryParameters['aiJobId'],
          initialAiFile: state.extra is PlatformFile
              ? state.extra as PlatformFile
              : null,
        ),
      ),
      GoRoute(
        path: '/:rest(.*)',
        builder: (_, _) => const Scaffold(body: Text('elsewhere')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router, api: api, runner: runner);
}

UtenEditableGridController<SalesGridRow> _grid(WidgetTester tester) => tester
    .widget<UtenEditableGrid<SalesGridRow>>(
      find.byType(UtenEditableGrid<SalesGridRow>),
    )
    .controller;

void main() {
  testWidgets('识别后的新建报价草稿: 硬关闭后恢复识别状态与行字段, 保存仍带 aiIntake', (tester) async {
    final storage = MemoryFormDraftStorage();
    var env = await _pump(tester, storage);
    FilePicker.platform = FakeFilePicker(fakeFile('UJ23 quotation.xlsx'));
    await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();

    final state =
        tester.state(find.byType(SalesDocEditPage))
            as FormDraftMixin<SalesDocEditPage>;
    await state.saveFormDraftNow();
    final draft = env.container.read(formDraftsProvider).single;
    final intake = draft.data['aiIntake'] as Map;
    expect(intake['jobId'], 'job-42');
    expect(intake['clientFields'], {'email': 'buyer@example.com'});
    expect(draft.data['clientFileCurrency'], 'USD');
    expect(env.api.writes, 0);

    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
    env = await _pump(tester, storage, location: draft.resumeLocation);
    // 恢复草稿不会再次识别。
    expect(env.runner.lastRequest, isNull);
    expect(env.runner.resumedJobId, isNull);
    expect(find.text('已从 UJ23 quotation.xlsx 导入 5 行'), findsOneWidget);
    final rows = _grid(tester).rows;
    final first = rows.firstWhere((r) => r.intakeLineKey == 'S1R9');
    expect(first.clientModel.text, 'GZ23/D');
    expect(first.clientPrice, '21');
    expect(first.setNameEn, isTrue);
    final review = rows.firstWhere((r) => r.intakeLineKey == 'S1R10');
    expect(review.aiReview, '颜色没对上');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final body = env.api.lastPostBody!;
    expect(body['aiIntake'], {
      'jobId': 'job-42',
      'clientFields': {'email': 'buyer@example.com'},
    });
    expect(body['clientFileCurrency'], 'USD');
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets('订货单「改为新建报价单」: 带 aiJobId 打开报价新建页即恢复同一次识别', (tester) async {
    final storage = MemoryFormDraftStorage();
    final env = await _pump(
      tester,
      storage,
      location: '/sales/quotes/new?aiJobId=job-99',
    );
    expect(env.runner.resumedJobId, 'job-99');
    expect(env.runner.lastRequest, isNull);
    expect(find.text('核对识别结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    // 报价单规则: 没标价的货品也导入(待财务定价)。
    expect(_grid(tester).rows.map((r) => r.intakeLineKey), contains('S1R12'));
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets('「改为新建报价单」带着原文件: 导入后原文件存进报价的暂存附件(客户确认)', (tester) async {
    final storage = MemoryFormDraftStorage();
    final env = await _pump(
      tester,
      storage,
      location: '/sales/quotes/new?aiJobId=job-99',
      extra: fakeFile('UJ23 quotation.xlsx'),
      permissions: const {
        Perm.salesQuoteView,
        Perm.salesQuoteCreate,
        Perm.salesQuoteEdit,
        Perm.salesOrderPriceView,
        Perm.attachmentUpload,
      },
    );
    expect(env.runner.resumedJobId, 'job-99');
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<BusinessAttachmentSection>(
          find.byType(BusinessAttachmentSection),
        )
        .draftController!;
    expect(controller.items.single.name, 'UJ23 quotation.xlsx');
    expect(controller.items.single.category, '客户确认');
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets('模拟身份(只读)带着 aiJobId 打开报价新建页: 不恢复识别', (tester) async {
    final storage = MemoryFormDraftStorage();
    final env = await _pump(
      tester,
      storage,
      location: '/sales/quotes/new?aiJobId=job-99',
      impersonating: true,
    );
    expect(env.runner.resumedJobId, isNull);
    expect(find.text('核对识别结果'), findsNothing);
    expect(find.byKey(const ValueKey('sales-intake-entry-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

/// 管理员「切换人」查看(只读)。
class _ImpersonatingSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'sales-person', code: 'S1', name: '业务员'),
    actor: AppUser(id: 'admin', code: 'A1', name: '管理员'),
    impersonationReadOnly: true,
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  Map<String, dynamic>? lastPostBody;
  int writes = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) {
      return [
        {'id': 'cny', 'name': '人民币'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes++;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    return {'id': 'quote-1', 'status': 0, 'writable': true};
  }
}
