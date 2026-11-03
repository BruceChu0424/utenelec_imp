// Offline native UI acceptance fixture. Never a distributable application.
// No authentication, HTTP or real installer; the production controller writes
// and verifies synthetic streamed bytes in a new temporary staging directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/web_update/app_update_safety_host.dart';
import 'package:uten_imp/core/web_update/update_safety_navigation.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_staged_update.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/client_update_controller.dart';
import 'package:uten_imp/features/client_update/client_update_host.dart';
import 'package:uten_imp/features/client_update/client_update_navigation.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final staging = await Directory.systemTemp.createTemp(
    'uten-update-native-ui-',
  );
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
      ],
      child: _Harness(staging: staging),
    ),
  );
}

class _Server extends ApiClient {
  _Server()
    : super(Dio(BaseOptions(baseUrl: 'https://offline-fixture.invalid/api')));
  final bytes = Uint8List(16 * 1024 * 1024);
  late final digest = sha256.convert(bytes).toString();
  int checks = 0, downloads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    checks++;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return {
      'updateAvailable': true,
      'release': {
        'id': '7bf6f638-c21f-464c-a1b2-814ae447f190',
        'platform': 'windows',
        'architecture': 'x64',
        'version': '2.5.44',
        'buildNumber': 2544,
        'installMode': 'windows_archive',
        'sizeBytes': bytes.length,
        'sha256': digest,
        'releaseNotes': '离线验收示例\n检查更新提示、下载进度和安装反馈。',
      },
    };
  }

  @override
  Future<Stream<Uint8List>> getPackageStream(
    String path, {
    required CancelToken cancelToken,
  }) async {
    downloads++;
    return _stream(cancelToken);
  }

  Stream<Uint8List> _stream(CancelToken cancellation) async* {
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      if (cancellation.isCancelled) {
        throw const FormatException('Cancelled fixture');
      }
      await Future<void>.delayed(const Duration(milliseconds: 12));
      yield Uint8List.sublistView(bytes, offset, offset + 65536);
    }
  }
}

class _Installer extends ClientUpdateBridge {
  _Installer(this.path);
  final String path;
  bool fail = false;
  int attempts = 0, handoffs = 0;
  @override
  Future<ClientInstallContext> context() async => ClientInstallContext(
    platform: 'windows',
    architecture: 'x64',
    currentVersion: '2.5.43+2543',
    currentBuild: 2543,
    supportsInPlaceUpdate: true,
    stagingDirectory: path,
  );
  @override
  Future<String> install(String path, ClientRelease release) async {
    attempts++;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (fail) throw PlatformException(code: 'UPDATE_START_FAILED');
    handoffs++;
    return 'installerOpened';
  }
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness({required this.staging});
  final Directory staging;
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  final navigator = GlobalKey<NavigatorState>();
  final server = _Server();
  final updateNavigation = ClientUpdateNavigation();
  late final rootSafety = UpdateSafetyNavigation();
  late final installer = _Installer(widget.staging.path);
  late ClientUpdateController controller;
  late final GoRouter router;
  int login = 0;
  bool dirty = false;
  Duration clockOffset = Duration.zero;
  final events = <Map<String, Object?>>[];

  void _newController() {
    controller = ClientUpdateController(
      api: server,
      bridge: installer,
      canInstall: () => webUpdateSafety.safeToReload,
    )..addListener(_receipt);
  }

  void _receipt() {
    events.add({
      'stage': controller.stage.name,
      'waiting': controller.waitingForSafeInstall,
      'checks': server.checks,
      'downloads': server.downloads,
      'attempts': installer.attempts,
      'handoffs': installer.handoffs,
      'dirty': dirty,
    });
    // Fixture data only, containing no accounts, credentials or business input.
    File('build/client-update-native-ui-receipt.json').writeAsStringSync(
      jsonEncode({
        'offlineFixture': true,
        'realInstallerInvoked': false,
        'staging': widget.staging.path,
        'events': events,
      }),
    );
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _newController();
    webUpdateSafety.setReady(true);
    webUpdateSafety.register(this, () => WebUpdateSafetyState(dirty: dirty));
    UserActivity.clock = () => DateTime.now().add(clockOffset);
    router = GoRouter(
      navigatorKey: navigator,
      initialLocation: RouteName.settings,
      observers: [rootSafety, updateNavigation],
      routes: [
        GoRoute(
          path: RouteName.settings,
          builder: (_, _) => const Scaffold(body: ClientUpdateTile()),
        ),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await const MethodChannel(
        'com.uten.imp/desktop_window',
      ).invokeMethod<void>('setMode', 'main');
      await const MethodChannel(
        'com.uten.imp/window_title',
      ).invokeMethod<void>('setTitle', 'UTEN 软件更新离线交互验收');
    });
  }

  @override
  void dispose() {
    controller.dispose();
    router.dispose();
    rootSafety.dispose();
    webUpdateSafety.unregister(this);
    UserActivity.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      clientUpdateControllerProvider.overrideWithValue(controller),
      clientStagedUpdateStoreProvider.overrideWithValue(
        controller.stagedUpdates,
      ),
      clientUpdateNavigationProvider.overrideWithValue(updateNavigation),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: buildLightTheme(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (_, child) => Column(
        children: [
          AppUpdateSafetyHost(router: router),
          ClientUpdateHost(
            key: ValueKey(login),
            enabled: true,
            dialogContext: () => navigator.currentContext,
          ),
          Expanded(child: child!),
          Material(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('离线验收：不连接服务器、不执行安装'),
                  TextButton(
                    onPressed: () {
                      setState(() => dirty = !dirty);
                      webUpdateSafety.changed();
                      _receipt();
                    },
                    child: Text(dirty ? '保存模拟工作' : '模拟未保存工作'),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => installer.fail = !installer.fail),
                    child: Text(installer.fail ? '恢复安装' : '模拟安装失败'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => clockOffset += const Duration(minutes: 6));
                    },
                    child: const Text('模拟空闲6分钟'),
                  ),
                  TextButton(
                    onPressed: () {
                      controller.dispose();
                      _newController();
                      setState(() => login++);
                    },
                    child: const Text('模拟重新登录'),
                  ),
                  Text(
                    '下载 ${server.downloads} / 安装尝试 ${installer.attempts} / 交接 ${installer.handoffs}',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
