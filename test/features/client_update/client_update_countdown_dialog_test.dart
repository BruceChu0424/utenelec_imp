import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_update_dialog.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';

const release = ClientRelease(
  id: '69fdcabe-0ae7-47cd-8d49-8136b21a4321',
  platform: 'windows',
  architecture: 'x64',
  version: '2.5.28',
  buildNumber: 2528,
  releaseNotes: '修复已知问题',
  installMode: 'windows_archive',
);

Future<void> pumpDialog(
  WidgetTester tester, {
  required List<bool> installs,
}) async {
  webUpdateSafety.setReady(true);
  addTearDown(() => webUpdateSafety.setReady(false));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showClientUpdateCountdownDialog(
                  context,
                  release: release,
                  currentVersion: '2.5.27',
                  onInstall: ({required bool automatic}) async {
                    installs.add(automatic);
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the countdown ticks visibly in the number and the button', (
    tester,
  ) async {
    final installs = <bool>[];
    await pumpDialog(tester, installs: installs);
    expect(find.text('有新的版本（2.5.28）'), findsOneWidget);
    expect(find.text('立即更新（10）'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('秒后自动更新'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('立即更新（9）'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('立即更新（6）'), findsOneWidget);
    expect(installs, isEmpty);
  });

  testWidgets('稍后 cancels the immediate update entirely', (tester) async {
    final installs = <bool>[];
    await pumpDialog(tester, installs: installs);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('有新的版本（2.5.28）'), findsNothing);
    expect(installs, isEmpty);
  });

  testWidgets('the primary button installs immediately without the wait', (
    tester,
  ) async {
    final installs = <bool>[];
    await pumpDialog(tester, installs: installs);
    await tester.tap(find.text('立即更新（10）'));
    await tester.pump();
    expect(installs, [false]);
  });

  testWidgets('reaching zero installs automatically', (tester) async {
    final installs = <bool>[];
    await pumpDialog(tester, installs: installs);
    await tester.pump(const Duration(seconds: 10));
    expect(installs, [true]);
  });

  testWidgets('unfinished work at zero pauses and fires once it is safe', (
    tester,
  ) async {
    final installs = <bool>[];
    var dirty = false;
    final owner = Object();
    webUpdateSafety.register(owner, () => WebUpdateSafetyState(dirty: dirty));
    addTearDown(() => webUpdateSafety.unregister(owner));
    await pumpDialog(tester, installs: installs);
    dirty = true;
    webUpdateSafety.changed();
    await tester.pump(const Duration(seconds: 10));
    expect(installs, isEmpty);
    expect(find.text('当前操作完成后自动更新'), findsOneWidget);
    dirty = false;
    webUpdateSafety.changed();
    await tester.pump();
    expect(installs, [true]);
  });
}
