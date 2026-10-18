import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/pages/admin_remote_access_page.dart';
import 'package:uten_imp/features/admin/repositories/remote_access_repository.dart';
import 'package:uten_imp/features/auth/pages/remote_mfa_page.dart';
import 'package:uten_imp/features/auth/remote_access_text.dart';
import 'package:uten_imp/features/auth/repositories/remote_mfa_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _identity = StateProvider(
  (ref) => const AuthenticatedScope(userId: 'one'),
);
RemoteAccessStatus _status({
  String channel = 'local',
  int version = 2,
  bool enabled = false,
  int max = 5,
}) => RemoteAccessStatus(
  policy: RemoteAccessPolicy(enabled: enabled, maxUsers: max, version: version),
  authorizedUsers: const [
    RemoteAccessUser(
      id: 'u1',
      username: 'worker1',
      displayName: '测试员工',
      mfaEnabled: false,
      remoteAccess: true,
    ),
  ],
  authorizedCount: 1,
  remoteChannelConfigured: false,
  currentAccessChannel: channel,
  observedAt: DateTime.utc(2026, 10, 17, 10),
  deploymentId: 'company-one',
);

class _AdminRepo implements RemoteAccessRepository {
  RemoteAccessStatus current = _status();
  int reads = 0, saves = 0;
  int? expected;
  Completer<RemoteAccessStatus>? pending;
  @override
  Future<RemoteAccessStatus> status() async {
    reads++;
    return pending?.future ?? current;
  }

  @override
  Future<void> save({
    required bool enabled,
    required int maxUsers,
    required int expectedVersion,
  }) async {
    saves++;
    expected = expectedVersion;
    current = _status(
      version: expectedVersion + 1,
      enabled: enabled,
      max: maxUsers,
    );
  }

  @override
  Future<void> revoke(String userId) async {}
  @override
  Future<void> resetMfa(String userId, String reason) async {}
}

