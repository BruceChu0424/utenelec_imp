// Loopback-only regression entrypoint. Never used for company/release builds.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/pages/admin_permissions_page.dart';
import 'package:uten_imp/features/admin/pages/server_status_page.dart';
import 'package:uten_imp/features/notice/pages/notice_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _permissions = [
  Perm.authorizationManage,
  Perm.accountSupport,
  'server_status:view',
];

class _ProbeSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'probe-admin',
      code: 'FIXTURE',
      name: '回归管理员',
      superAdmin: true,
      permissions: _permissions,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1') throw StateError('Loopback fixture only');
  final base = Uri.base.resolve('/api').toString();
  final storage = SecureStorage(const FlutterSecureStorage());
  await storage.saveTokens(
    issuer: AuthBackendRealmPolicy().issuerFor(base),
    accessToken: 'fixture-access-0',
    refreshToken: 'fixture-refresh',
  );
  final preferences = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        secureStorageProvider.overrideWithValue(storage),
        apiBaseUrlProvider.overrideWithValue(base),
        authBackendRealmPolicyProvider.overrideWithValue(
          AuthBackendRealmPolicy(),
        ),
        sessionProvider.overrideWith(_ProbeSession.new),
        currentPermissionsProvider.overrideWith((ref) => _permissions.toSet()),
        isSuperAdminProvider.overrideWith((ref) => true),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _ProbeHome(),
      ),
    ),
  );
}

class _ProbeHome extends StatefulWidget {
  const _ProbeHome();
  @override
  State<_ProbeHome> createState() => _ProbeHomeState();
}

class _ProbeHomeState extends State<_ProbeHome> {
  int _page = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _page = 0),
              child: const Text('回归：账号权限'),
            ),
            TextButton(
              onPressed: () => setState(() => _page = 1),
              child: const Text('回归：服务器状态'),
            ),
            TextButton(
              onPressed: () => setState(() => _page = 2),
              child: const Text('回归：离开页面'),
            ),
            TextButton(
              onPressed: () => setState(() => _page = 3),
              child: const Text('回归：通知'),
            ),
          ],
        ),
        Expanded(
          child: switch (_page) {
            0 => const AdminPermissionsPage(),
            1 => const ServerStatusPage(),
            3 => const NoticeListPage(),
            _ => const Center(child: Text('已离开')),
          },
        ),
      ],
    ),
  );
}
