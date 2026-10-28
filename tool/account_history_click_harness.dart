// Local browser-profile probe for the real login page and account-history menu.
// Uses synthetic account history and never submits credentials automatically.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/platform_tables_host.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

class _ProbeHistory extends AccountHistoryStore {
  _ProbeHistory() : super(SecureStorage(const FlutterSecureStorage()));

  final _accounts = ['probe-account-a', 'probe-account-b'];

  @override
  Future<List<String>> getAll() async => List.of(_accounts);

  @override
  Future<void> remove(String account) async => _accounts.remove(account);

  @override
  Future<void> clear() async => _accounts.clear();

  @override
  Future<void> add(String account) async {
    _accounts.remove(account);
    _accounts.insert(0, account);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final requestedZoom = double.tryParse(Uri.base.queryParameters['zoom'] ?? '');
  final zoom = requestedZoom != null && requestedZoom > 0 && requestedZoom <= 2
      ? requestedZoom
      : 1.0;
  runApp(
    ProviderScope(
      overrides: [
        accountHistoryProvider.overrideWithValue(_ProbeHistory()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
      ],
      child: MaterialApp(
        title: 'UTEN account history click probe',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => UtenContextMenuPolicy(
          child: PlatformTablesHost(
            child: UtenDisplayZoomBox(
              fontFactor: zoom,
              child: UtenControlTheme(
                child: UtenPageScrollbarHost(child: child!),
              ),
            ),
          ),
        ),
        home: const LoginPage(),
      ),
    ),
  );
}