class _MfaRepo implements RemoteMfaRepository {
  bool enabled = false;
  int enrolls = 0, confirms = 0;
  Completer<RemoteMfaEnrollment>? pendingEnrollment;
  @override
  Future<RemoteMfaStatus> status() async => RemoteMfaStatus(
    enabled: enabled,
    pending: false,
    sessionVerified: false,
    enrollmentAllowed: true,
    remoteRequest: false,
  );
  @override
  Future<RemoteMfaEnrollment> enroll() async {
    enrolls++;
    if (pendingEnrollment != null) return pendingEnrollment!.future;
    return RemoteMfaEnrollment(
      secret: 'JBSWY3DPEHPK3PXP',
      otpauthUri:
          'otpauth://totp/Test:worker?secret=JBSWY3DPEHPK3PXP&issuer=Test',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<RemoteMfaStatus> confirm(String otpCode) async {
    expect(otpCode, '001234');
    confirms++;
    enabled = true;
    return status();
  }

  @override
  Future<void> disable(String otpCode) async {}
  @override
  Future<DateTime> verify(String otpCode) async =>
      DateTime.now().add(const Duration(hours: 1));
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Widget page,
  _AdminRepo? admin,
  _MfaRepo? mfa,
  bool allowed = true,
  bool dark = false,
  double scale = 1,
  String language = 'zh',
  Size size = const Size(1200, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        apiBaseUrlProvider.overrideWithValue('https://office.invalid/api'),
        isSuperAdminProvider.overrideWithValue(allowed),
        currentPermissionsProvider.overrideWithValue({
          Perm.authorizationManage,
        }),
        if (admin != null)
          remoteAccessRepositoryProvider.overrideWithValue(admin),
        if (mfa != null) remoteMfaRepositoryProvider.overrideWithValue(mfa),
      ],
      child: RepaintBoundary(
        key: const Key('remote-access-capture'),
        child: MaterialApp(
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(page.runtimeType)),
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['REMOTE_ACCESS_PREVIEW'];
  if (output == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('remote-access-capture')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test('route requires both administrator status and actual grant', () {
    expect(
      locationAllowedFor(
        {Perm.authorizationManage},
        false,
        RouteName.adminRemoteAccess,
      ),
      isFalse,
    );
    expect(locationAllowedFor({}, true, RouteName.adminRemoteAccess), isFalse);
    expect(
      locationAllowedFor(
        {Perm.authorizationManage},
        true,
        RouteName.adminRemoteAccess,
      ),
      isTrue,
    );
    expect(locationAllowedFor({}, false, RouteName.remoteMfa), isTrue);
  });
  test('all new wording has Chinese, English and Korean content', () {
    for (final entry in remoteAccessTexts.entries) {
      expect(entry.value, hasLength(3), reason: entry.key);
      expect(entry.value.every((text) => text.isNotEmpty), isTrue);
    }
  });
  testWidgets('non-admin cannot fetch privileged status', (tester) async {
    final repo = _AdminRepo();
    await _pump(
      tester,
      page: const AdminRemoteAccessPage(),
      admin: repo,
      allowed: false,
    );
    expect(repo.reads, 0);
    expect(find.text('只有超级管理员可管理外网访问'), findsOneWidget);
  });
  testWidgets(
    'unconfigured channel stays explicit and policy save uses read version',
    (tester) async {
      final repo = _AdminRepo();
      await _pump(tester, page: const AdminRemoteAccessPage(), admin: repo);
      expect(find.text('未接入'), findsOneWidget);
      await _capture(tester, 'remote-admin-desktop');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('remote-access-limit')),
          matching: find.byType(TextField),
        ),
        '8',
      );
      await tester.tap(find.byKey(const Key('remote-access-save')));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(repo.expected, 2);
      expect(repo.current.policy.maxUsers, 8);
      expect(repo.reads, 2);
    },
  );
  testWidgets('remote policy is read-only while revoke stays available', (
    tester,
  ) async {
    final repo = _AdminRepo()..current = _status(channel: 'remote');
    await _pump(tester, page: const AdminRemoteAccessPage(), admin: repo);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('remote-access-save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('remote-revoke-u1')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<UtenInput>(find.byKey(const Key('remote-access-limit')))
          .enabled,
      isFalse,
    );
  });
  for (final language in ['zh', 'en', 'ko']) {
    testWidgets('narrow dark large text remains usable in $language', (
      tester,
    ) async {
      await _pump(
        tester,
        page: const AdminRemoteAccessPage(),
        admin: _AdminRepo(),
        dark: true,
        scale: 1.6,
        language: language,
        size: const Size(390, 1000),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('setup secret is removed when the account changes', (
    tester,
  ) async {
    final repo = _MfaRepo();
    final container = await _pump(
      tester,
      page: const RemoteMfaPage(),
      mfa: repo,
    );
    await tester.tap(find.byKey(const Key('mfa-enroll')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mfa-secret')), findsOneWidget);
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'two',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mfa-secret')), findsNothing);
    expect(repo.enrolls, 1);
  });
  for (final width in [320.0, 360.0]) {
    testWidgets('management at $width with large text has no overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        page: const AdminRemoteAccessPage(),
        admin: _AdminRepo(),
        dark: true,
        scale: 1.6,
        size: Size(width, 1000),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    testWidgets('personal setup at $width with large text has no overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        page: const RemoteMfaPage(),
        mfa: _MfaRepo(),
        dark: true,
        scale: 1.6,
        size: Size(width, 1200),
      );
      await tester.tap(find.byKey(const Key('mfa-enroll')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('mfa-setup-otp')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (width == 360) await _capture(tester, 'remote-mfa-mobile-dark');
    });
  }
  testWidgets(
    'late enrollment response cannot reveal previous account secret',
    (tester) async {
      final pending = Completer<RemoteMfaEnrollment>();
      final repo = _MfaRepo()..pendingEnrollment = pending;
      final container = await _pump(
        tester,
        page: const RemoteMfaPage(),
        mfa: repo,
      );
      await tester.tap(find.byKey(const Key('mfa-enroll')));
      await tester.pump();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'new-user',
      );
      await tester.pumpAndSettle();
      pending.complete(
        RemoteMfaEnrollment(
          secret: 'PREVIOUS-ACCOUNT-SECRET',
          otpauthUri: 'otpauth://totp/Test?secret=OLD',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('PREVIOUS-ACCOUNT-SECRET'), findsNothing);
      expect(find.byKey(const Key('mfa-secret')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'setup confirms code then removes secret and shows enabled state',
    (tester) async {
      final repo = _MfaRepo();
      await _pump(
        tester,
        page: const RemoteMfaPage(),
        mfa: repo,
        size: const Size(1000, 1500),
      );
      await tester.tap(find.byKey(const Key('mfa-enroll')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('mfa-setup-otp')),
          matching: find.byType(TextField),
        ),
        '001234',
      );
      await tester.ensureVisible(find.byKey(const Key('mfa-confirm')));
      await tester.tap(find.byKey(const Key('mfa-confirm')));
      await tester.pumpAndSettle();
      expect(repo.confirms, 1);
      expect(find.byKey(const Key('mfa-secret')), findsNothing);
      expect(find.text('验证器已绑定'), findsOneWidget);
    },
  );
}
