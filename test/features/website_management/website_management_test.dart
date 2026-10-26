import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/website_management/models/website_management.dart';
import 'package:uten_imp/features/website_management/pages/website_management_page.dart';
import 'package:uten_imp/features/website_management/providers/website_management_providers.dart';
import 'package:uten_imp/features/website_management/repositories/website_management_repository.dart';
import 'package:uten_imp/features/webinquiry/models/website_inquiry.dart';
import 'package:uten_imp/features/webinquiry/widgets/website_inquiry_source_timeline.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';

const _permissions = {
  Perm.websiteView,
  Perm.websiteContentEdit,
  Perm.websiteProductEdit,
  Perm.websiteMediaManage,
  Perm.websitePublish,
  Perm.websiteRollback,
  Perm.webinquiryView,
  Perm.authorizationManage,
};
const _info = WebsiteManagementInfo(
  version: 3,
  displayName: 'UTEN',
  publicOrigin: 'https://www.ch-uten.com',
  adminOrigin: 'https://www.ch-uten.com',
  enabled: true,
  configured: true,
  tokenConfigured: true,
  canConfigure: true,
  permissions: _permissions,
  allowedOrigins: ['https://www.ch-uten.com'],
);
const _ownerA = AuthenticatedScope(userId: 'a');
final _owner = StateProvider<AuthenticatedScope?>((ref) => _ownerA);

WebsiteManagementInfo _originInfo(String origin, {String? publicOrigin}) =>
    WebsiteManagementInfo(
      version: 1,
      displayName: 'Local acceptance',
      publicOrigin: publicOrigin ?? origin,
      adminOrigin: origin,
      enabled: true,
      configured: true,
      tokenConfigured: true,
      permissions: _permissions,
    );

class _EmployeeSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'E001', name: '王工', employeeId: 'employee-a'),
  );
}

class _Repository implements WebsiteManagementRepository {
  int loads = 0, checks = 0, opens = 0;
  Object? checkFailure;
  Completer<WebsiteConnectionCheck>? pendingCheck;
  Completer<WebsiteEditorGrant>? pendingGrant;
  String entryUrl = 'https://www.ch-uten.com/admin/imp-entry';
  String? challenge;
  @override
  Future<WebsiteManagementInfo> load() async {
    loads++;
    return _info;
  }

  @override
  Future<WebsiteConnectionCheck> check() async {
    checks++;
    if (checkFailure != null) throw checkFailure!;
    return pendingCheck?.future ??
        Future.value(
          WebsiteConnectionCheck(
            checkedAt: DateTime.utc(2026, 10, 17),
            reachable: true,
            ready: true,
          ),
        );
  }

