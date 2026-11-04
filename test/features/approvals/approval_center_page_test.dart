import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/applications/pages/my_applications_page.dart';
import 'package:uten_imp/features/applications/pages/business_application_list_page.dart';
import 'package:uten_imp/features/approvals/pages/approval_center_page.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/pages/expense_detail_page.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/features/expense/widgets/expense_editable_items.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_detail_page.dart';
import 'package:uten_imp/features/applications/pages/business_application_edit_page.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_APPROVAL_CAPTURE');
bool _fontsLoaded = false;
final _captureKey = GlobalKey();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reviewer',
      employeeId: 'reviewer-employee',
      code: 'E003',
      name: '部门负责人',
      department: '综合营销部',
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Claims extends TaskClaimRepository {
  _Claims() : super(ApiClient(Dio()));
  @override
  Future<TaskClaimView?> claim(String targetType, String targetKey) async =>
      null;
  @override
  Future<void> release(String targetType, String targetKey) async {}
}

Map<String, dynamic> expenseExample(bool reviewing) => {
  'id': reviewing ? 'review-example' : 'draft-example',
  'claimNo': 'BX20261103000001',
  'title': '客户现场差旅报销（示例）',
  'applicantId': reviewing ? 'example-employee' : 'reviewer-employee',
  'applicantName': '示例员工',
  'departmentName': '综合营销部',
  'totalAmount': 2386.50,
  'expenseKind': 'TRAVEL',
  'status': reviewing ? 'REVIEWING' : 'DRAFT',
  'approvalRound': reviewing ? 1 : 0,
  'version': 3,
  'approvalStage': reviewing ? 'FINANCE_INITIAL' : null,
  'canApprove': reviewing,
  'createdAt': '2026-11-03T09:00:00+08:00',
  'items': [
    {
      'id': 'item-transport',
      'category': 'TRANSPORT',
      'amount': 326.50,
      'date': '2026-11-03',
      'description': '客户现场往返交通费',
    },
    {
      'id': 'item-travel',
      'category': 'TRAVEL',
      'amount': 2060.00,
      'date': '2026-11-03',
      'description': '客户现场出差住宿费',
    },
  ],
  'attachments': [
    for (final data in [
      ('hotel-proof', '示例住宿发票.pdf'),
      ('transport-proof', '示例交通票据.pdf'),
    ])
      {
        'id': data.$1,
        'ownerType': 'EXPENSE_CLAIM',
        'ownerId': reviewing ? 'review-example' : 'draft-example',
        'storageKey': 'example-only/${data.$1}',
        'originalName': data.$2,
        'contentType': 'application/pdf',
        'sizeBytes': 102400,
        'scanStatus': 'CLEAN',
        'originalAvailability': 'AVAILABLE',
        'uploadedAt': '2026-11-03T09:05:00+08:00',
      },
  ],
  'invoices': [
    for (final data in [
      (
        'hotel-invoice',
        1,
        '12345678901234567890',
        2060.0,
        'hotel-proof',
        '示例酒店',
      ),
      (
        'transport-invoice',
        2,
        '12345678901234567891',
        326.5,
        'transport-proof',
        '示例运输单位',
      ),
    ])
      {
        'id': data.$1,
        'lineNo': data.$2,
        'invoiceType': 'DIGITAL',
        'invoiceNo': data.$3,
        'totalAmount': data.$4,
        'amountExclTax': data.$4,
        'taxAmount': 0,
        'attachmentId': data.$5,
        'sellerName': data.$6,
        'buyerName': '示例公司',
        'issueDate': '2026-11-03',
        'checkState': reviewing ? 'VERIFIED_MANUAL' : 'AMOUNTS_MATCH',
        if (reviewing) 'verificationRemark': '示例：按原始凭证核对日期、抬头和金额一致',
        if (reviewing) 'verifiedByName': '示例财务初核员',
        if (reviewing) 'verifiedAt': '2026-11-03T10:10:00+08:00',
      },
  ],
  'events': [
    {
      'eventType': 'CREATED',
      'actorName': '示例员工',
      'occurredAt': '2026-11-03T09:00:00+08:00',
    },
    if (reviewing)
      {
        'eventType': 'SUBMITTED',
        'actorName': '示例员工',
        'approvalRound': 1,
        'occurredAt': '2026-11-03T09:10:00+08:00',
      },
    if (reviewing)
      {
        'eventType': 'STAGE_APPROVED',
        'actorName': '示例部门负责人',
        'approvalStage': 'DEPARTMENT',
        'approvalRound': 1,
        'occurredAt': '2026-11-03T10:00:00+08:00',
      },
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <({String path, Map<String, dynamic> query})>[];
  bool delayApplications = false;
  int postingTodo = 0, postingProgress = 0, personalPosting = 0;
  final applicationGates = <String, Completer<Map<String, dynamic>>>{};

  Map<String, dynamic> applicationPage(String kind) => {
    'page': 1,
    'size': 24,
    'total': 1,
    'totalPages': 1,
    'items': [
      {
        'id': 'application-$kind',
        'applicationNo': 'SQ20261103000001',
        'kind': kind,
        'title': kind == 'TRAVEL' ? '客户现场出差申请' : '样品材料付款申请',
        'amount': '1200.00',
        'status': 'SUBMITTED',
        'approvalStage': 'DEPARTMENT',
        'approvalStageLabel': '部门负责人审核',
        'canApprove': true,
        'applicantId': 'applicant',
        'applicantName': '申请员工',
        'departmentName': '综合营销部',
        'fields': <String, dynamic>{},
        'createdAt': '2026-11-03T09:00:00+08:00',
      },
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/platform-columns/scopes'
      ? [
          {
            'scope': 'expense_claim_item',
            'label': '报销明细',
            'canWrite': true,
            'priceVisible': true,
            'supportsValues': true,
          },
        ]
      : [];
  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async => [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add((path: path, query: Map.of(query ?? {})));
    if (path == '/expense-claims/draft-example' ||
        path == '/expense-claims/review-example') {
      return expenseExample(path.endsWith('review-example'));
    }
    if (path == '/expense-claims/mine') {
      return {
        'page': 1,
        'size': 24,
        'total': 1,
        'totalPages': 1,
        'items': [expenseExample(false)],
      };
    }
    if (path == '/expense-claims/settings') {
      return {'companyName': '示例公司', 'requireInvoice': false};
    }
    if (path == '/expense-claims/pending' ||
        path == '/expense-claims/history') {
      return {
        'page': 1,
        'size': 24,
        'total': 1,
        'totalPages': 1,
        'items': [
          {
            'id': 'expense-1',
            'claimNo': 'BX20261103000001',
            'title': '客户现场差旅报销',
            'applicantId': 'applicant',
            'applicantName': '申请员工',
            'departmentName': '综合营销部',
            'totalAmount': 2386.50,
            'status': 'SUBMITTED',
            'approvalStage': 'DEPARTMENT',
            'approvalStageLabel': '部门负责人审核',
            'canApprove': true,
            'createdAt': '2026-11-03T09:00:00+08:00',
          },
        ],
      };
    }
    if (path == '/business-applications/counts') {
      return {
        'prepaymentPostingTodoCount': postingTodo,
        'prepaymentPostingInProgressCount': postingProgress,
        'mineDraftCount': 2,
        'mineRejectedCount': 1,
        'mineProcessingCount': 3 + personalPosting,
        'pendingByScopeKind': {
          'DEPT_SALES': {'TRAVEL': 2, 'PAYMENT': 1},
        },
        'mineByKind': {
          'TRAVEL': {'DRAFT': 2, 'SUBMITTED': 3},
          'PAYMENT': {'REJECTED': 1},
          'PREPAYMENT': {'POSTING_PENDING': personalPosting},
        },
      };
    }
    if (path == '/business-applications/prepayment-posting') {
      final page = applicationPage('PREPAYMENT');
      final rows = page['items'] as List;
      final base = Map<String, dynamic>.from(rows.single as Map);
      base.addAll({
        'status': 'PAID',
        'postingStatus': 'PENDING',
        'canLinkFinance': true,
        'title': '供应商预付待入账（示例）',
        'approvalStage': null,
        'canApprove': false,
        'fields': {
          'supplierName': '示例供应商',
          'paymentDate': '2026-11-03',
          'paymentReference': '示例回单001',
        },
      });
      page['items'] = [
        for (var i = 0; i < postingTodo + postingProgress; i++)
          {
            ...base,
            'id': 'posting-$i',
            'applicationNo': 'SQ2026110300000${i + 1}',
            'amount': (1200 + i * 100).toStringAsFixed(2),
            'canLinkFinance': i < postingTodo,
          },
      ];
      page['total'] = postingTodo + postingProgress;
      return page;
    }
    if (path == '/business-applications/pending' ||
        path == '/business-applications/history' ||
        path == '/business-applications/mine') {
      final kind = query?['kind'] as String? ?? 'TRAVEL';
      if (delayApplications) {
        return applicationGates.putIfAbsent(kind, Completer.new).future;
      }
      return applicationPage(kind);
    }
    return {};
  }
}

Future<GoRouter> _pump(
  WidgetTester tester,
  _Api api,
  String route,
  Size size, {
  Set<String>? permissions,
  double textScale = 1,
  bool zeroApprovalTasks = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  if (_capture && !_fontsLoaded) {
    await loadAuditScreenshotFonts(tester);
    _fontsLoaded = true;
  }
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: route,
    routes: [
      GoRoute(
        path: '/applications/mine',
        builder: (_, state) => BusinessApplicationListPage(
          kind: state.uri.queryParameters['kind'],
        ),
      ),
      GoRoute(
        path: '/applications',
        builder: (_, _) => const MyApplicationsPage(),
      ),
      GoRoute(
        path: '/approvals/:departmentCode',
        builder: (_, state) => ApprovalCenterPage(
          departmentCode: state.pathParameters['departmentCode']!,
          initialGroup: state.uri.queryParameters['group'],
          initialApplicationQueue: state.uri.queryParameters['queue'],
        ),
      ),
      GoRoute(
        path: '/expense/example/draft',
        builder: (_, _) => const ExpenseDetailPage(claimId: 'draft-example'),
      ),
      GoRoute(
        path: '/expense/example/review',
        builder: (_, _) =>
            const ExpenseApprovalDetailPage(claimId: 'review-example'),
      ),
      GoRoute(
        path: '/applications/new',
        builder: (_, state) => BusinessApplicationEditPage(
          kind: state.uri.queryParameters['kind'],
        ),
      ),
      GoRoute(path: '/expense', builder: (_, _) => const ExpenseListPage()),
      GoRoute(
        path: '/expense/new',
        builder: (_, _) => const ExpenseClaimEditPage(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://approval.test/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        taskClaimRepositoryProvider.overrideWithValue(_Claims()),
        currentPermissionsProvider.overrideWithValue(
          permissions ??
              {
                Perm.expenseApply,
                Perm.expenseApproveDepartment,
                Perm.expenseApproveFinanceInitial,
                Perm.attachmentUpload,
                Perm.attachmentDelete,
                Perm.applicationApply,
                Perm.applicationApproveDepartment,
                Perm.salesOrderManagerView,
                Perm.attachmentView,
                Perm.attachmentDownload,
              },
        ),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {
              BadgeEntry.expenseMine: (2, 1),
              BadgeEntry.applicationMine: (3, 3 + api.personalPosting),
            },
            facts: {
              'expense.departmentPendingByCode.DEPT_SALES': zeroApprovalTasks
                  ? 0
                  : 1,
              'application.departmentPendingByCode.DEPT_SALES':
                  zeroApprovalTasks ? 0 : 3,
              'expense.draftCount': 2,
              'expense.processingCount': 1,
              'application.mineDraftCount': 2,
              'application.mineRejectedCount': 1,
              'application.mineProcessingCount': 3 + api.personalPosting,
              'application.prepaymentPostingTodoCount': api.postingTodo,
              'application.prepaymentPostingInProgressCount':
                  api.postingProgress,
            },
          ),
        ),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('unposted supplier prepayments remain in personal processing', (
    tester,
  ) async {
    final api = _Api()..personalPosting = 2;
    await _pump(
      tester,
      api,
      '/applications/mine?kind=PREPAYMENT',
      const Size(1440, 1000),
      permissions: {Perm.applicationApplyPrepayment},
    );
    final states = tester.widget<UtenFilterToolbar<String>>(
      find.byWidgetPredicate(
        (value) =>
            value is UtenFilterToolbar<String> &&
            value.segmentsKey == const Key('application-status-filter'),
      ),
    );
    expect(
      states.segments.singleWhere((value) => value.value == 'PROCESSING').count,
      2,
    );
    states.onSelectionChanged!('PROCESSING');
    await tester.pumpAndSettle();
    expect(
      api.queries
          .where((value) => value.path == '/business-applications/mine')
          .last
          .query['status'],
      'PROCESSING',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'prepayment posting follows red and yellow authority through finance scope',
    (tester) async {
      final api = _Api()
        ..postingTodo = 1
        ..postingProgress = 2;
      await _pump(
        tester,
        api,
        '/approvals/FINANCE?group=application&queue=prepayment-posting',
        const Size(1440, 1000),
        permissions: {Perm.applicationPrepaymentLinkFinance},
      );
      final states = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (value) =>
              value is UtenFilterToolbar<String> &&
              value.segmentsKey == const Key('application-status-filter'),
        ),
      );
      final posting = states.segments.singleWhere(
        (value) => value.value == 'prepayment-posting',
      );
      expect(posting.count, 1);
      expect(posting.inProgressCount, 2);
      expect(states.selected, {'prepayment-posting'});
      expect(
        api.queries
            .where(
              (value) =>
                  value.path == '/business-applications/prepayment-posting',
            )
            .last
            .query['kind'],
        'PREPAYMENT',
      );
      final table = tester.widget<MasterDataTableView<BusinessApplication>>(
        find.byType(MasterDataTableView<BusinessApplication>),
      );
      expect(table.error, isNull);
      expect(table.items, hasLength(3));
      expect(
        table.items.map((value) => value.statusLabel),
        everyElement(contains('待财务入账')),
      );
      expect(find.text('新建申请'), findsNothing);
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'manual-prepayment-posting',
        );
      }
    },
  );

  testWidgets(
    'approval center stays on guidance placeholder until a category is chosen',
    (tester) async {
      // 无任何待办/在办时进页面：不再兜底选中第一组，保持任务中心
      // 「默认不选、点击后加载」范式——子分类不出现、列表请求不发。
      final api = _Api();
      await _pump(
        tester,
        api,
        '/approvals/DEPT_SALES',
        const Size(1440, 1000),
        zeroApprovalTasks: true,
      );
      expect(find.byType(UtenFilterPlaceholder), findsOneWidget);
      expect(find.byKey(const Key('expense-approval-segments')), findsNothing);
      expect(find.byKey(const Key('application-kind-filter')), findsNothing);
      expect(
        api.queries.where((q) => q.path == '/expense-claims/pending'),
        isEmpty,
      );
      expect(
        api.queries.where((q) => q.path == '/business-applications/pending'),
        isEmpty,
      );
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'approval-center-placeholder',
        );
      }
      // 点击父分类后子分类行才出现并加载对应队列。
      final main = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (w) =>
              w is UtenFilterToolbar<String> &&
              w.segmentsKey == const Key('approval-center-categories'),
        ),
      );
      main.onSelectionChanged!('expense');
      await tester.pumpAndSettle();
      expect(find.byType(UtenFilterPlaceholder), findsNothing);
      expect(
        find.byKey(const Key('expense-approval-segments')),
        findsOneWidget,
      );
      expect(
        api.queries.where((q) => q.path == '/expense-claims/pending'),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'approval-center-clicked',
        );
      }
    },
  );

  testWidgets(
    'approval center auto-loads the first category with pending tasks',
    (tester) async {
      // 有待办分类时自动选中（红徽章优先），与任务中心 autoSelectBadge 同口径。
      final api = _Api();
      await _pump(tester, api, '/approvals/DEPT_SALES', const Size(1440, 1000));
      final main = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (w) =>
              w is UtenFilterToolbar<String> &&
              w.segmentsKey == const Key('approval-center-categories'),
        ),
      );
      expect(main.selected, {'expense'});
      expect(
        find.byKey(const Key('expense-approval-segments')),
        findsOneWidget,
      );
      expect(
        api.queries.where((q) => q.path == '/expense-claims/pending'),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'parent and child category rows share the container edge and rowGap',
    (tester) async {
      // 父分类行与子分类行同一左缘（页面容器 gutter，不再有 16px 手写缩进），
      // 行间距为任务中心统一 UtenFilterRow.rowGap（不再出现 8+8 双层叠加）。
      final api = _Api();
      await _pump(
        tester,
        api,
        '/approvals/DEPT_SALES?group=expense',
        const Size(1440, 1000),
      );
      final parent =
          tester.renderObject(
                find.byKey(const Key('approval-center-categories')),
              )
              as RenderBox;
      final child =
          tester.renderObject(
                find.byKey(const Key('expense-approval-segments')),
              )
              as RenderBox;
      final parentTopLeft = parent.localToGlobal(Offset.zero);
      final childTopLeft = child.localToGlobal(Offset.zero);
      expect(childTopLeft.dx, parentTopLeft.dx, reason: '子分类行应与父分类行同左缘');
      final gap = childTopLeft.dy - (parentTopLeft.dy + parent.size.height);
      expect(gap, UtenFilterRow.rowGap, reason: '父/子分类行间距应为统一 rowGap');
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets('approval center and self applications fit $size', (
      tester,
    ) async {
      final api = _Api();
      final router = await _pump(
        tester,
        api,
        '/approvals/DEPT_SALES?group=expense',
        size,
      );
      expect(tester.takeException(), isNull);
      expect(
        api.queries
            .where((q) => q.path == '/expense-claims/pending')
            .last
            .query,
        containsPair('departmentCode', 'DEPT_SALES'),
      );
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'approval-center-${size.width.toInt()}',
        );
      }
      router.go('/applications');
      await tester.pumpAndSettle();
      expect(find.text('我的申请'), findsOneWidget);
      expect(find.text('申请报销'), findsOneWidget);
      expect(find.text('申请出差'), findsOneWidget);
      expect(find.textContaining('工资'), findsNothing);
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'my-applications-${size.width.toInt()}',
        );
      }
      router.go('/expense/new');
      await tester.pumpAndSettle();
      final grid = tester.widget<ExpenseEditableItems>(
        find.byType(ExpenseEditableItems),
      );
      grid.controller.addRows([
        ExpenseGridRow()
          ..amount.text = '326.50'
          ..description.text = '客户现场往返交通费'
          ..date.value = DateTime(2026, 11, 3),
        ExpenseGridRow()
          ..amount.text = '2060.00'
          ..description.text = '客户现场出差住宿费'
          ..category.value = ExpenseCategory.travel
          ..date.value = DateTime(2026, 11, 3),
      ]);
      await tester.enterText(
        find.widgetWithText(TextField, '报销标题 *').first,
        '客户现场差旅报销（示例）',
      );
      await tester.pumpAndSettle();

      expect(find.text('保存并补充凭证'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'expense-editor-${size.width.toInt()}',
        );
      }
      router.go('/expense');
      await tester.pumpAndSettle();
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'manual-my-expenses-${size.width.toInt()}',
        );
      }
    });
  }

  testWidgets('manual examples show expense actions and travel fields', (
    tester,
  ) async {
    final api = _Api();
    final router = await _pump(
      tester,
      api,
      '/expense/example/draft',
      const Size(1440, 1800),
    );
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'manual-expense-applicant',
      );
    }
    router.go('/expense/example/review');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(tester, _captureKey, 'manual-expense-review');
    }
    router.go('/applications/new?kind=TRAVEL');
    await tester.pumpAndSettle();
    for (final entry in {
      '申请标题 *': '客户现场出差申请（示例）',
      '出差目的地 *': '深圳客户现场',
      '出差事由 *': '安装调试与现场验收',
      '交通方式': '高铁',
      '同行人员': '示例同事',
    }.entries) {
      final field = find.widgetWithText(TextField, entry.key).first;
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    for (final field in tester.widgetList<UtenDateField>(
      find.byType(UtenDateField),
    )) {
      field.onChanged(DateTime(2026, 11, 3));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'manual-application-travel',
      );
    }
  });

  testWidgets(
    'new deep link group takes effect and rapid kind changes reject late rows',
    (tester) async {
      final api = _Api();
      final router = await _pump(
        tester,
        api,
        '/approvals/DEPT_SALES?group=expense',
        const Size(1440, 1000),
      );
      router.go('/approvals/DEPT_SALES?group=application');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ApprovalCenterPage>(find.byType(ApprovalCenterPage))
            .initialGroup,
        'application',
        reason: router.routerDelegate.currentConfiguration.uri.toString(),
      );
      final main = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (w) =>
              w is UtenFilterToolbar<String> &&
              w.segmentsKey == const Key('approval-center-categories'),
        ),
      );
      expect(main.selected, {
        'application',
      }, reason: main.segments.map((v) => v.value).toString());
      expect(tester.takeException(), isNull);
      final genericTable = tester
          .widget<MasterDataTableView<BusinessApplication>>(
            find.byType(MasterDataTableView<BusinessApplication>),
          );
      expect(genericTable.error, isNull);
      expect(
        api.queries.any((q) => q.path == '/business-applications/pending'),
        isTrue,
        reason: api.queries.toString(),
      );
      expect(find.text('客户现场出差申请'), findsOneWidget);
      final kinds = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFilterToolbar<String> &&
              widget.segmentsKey == const Key('application-kind-filter'),
        ),
      );
      api.delayApplications = true;
      kinds.onSelectionChanged!('PAYMENT');
      await tester.pump();
      kinds.onSelectionChanged!('PREPAYMENT');
      await tester.pump();
      api.applicationGates['PREPAYMENT']!.complete(
        api.applicationPage('PREPAYMENT'),
      );
      await tester.pumpAndSettle();
      api.applicationGates['PAYMENT']!.complete(api.applicationPage('PAYMENT'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<BusinessApplication>>(
        find.byType(MasterDataTableView<BusinessApplication>),
      );
      expect(table.items.single.kind, 'PREPAYMENT');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'kind-only permission hides other creation cards at narrow large text',
    (tester) async {
      await _pump(
        tester,
        _Api(),
        '/applications',
        const Size(390, 844),
        permissions: {Perm.applicationApplyTravel},
        textScale: 1.5,
      );
      expect(find.text('申请出差'), findsOneWidget);
      expect(find.text('申请报销'), findsNothing);
      expect(find.text('申请付款'), findsNothing);
      expect(find.text('供应商付款申请'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
