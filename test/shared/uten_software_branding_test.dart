import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/brand/uten_brand_mascot.dart';
import 'package:uten_imp/components/brand/uten_wordmark_logo.dart';
import 'package:uten_imp/core/constants/app_info.dart';
import 'package:uten_imp/core/constants/assets.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/client_update/software_downloads_presentation.dart';
import 'package:uten_imp/shared/platform_branding/platform_brand_logo.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'external UTEN identity leaves internal names and company identity intact',
    () async {
      const company = PlatformBranding(
        companyName: '示例公司法定名称',
        platformName: '旧公司的自定义平台名称',
      );
      expect(AppInfo.externalName, 'UTEN');
      expect(AppInfo.displayName, '优腾综合管理平台');
      expect(company.toUpdateJson()['platformName'], '旧公司的自定义平台名称');
      expect(company.copyright(2026), '© 2026 示例公司法定名称');
      const titles = {
        'zh': '优腾·综合管理平台',
        'en': 'Uten Integrated Management Platform',
        'ko': '우텅 통합 관리 플랫폼',
      };
      for (final entry in titles.entries) {
        final locale = Locale(entry.key);
        expect(
          (await AppLocalizations.delegate.load(locale)).appTitle,
          entry.value,
        );
        expect(
          softwareProductName(locale),
          entry.key == 'zh'
              ? '优腾综合管理平台(UIMP)'
              : 'Uten Integrated Management Platform (UIMP)',
        );
      }
    },
  );

  testWidgets('internal brand components retain the company presentation', (
    tester,
  ) async {
    const company = PlatformBranding(companyName: '示例公司', platformName: '示例平台');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
          platformBrandingSnapshotProvider.overrideWithValue(company),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UtenBrandMascot.size(64),
                UtenWordmarkLogo(),
                PlatformBrandLogo(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images, isEmpty);
    expect(find.text('UTEN'), findsNothing);
    expect(find.text('示例平台'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'login restores the original wide wordmark and company copyright',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      const company = PlatformBranding.defaults;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            platformBrandingSnapshotProvider.overrideWithValue(company),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('UTEN'), findsNothing);
      expect(find.text(company.tagline), findsOneWidget);
      expect(find.text('© ${DateTime.now().year} 优腾 · 综合管理平台'), findsOneWidget);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(
        images.map((image) => (image.image as AssetImage).assetName),
        containsAll([UtenAssets.logoName, UtenAssets.logoIp]),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'visible names never rename Windows persistence or installer product markers',
    () {
      final resource = File('windows/runner/Runner.rc').readAsStringSync();
      expect(resource, contains('VALUE "FileDescription", "UTEN"'));
      expect(resource, contains('VALUE "CompanyName", "Uten"'));
      expect(resource, contains('VALUE "ProductName", "优腾综合管理平台"'));
      final script = File(
        'deploy/client/windows_installer.iss',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(script, contains('AppId=com.uten.uten_imp.local_test'));
      expect(
        script,
        contains(
          'DefaultDirName={localappdata}\\Programs\\Uten\\UIMP-LocalTest',
        ),
      );
      expect(script, contains('AppId=com.uten.uten_imp\n'));
      expect(script, contains('VersionInfoProductName=Uten IMP Windows Setup'));
      expect(script, contains('VersionInfoOriginalFileName=UtenIMPSetup.exe'));
      expect(script, contains('english.AppDisplayName=UTEN\n'));
      expect(script, contains('chinesesimp.AppDisplayName=UTEN - 本地测试'));
      expect(
        script,
        contains(
          '#ifdef LocalTest\nUsePreviousAppDir=no\n#else\nUsePreviousAppDir=yes\n#endif',
        ),
      );
    },
  );
}
