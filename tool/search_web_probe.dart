// Task-owned production-Web search probe. Never a release entrypoint or company client.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/pages/admin_permissions_page.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _SearchSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'search-fixture',
      code: 'FIXTURE',
      name: '搜索验证',
      permissions: [Perm.accountSupport],
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final api = ApiClient(
    Dio(BaseOptions(baseUrl: Uri.base.resolve('/api').toString())),
  );
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_SearchSession.new),
        currentPermissionsProvider.overrideWith((ref) => {Perm.accountSupport}),
        isSuperAdminProvider.overrideWith((ref) => false),
        apiClientProvider.overrideWithValue(api),
        adminRepositoryProvider.overrideWithValue(DioAdminRepository(api)),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AdminPermissionsPage(),
      ),
    ),
  );
}
