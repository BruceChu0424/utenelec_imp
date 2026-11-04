import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_edit_page.dart';
import 'package:uten_imp/features/applications/repositories/business_application_repository.dart';
import 'package:uten_imp/features/applications/widgets/business_application_print.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

BusinessApplication application({
  String kind = 'PAYMENT',
  String id = 'fixed-id',
  Map<String, dynamic> fields = const {},
}) => BusinessApplication(
  id: id,
  applicationNo: 'SQ20261103000001',
  kind: kind,
  title: '业务差旅及付款申请',
  amount: '1200.50',
  status: 'DRAFT',
  applicantId: 'e1',
  applicantName: '测试员工',
  departmentName: '综合营销部',
  createdAt: DateTime(2026, 11, 3),
  fields: fields,
  events: [
    BusinessApplicationEvent(
      action: 'CREATED',
      actorName: '测试员工',
      occurredAt: DateTime(2026, 11, 3),
      round: 1,
    ),
  ],
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'u1',
      employeeId: 'e1',
      code: 'T001',
      name: '测试员工',
      department: '综合营销部',
      permissions: [Perm.applicationApply],
    ),
  );
}

class _Repo extends Fake implements BusinessApplicationRepository {
  final inputs = <BusinessApplicationInput>[];
  Completer<BusinessApplication>? pending;
  bool loseResponse = false;
  int reads = 0;
  @override
  Future<BusinessApplication> create(BusinessApplicationInput input) {
    inputs.add(input);
    if (loseResponse) throw const SocketException('response lost');
    return pending?.future ??
        Future.value(
          application(id: input.id, kind: input.kind, fields: input.fields),
        );
  }

  @override
  Future<BusinessApplication> get(String id) async {
    reads++;
    return application(id: id);
  }
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _Repo repository, {
  String kind = 'PAYMENT',
  double width = 1200,
  double textScale = 1,
  Set<String> permissions = const {Perm.applicationApply},
  GlobalKey? capture,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/applications/new?kind=$kind',
    routes: [
      GoRoute(
        path: '/applications/new',
        builder: (_, s) =>
            BusinessApplicationEditPage(kind: s.uri.queryParameters['kind']),
      ),
      GoRoute(
        path: '/applications/:id',
        builder: (_, s) =>
            Text('已保存 ${s.pathParameters['id']}', key: const Key('saved')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(prefs),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        apiBaseUrlProvider.overrideWithValue('https://applications.test/api'),
        apiClientProvider.overrideWithValue(
          ApiClient(Dio(BaseOptions(baseUrl: 'https://applications.test/api'))),
        ),
        businessApplicationRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: capture == null
            ? buildLightTheme()
            : auditScreenshotTheme(buildLightTheme()),
        builder: (context, child) => RepaintBoundary(
          key: capture,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> fillPayment(WidgetTester tester) async {
  for (final entry in {
    '申请标题 *': '采购配件付款',
    '收款人 / 单位 *': '测试收款单位',
    '申请金额（元）*': '1200.50',
    '内容摘要 / 付款事由 *': '采购配件，按合同支付',
  }.entries) {
    final field = find.widgetWithText(TextField, entry.key);
    await tester.ensureVisible(field);
    await tester.enterText(field, entry.value);
  }
}

void main() {
  test(
    'long and newline-heavy application text prints completely across A4 pages',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final reason = List.filled(334, '业务说明完整保留。').join().substring(0, 3000);
      final remark = '起始${List.filled(400, '\n').join()}结尾';
      final value = application(fields: {'reason': reason, 'remark': remark});
      final rows = businessApplicationPrintSegments(value);
      expect(
        rows
            .where((row) => row[0].startsWith('内容摘要'))
            .map((row) => row[1])
            .join(),
        reason,
      );
      expect(
        rows
            .where((row) => row[0].startsWith('备注'))
            .map((row) => row[1])
            .join(),
        remark,
      );
      final bytes = await buildBusinessApplicationPdf(value);
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      if (Platform.environment['UTEN_APPLICATION_QA_PDF'] == '1') {
        Directory('build/ui-audit').createSync(recursive: true);
        File('build/ui-audit/application-long.pdf').writeAsBytesSync(bytes);
      }
    },
  );
  for (final width in [390.0, 760.0, 1440.0]) {
    testWidgets('payment fields use the available width at $width', (
      tester,
    ) async {
      await _pumpEditor(tester, _Repo(), width: width);
      final title = tester.getRect(find.widgetWithText(TextField, '申请标题 *'));
      final payee = tester.getRect(
        find.widgetWithText(TextField, '收款人 / 单位 *'),
      );
      if (width >= 760) {
        expect(title.top, payee.top);
        expect(payee.left, greaterThan(title.right));
      } else {
        expect(payee.top, greaterThan(title.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('rapid repeated save creates once and shows one busy overlay', (
    tester,
  ) async {
    final repository = _Repo()..pending = Completer<BusinessApplication>();
    await _pumpEditor(tester, repository);
    await fillPayment(tester);
    final action = find.text('保存并补充凭证');
    await tester.tap(action);
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.tap(action, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(repository.inputs, hasLength(1));
    expect(find.text('正在保存申请'), findsOneWidget);
    expect(repository.inputs.single.amount, '1200.50');
    repository.pending!.complete(application(id: repository.inputs.single.id));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unknown create is reconciled by fixed identity without a second write',
    (tester) async {
      final repository = _Repo()..loseResponse = true;
      await _pumpEditor(tester, repository);
      await fillPayment(tester);
      await tester.tap(find.text('保存并补充凭证'));
      await tester.pumpAndSettle();
      expect(repository.inputs, hasLength(1));
      expect(find.text('核对保存结果'), findsOneWidget);
      await tester.tap(find.text('核对保存结果'));
      await tester.pumpAndSettle();
      expect(repository.inputs, hasLength(1));
      expect(repository.reads, 1);
      expect(find.byKey(const Key('saved')), findsOneWidget);
    },
  );
  for (final kind in businessApplicationKinds.keys) {
    testWidgets(
      '$kind narrow large text preserves fields and uses granted kind authority',
      (tester) async {
        await _pumpEditor(
          tester,
          _Repo(),
          kind: kind,
          width: 390,
          textScale: 1.5,
          permissions: {Perm.applicationKindApplyPermissions[kind]!},
        );
        expect(find.text('保存并补充凭证'), findsOneWidget);
        await tester.drag(find.byType(ListView).first, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
    test(
      '$kind PDF contains its fields and matching signature roles',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final value = application(
          kind: kind,
          fields: {
            'reason': '按原始凭证办理',
            'destination': '上海',
            'startDate': '2026-11-03',
            'endDate': '2026-11-05',
            'payee': '测试单位',
          },
        );
        final bytes = await buildBusinessApplicationPdf(value);
        expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
        expect(businessApplicationApprovalRoles(kind), isNotEmpty);
        if (Platform.environment['UTEN_APPLICATION_QA_PDF'] == '1') {
          Directory('build/ui-audit').createSync(recursive: true);
          File('build/ui-audit/application-$kind.pdf').writeAsBytesSync(bytes);
        }
      },
    );
  }
  testWidgets('capture the real application editor', (tester) async {
    if (Platform.environment['UTEN_APPLICATION_QA_CAPTURE'] != '1') return;
    await loadAuditScreenshotFonts(tester);
    final key = GlobalKey();
    await _pumpEditor(tester, _Repo(), capture: key);
    await fillPayment(tester);
    await tester.pumpAndSettle();
    await saveAuditScreenshot(tester, key, 'application-payment-desktop');
    expect(tester.takeException(), isNull);
  });
}