  WebsiteEditorGrant grant() => WebsiteEditorGrant(
    entryUrl: entryUrl,
    code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
    expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 60)),
  );
  @override
  Future<WebsiteEditorGrant> open({
    required String section,
    required String codeChallenge,
  }) async {
    opens++;
    challenge = codeChallenge;
    return pendingGrant?.future ?? Future.value(grant());
  }

  @override
  Future<WebsiteManagementInfo> configure({
    required int expectedVersion,
    required String displayName,
    required String publicOrigin,
    required bool enabled,
  }) async => _info;
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository, {
  Set<String> permissions = _permissions,
  bool superAdmin = false,
  List<Uri>? launched,
  Size size = const Size(1300, 1000),
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        websiteManagementRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(superAdmin),
        apiBaseUrlProvider.overrideWithValue('https://erp.example/api'),
        apiClientProvider.overrideWithValue(
          ApiClient(Dio(BaseOptions(baseUrl: 'https://erp.example/api'))),
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        websiteExternalLauncherProvider.overrideWithValue((uri) async {
          launched?.add(uri);
          return true;
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const WebsiteManagementPage(),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(WebsiteManagementPage)),
  );
}

void main() {
  for (final scenario in [
    (owner: 'employee-a', readOnly: false, claim: true, allowed: true),
    (owner: 'employee-b', readOnly: false, claim: true, allowed: false),
    (owner: 'employee-a', readOnly: true, claim: true, allowed: false),
    (owner: 'employee-a', readOnly: false, claim: false, allowed: false),
  ]) {
    testWidgets(
      'follow-up editor respects assignment, permission and read-only scope $scenario',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final inquiry = WebsiteInquiry(
          id: 'q',
          name: 'Customer',
          message: 'Inquiry',
          status: WebsiteInquiryStatus.following,
          receivedAt: DateTime.utc(2026),
          assigneeEmployeeId: scenario.owner,
          timeline: [
            WebsiteInquiryEvent(
              id: 'event',
              kind: 'claimed',
              createdAt: DateTime.utc(2026),
              actorName: '王工',
              actorEmployeeCode: 'E001',
            ),
          ],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              sessionProvider.overrideWith(_EmployeeSession.new),
              authenticatedScopeProvider.overrideWithValue(
                AuthenticatedScope(userId: 'a', readOnly: scenario.readOnly),
              ),
              currentPermissionsProvider.overrideWithValue({
                if (scenario.claim) Perm.webinquiryClaim,
              }),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: WebsiteInquiryTimelineCard(inquiry: inquiry),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('website-inquiry-save-follow-up')),
          scenario.allowed ? findsOneWidget : findsNothing,
        );
        expect(find.textContaining('王工(E001)'), findsOneWidget);
      },
    );
  }
  test('route and workbench gate require the same website permission', () {
    expect(requiredAnyPermFor(RouteName.websiteManagement), [Perm.websiteView]);
    expect(
      locationAllowedFor(
        {Perm.webinquiryView},
        false,
        RouteName.websiteManagement,
      ),
      isFalse,
    );
    expect(
      locationAllowedFor(
        {Perm.websiteView},
        false,
        RouteName.websiteManagement,
      ),
      isTrue,
    );
  });

  test(
    'handoff uses random S256 proof and a fragment, never query parameters',
    () {
      final proof = WebsiteHandoffProof.create();
      final other = WebsiteHandoffProof.create();
      expect(proof.verifier, hasLength(43));
      expect(other.verifier, isNot(proof.verifier));
      expect(
        proof.challenge,
        base64UrlEncode(
          sha256.convert(utf8.encode(proof.verifier)).bytes,
        ).replaceAll('=', ''),
      );
      final uri = websiteEditorUri(
        info: _info,
        grant: _Repository().grant(),
        proof: proof,
        now: DateTime.now().toUtc(),
        releaseMode: false,
        allowLoopbackHttp: false,
      );
      expect(uri.hasQuery, isFalse);
      expect(Uri.splitQueryString(uri.fragment)['verifier'], proof.verifier);
      expect(uri.path, '/admin/imp-entry');
    },
  );

  for (final origin in [
    'http://127.0.0.1:3008',
    'http://localhost:3008',
    'http://[::1]:3008',
  ]) {
    test(
      'loopback origin requires an explicit non-Release opt-in: $origin',
      () {
        final info = _originInfo(origin);
        final proof = WebsiteHandoffProof.create();
        final now = DateTime.now().toUtc();
        final grant = WebsiteEditorGrant(
          entryUrl: '$origin/admin/imp-entry',
          code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
          expiresAt: now.add(const Duration(seconds: 60)),
        );
        expect(
          () => websiteOriginUri(
            origin,
            releaseMode: false,
            allowLoopbackHttp: false,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(
          () => websiteEditorUri(
            info: info,
            grant: grant,
            proof: proof,
            now: now,
            releaseMode: false,
            allowLoopbackHttp: false,
          ),
          throwsA(isA<ApiException>()),
        );
        final uri = websiteEditorUri(
          info: info,
          grant: grant,
          proof: proof,
          now: now,
          releaseMode: false,
          allowLoopbackHttp: true,
        );
        expect(uri.origin, Uri.parse(origin).origin);
        expect(uri.path, '/admin/imp-entry');
        expect(uri.hasQuery, isFalse);
        expect(Uri.splitQueryString(uri.fragment)['verifier'], proof.verifier);
        expect(
          websiteOriginUri(
            origin,
            releaseMode: false,
            allowLoopbackHttp: true,
          ).origin,
          uri.origin,
        );
        expect(
          () => websiteOriginUri(
            origin,
            releaseMode: true,
            allowLoopbackHttp: true,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(
          () => websiteEditorUri(
            info: info,
            grant: grant,
            proof: proof,
            now: now,
            releaseMode: true,
            allowLoopbackHttp: true,
          ),
          throwsA(isA<ApiException>()),
        );
      },
    );
  }

  for (final origin in [
    'http://192.168.1.10:3008',
    'http://10.0.0.5:3008',
    'http://www.ch-uten.com',
    'http://localhost.evil.test:3008',
    'http://localhost.:3008',
    'http://127.0.0.1.evil.test:3008',
    'http://127.0.0.2:3008',
    'http://127.1:3008',
    'http://[::ffff:127.0.0.1]:3008',
    'http://user@localhost:3008',
    'http://@localhost:3008',
    'http://localhost:3008/path',
    'http://localhost:3008?x=1',
    'http://localhost:3008?',
    'http://localhost:3008#x',
    'http://localhost:3008#',
  ]) {
    test(
      'local opt-in cannot trust other origins or decorated URLs: $origin',
      () {
        expect(
          () => websiteOriginUri(
            origin,
            releaseMode: false,
            allowLoopbackHttp: true,
          ),
          throwsA(isA<ApiException>()),
        );
      },
    );
  }

  test('local opt-in keeps all editor origin, fixed path and grant checks', () {
    const origin = 'http://127.0.0.1:3008';
    final now = DateTime.now().toUtc();
    final proof = WebsiteHandoffProof.create();
    for (final entry in [
      'http://localhost:3008/admin/imp-entry',
      'http://127.0.0.1:3009/admin/imp-entry',
      'https://127.0.0.1:3008/admin/imp-entry',
      '$origin/admin/users',
      '$origin/admin/imp-entry?code=in-query',
      '$origin/admin/imp-entry#existing',
      'http://@127.0.0.1:3008/admin/imp-entry',
    ]) {
      expect(
        () => websiteEditorUri(
          info: _originInfo(origin),
          grant: WebsiteEditorGrant(
            entryUrl: entry,
            code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
            expiresAt: now.add(const Duration(seconds: 60)),
          ),
          proof: proof,
          now: now,
          releaseMode: false,
          allowLoopbackHttp: true,
        ),
        throwsA(isA<ApiException>()),
        reason: entry,
      );
    }
    expect(
      () => websiteEditorUri(
        info: _originInfo(origin, publicOrigin: 'http://localhost:3008'),
        grant: WebsiteEditorGrant(
          entryUrl: '$origin/admin/imp-entry',
          code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
          expiresAt: now.add(const Duration(seconds: 60)),
        ),
        proof: proof,
        now: now,
        releaseMode: false,
        allowLoopbackHttp: true,
      ),
      throwsA(isA<ApiException>()),
    );
    for (final expiresAt in [
      now,
      now.add(const Duration(minutes: 2, seconds: 1)),
    ]) {
      expect(
        () => websiteEditorUri(
          info: _originInfo(origin),
          grant: WebsiteEditorGrant(
            entryUrl: '$origin/admin/imp-entry',
            code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
            expiresAt: expiresAt,
          ),
          proof: proof,
          now: now,
          releaseMode: false,
          allowLoopbackHttp: true,
        ),
        throwsA(isA<ApiException>()),
      );
    }
  });

  test(
    'HTTPS production origins remain valid with either local flag value',
    () {
      for (final allowLocal in [false, true]) {
        expect(
          websiteOriginUri(
            _info.publicOrigin,
            releaseMode: true,
            allowLoopbackHttp: allowLocal,
          ).scheme,
          'https',
        );
        expect(
          websiteEditorUri(
            info: _info,
            grant: _Repository().grant(),
            proof: WebsiteHandoffProof.create(),
            now: DateTime.now().toUtc(),
            releaseMode: true,
            allowLoopbackHttp: allowLocal,
          ).scheme,
          'https',
        );
      }
    },
  );

  for (final bad in [
    'https://www.ch-uten.com.evil.test/admin/imp-entry',
    'https://evil.test/admin/imp-entry',
    'http://www.ch-uten.com/admin/imp-entry',
    'https://user@www.ch-uten.com/admin/imp-entry',
    'https://www.ch-uten.com/admin/imp-entry?code=x',
    'https://www.ch-uten.com/admin/imp-entry#x',
    'https://www.ch-uten.com/admin/users',
  ]) {
    test('rejects untrusted handoff target $bad', () {
      final repository = _Repository()..entryUrl = bad;
      expect(
        () => websiteEditorUri(
          info: _info,
          grant: repository.grant(),
          proof: WebsiteHandoffProof.create(),
          now: DateTime.now().toUtc(),
          releaseMode: false,
          allowLoopbackHttp: false,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  }
  test('expired grant cannot open a browser', () {
    expect(
      () => websiteEditorUri(
        info: _info,
        grant: WebsiteEditorGrant(
          entryUrl: 'https://www.ch-uten.com/admin/imp-entry',
          code: 'abcdefghijklmnopqrstuvwxyz0123456789ABCD',
          expiresAt: DateTime.utc(2020),
        ),
        proof: WebsiteHandoffProof.create(),
        now: DateTime.now().toUtc(),
        releaseMode: false,
        allowLoopbackHttp: false,
      ),
      throwsA(isA<ApiException>()),
    );
  });

  testWidgets('unauthorized page never requests cloud state', (tester) async {
    final repo = _Repository();
    await _mount(tester, repo, permissions: {Perm.webinquiryView});
    await tester.pumpAndSettle();
    expect(repo.loads, 0);
    expect(repo.checks, 0);
    expect(find.text('当前账号没有官网管理权限。'), findsOneWidget);
  });
  testWidgets(
    'initial load awaits a real check and connection errors retain the sales inbox',
    (tester) async {
      final repo = _Repository()
        ..checkFailure = ApiException('UNAVAILABLE', 'unavailable');
      await _mount(tester, repo);
      await tester.pumpAndSettle();
      expect(repo.loads, 1);
      expect(repo.checks, 1);
      expect(find.text('连接正常'), findsNothing);
      expect(find.text('暂不可编辑'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('website-open-overview')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('销售询盘收件箱'), findsWidgets);
      expect(find.byKey(const ValueKey('website-configure')), findsNothing);
    },
  );
  testWidgets(
    'read-only permission hides editors and super-admin configuration requires authorization',
    (tester) async {
      await _mount(
        tester,
        _Repository(),
        permissions: {Perm.websiteView},
        superAdmin: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('产品目录'), findsNothing);
      expect(find.byKey(const ValueKey('website-configure')), findsNothing);
    },
  );
  testWidgets('authorized super administrator can open trusted configuration', (
    tester,
  ) async {
    await _mount(tester, _Repository(), superAdmin: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('website-configure')));
    await tester.pumpAndSettle();
    expect(find.text('已批准的官网地址'), findsWidgets);
    expect(find.text('保存连接配置'), findsOneWidget);
  });
  testWidgets('untrusted entry response never reaches the external launcher', (
    tester,
  ) async {
    final repo = _Repository()..entryUrl = 'https://evil.test/admin/imp-entry';
    final launched = <Uri>[];
    await _mount(tester, repo, launched: launched);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('website-open-overview')));
    await tester.pumpAndSettle();
    expect(repo.opens, 1);
    expect(launched, isEmpty);
    expect(repo.challenge, hasLength(43));
  });
  testWidgets(
    'session switch during handoff suppresses late browser navigation',
    (tester) async {
      final repo = _Repository()
        ..pendingGrant = Completer<WebsiteEditorGrant>();
      final launched = <Uri>[];
      final container = await _mount(tester, repo, launched: launched);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('website-open-overview')));
      await tester.pump();
      container.read(_owner.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      repo.pendingGrant!.complete(repo.grant());
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
    },
  );
  testWidgets('narrow view at 200 percent text scale has no overflow', (
    tester,
  ) async {
    await _mount(tester, _Repository(), size: const Size(390, 844), scale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'multiple source products retain identities and expand explicitly',
    (tester) async {
      final inquiry = WebsiteInquiry(
        id: 'q',
        name: 'Customer',
        message: 'Need switches',
        status: WebsiteInquiryStatus.newOne,
        receivedAt: DateTime.utc(2026),
        sourceContext: const {
          'series': 'S300',
          'products': [
            {
              'id': 'first-id',
              'name': 'One gang',
              'series': 'S300',
              'sourceIdentity': 'zh:1084',
            },
            {
              'id': 'second-id',
              'name': 'Two gang',
              'series': 'S300',
              'sourceIdentity': 'zh:1058',
            },
          ],
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: WebsiteInquirySourceCard(inquiry: inquiry)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('first-id'), findsOneWidget);
      expect(find.textContaining('second-id'), findsNothing);
      await tester.tap(find.text('展开全部关联产品'));
      await tester.pumpAndSettle();
      expect(find.textContaining('second-id'), findsOneWidget);
      expect(find.textContaining('zh:1058'), findsOneWidget);
    },
  );
}
