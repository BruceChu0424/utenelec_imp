import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_release_publish_page.dart';
import 'package:uten_imp/features/client_update/client_release_publish_queue.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _apiSource = StateProvider<ApiClient>((_) => throw UnimplementedError());
late SharedPreferences _preferences;
SessionState _identity({
  String id = 'publisher-a',
  bool admin = false,
  List<String> permissions = const [Perm.clientReleasePublish],
  bool impersonating = false,
  AuthStatus status = AuthStatus.authenticated,
}) => SessionState(
  status: status,
  user: AppUser(
    id: id,
    code: id,
    name: id,
    permissions: permissions,
    superAdmin: admin,
  ),
  actor: impersonating
      ? const AppUser(
          id: 'actor',
          code: 'actor',
          name: 'actor',
          superAdmin: true,
        )
      : null,
);

class _Session extends SessionNotifier {
  _Session(this.initial);
  final SessionState initial;
  @override
  SessionState build() => initial;
  void replace(SessionState next) => state = next;
}

class _Storage implements FormDraftStorage {
  final records = <String, String>{};
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in records.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://fixture.test/api')));
  final creates = <Map<String, dynamic>>[],
      packages = <String>[],
      publishIds = <String>[];
  final uploadedBytes = <Uint8List>[],
      records = <String, Map<String, dynamic>>{};
  int listCalls = 0, withdrawCalls = 0;
  String? rejectKind, losePublishKind;
  Completer<void>? delayedUpload;
  Map<String, dynamic> _view(Map<String, dynamic> body) => {
    ...body,
    'id': body['requestId'],
    'sizeBytes': body['sizeBytes'] ?? 0,
    'installMode': body['platform'] == 'windows'
        ? body['runtimeFamily'] == ClientRuntimeFamily.wpfLegacy
              ? body['packageKind'] == 'installer'
                    ? 'windows_wpf_setup'
                    : 'windows_wpf_archive'
              : body['packageKind'] == 'installer'
              ? 'windows_setup'
              : 'windows_archive'
        : body['platform'] == 'android'
        ? 'android_package'
        : 'store',
    'deliveryContract': body['platform'] == 'windows'
        ? 'paired_v1'
        : body['platform'] == 'android'
        ? 'audited_v1'
        : null,
    'state': body['state'] ?? 'DRAFT',
  };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/admin/client-releases');
    listCalls++;
    return records.values.map(_view).toList();
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final record = records[path.split('/').last];
    if (record == null) {
      throw ApiException(
        'NOT_FOUND',
        'fixture record absent',
        httpStatus: 404,
        hasResponseCode: true,
      );
    }
    return _view(record);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/admin/client-releases') {
      final draft = Map<String, dynamic>.from(body! as Map);
      creates.add(draft);
      records.putIfAbsent(draft['requestId'] as String, () => draft);
      return _view(records[draft['requestId']]!);
    }
    final id = path.split('/')[3], record = records[id]!;
    if (path.endsWith('/withdraw')) {
      withdrawCalls++;
      record['state'] = 'WITHDRAWN';
      return _view(record);
    }
    expect(path, endsWith('/publish'));
    publishIds.add(id);
    if (record['packageKind'] == rejectKind) {
      throw ApiException(
        'VALIDATION_FAILED',
        'fixture publication rejected',
        httpStatus: 400,
        hasResponseCode: true,
      );
    }
    record['state'] = 'PUBLISHED';
    if (record['packageKind'] == losePublishKind) {
      losePublishKind = null;
      throw NetworkException('fixture publish receipt lost');
    }
    return _view(record);
  }

  @override
  Future<void> uploadClientPackage(
    String path,
    Uint8List bytes, {
    required void Function(int, int) onProgress,
  }) async {
    final id = path.split('/')[3];
    packages.add(id);
    uploadedBytes.add(Uint8List.fromList(bytes));
    records[id]!['sha256'] = sha256.convert(bytes).toString();
    records[id]!['sizeBytes'] = bytes.length;
    onProgress(bytes.length, bytes.length);
    await delayedUpload?.future;
  }
}

final _bytes = Uint8List.fromList([0x50, 0x4b, 3, 4, 10, 20, 30, 40]);
ClientReleasePickedFile _file(String name) =>
    ClientReleasePickedFile.bytes(name, _bytes);
Future<void> _pump(
  WidgetTester tester,
  _Api api,
  _Session session, {
  Size size = const Size(1440, 1100),
  double scale = 1,
  Brightness brightness = Brightness.light,
  GlobalKey? boundaryKey,
  _Storage? storage,
  List<ClientReleasePickedFile>? files,
  String platform = 'windows',
  String family = ClientRuntimeFamily.flutter,
  String architecture = 'x64',
  String kind = 'installer',
  bool tile = false,
  ValueChanged<List<ClientRelease>>? onPublished,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: tile ? '/settings' : RouteName.clientReleasePublish,
    routes: [
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: ClientReleasePublishTile()),
      ),
      DraftAwareGoRoute(
        path: RouteName.clientReleasePublish,
        builder: (_, _) => ClientReleasePublishPage(
          initialPlatform: platform,
          initialRuntimeFamily: family,
          initialArchitecture: architecture,
          initialPackageKind: kind,
          onPublished: onPublished,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _apiSource.overrideWith((_) => api),
        apiClientProvider.overrideWith((ref) => ref.watch(_apiSource)),
        sessionProvider.overrideWith(() => session),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiBaseUrlProvider.overrideWithValue('https://fixture.test/api'),
        formDraftStorageProvider.overrideWithValue(storage ?? _Storage()),
        clientReleaseFilePickerProvider.overrideWithValue(
          (multiple) async =>
              files ?? [_file('uten-setup.exe'), _file('uten-update.zip')],
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: brightness == Brightness.light
            ? buildLightTheme()
            : buildDarkTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: boundaryKey, child: app!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, '版本').first, '2.5.34');
  await tester.enterText(find.widgetWithText(TextField, '构建号').first, '2534');
  await tester.enterText(
    find.widgetWithText(TextField, '发布说明').first,
    '改进工作台与表格，保留原业务流程。',
  );
  await tester.pump();
}

Future<void> _add(WidgetTester tester, {bool single = false}) async {
  final action = find.text(single ? '添加单个文件' : '批量添加');
  await _reveal(tester, action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.hitTestable().evaluate().isNotEmpty) return;
  final element = tester.element(target);
  final render = element.findRenderObject()!;
  final vertical = <ScrollableState>[];
  element.visitAncestorElements((ancestor) {
    if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
      final state = ancestor.state as ScrollableState;
      if (axisDirectionToAxis(state.axisDirection) == Axis.vertical) {
        vertical.add(state);
      }
    }
    return true;
  });
  for (final state in vertical) {
    await state.position.ensureVisible(
      render,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _run(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('client-release-publish-batch'));
  await _reveal(tester, action);
  await tester.tap(action);
  await tester.pump();
  for (
    var turn = 0;
    turn < 100 && find.text('正在处理').evaluate().isNotEmpty;
    turn++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(find.text('正在处理'), findsNothing);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SOFTWARE_DOWNLOADS_SCREENSHOTS')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await boundary.toImage();
    try {
      final data = await picture.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/software-downloads-20261028/previews');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets(
    'settings opens a full publication route without an upload dialog',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, _Session(_identity()), tile: true);
      await tester.tap(find.byType(ClientReleasePublishTile));
      await tester.pumpAndSettle();
      expect(find.byType(ClientReleasePublishPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('批量添加'), findsOneWidget);
      expect(api.listCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mixed Setup and ZIP batch uses shared metadata and distinct stable intents',
    (tester) async {
      final api = _Api(), storage = _Storage();
      await _pump(tester, api, _Session(_identity()), storage: storage);
      await _fill(tester);
      await _add(tester);
      await _run(tester);
      expect(api.creates.map((r) => r['packageKind']).toSet(), {
        'installer',
        'update',
      });
      expect(api.creates.map((r) => r['requestId']).toSet(), hasLength(2));
      expect(
        api.creates.every(
          (r) => r['version'] == '2.5.34' && r['buildNumber'] == 2534,
        ),
        true,
      );
      expect(api.uploadedBytes, hasLength(2));
      expect(api.publishIds, hasLength(2));
      expect(storage.records, isNotEmpty);
      final saved = storage.records.values.join();
      expect(saved, contains('requestId'));
      expect(saved, isNot(contains('fixture.test/api/admin')));
      expect(saved, isNot(contains('Uint8List')));
      expect(tester.takeException(), isNull);
      await _run(tester);
      expect(api.publishIds, hasLength(2));
      expect(api.uploadedBytes, hasLength(2));
    },
  );
  testWidgets('single file upload preserves its exact legacy X86 target', (
    tester,
  ) async {
    final api = _Api();
    await _pump(
      tester,
      api,
      _Session(_identity()),
      family: ClientRuntimeFamily.wpfLegacy,
      architecture: 'x86',
      files: [_file('legacy-setup.exe')],
    );
    await _fill(tester);
    await _add(tester, single: true);
    await _run(tester);
    expect(api.creates.single['runtimeFamily'], 'wpf_legacy');
    expect(api.creates.single['architecture'], 'x86');
    expect(api.packages, hasLength(1));
    expect(api.publishIds, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'ledger withdrawal updates the visible result and never republishes it',
    (tester) async {
      final api = _Api();
      await _pump(
        tester,
        api,
        _Session(_identity()),
        files: [_file('setup.exe')],
      );
      await _fill(tester);
      await _add(tester, single: true);
      await _run(tester);
      expect(api.publishIds, hasLength(1));
      await tester.tap(find.text('发布记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(find.text('撤回这个版本？'), findsOneWidget);
      final withdrawPrompt = find.byType(UtenAlertDialog);
      final withdrawClose = find.descendant(
        of: withdrawPrompt,
        matching: find.byType(UtenCloseButton),
      );
      expect(withdrawClose.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: withdrawPrompt, matching: find.text('关闭')),
        findsNothing,
      );
      expect(
        find.descendant(of: withdrawPrompt, matching: find.text('取消')),
        findsNothing,
      );
      await tester.tap(withdrawClose);
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(api.withdrawCalls, 0);
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤回'));
      await tester.pumpAndSettle();
      expect(api.withdrawCalls, 1);
      expect(find.text('已撤回'), findsOneWidget);
      await tester.tap(find.text('发布队列'));
      await tester.pumpAndSettle();
      await _run(tester);
      expect(api.publishIds, hasLength(1));
      expect(api.creates, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial failure does not retransmit confirmed files', (
    tester,
  ) async {
    final api = _Api()..rejectKind = 'update';
    await _pump(tester, api, _Session(_identity()));
    await _fill(tester);
    await _add(tester);
    await _run(tester);
    expect(api.publishIds, hasLength(2));
    expect(api.uploadedBytes, hasLength(2));
    await _run(tester);
    expect(api.uploadedBytes, hasLength(2));
    expect(
      api.publishIds.where(
        (id) => api.records[id]!['packageKind'] == 'installer',
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'shared page navigation and alert close preserve the former popup close protection',
    (tester) async {
      final api = _Api()..delayedUpload = Completer<void>();
      final storage = _Storage();
      await _pump(
        tester,
        api,
        _Session(_identity()),
        tile: true,
        storage: storage,
        files: [_file('setup.exe')],
      );
      await tester.tap(find.byType(ClientReleasePublishTile));
      await tester.pumpAndSettle();
      final back = find.byType(UtenBackButton);
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(ClientReleasePublishPage), findsNothing);
      expect(find.byType(ClientReleasePublishTile), findsOneWidget);

      await tester.tap(find.byType(ClientReleasePublishTile));
      await tester.pumpAndSettle();
      await _fill(tester);
      await _add(tester, single: true);
      final publish = find.byKey(
        const ValueKey('client-release-publish-batch'),
      );
      await _reveal(tester, publish);
      await tester.tap(publish);
      await tester.pump();
      for (var frame = 0; frame < 100 && api.packages.isEmpty; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(api.packages, hasLength(1));
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ClientReleasePublishPage), findsOneWidget);
      expect(find.text('正在完成当前文件或提交状态，请稍候再离开。'), findsOneWidget);
      expect(api.publishIds, isEmpty);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.enabled == false),
        isTrue,
      );

      api.delayedUpload!.complete();
      for (var frame = 0; frame < 100 && api.publishIds.isEmpty; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(api.publishIds, hasLength(1));
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      final confirmation = find.byType(UtenAlertDialog);
      expect(confirmation, findsOneWidget);
      final close = find.descendant(
        of: confirmation,
        matching: find.byType(UtenCloseButton),
      );
      expect(close.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: confirmation, matching: find.text('关闭')),
        findsNothing,
      );
      expect(
        find.descendant(of: confirmation, matching: find.text('留在本页')),
        findsNothing,
      );
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(find.byType(ClientReleasePublishPage), findsOneWidget);
      expect(api.creates, hasLength(1));
      expect(api.publishIds, hasLength(1));

      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.byType(ClientReleasePublishPage), findsNothing);
      expect(storage.records, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lost publish receipt reconciles and finishes the original Windows intent',
    (tester) async {
      final api = _Api()..losePublishKind = 'installer';
      final callbacks = <List<ClientRelease>>[];
      await _pump(
        tester,
        api,
        _Session(_identity()),
        files: [_file('setup.exe')],
        onPublished: callbacks.add,
      );
      await _fill(tester);
      await _add(tester, single: true);
      await _run(tester);
      expect(callbacks, isEmpty);
      expect(api.creates, hasLength(1));
      expect(api.packages, hasLength(1));
      expect(api.publishIds, hasLength(1));
      final read = find.text('核对原状态').first;
      await _reveal(tester, read);
      await tester.tap(read);
      await tester.pumpAndSettle();
      expect(callbacks, isEmpty);
      await _run(tester);
      expect(callbacks.single.single.state, 'PUBLISHED');
      expect(api.creates, hasLength(1));
      expect(api.packages, hasLength(1));
      expect(api.publishIds, hasLength(2));
      expect(api.publishIds.toSet(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a real unbound superadmin can still manage publication', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, _Session(_identity(admin: true)));
    expect(find.text('批量添加'), findsOneWidget);
    expect(api.listCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late upload cannot publish for a replacement account', (
    tester,
  ) async {
    final api = _Api()..delayedUpload = Completer<void>();
    final session = _Session(_identity());
    final storage = _Storage();
    await _pump(
      tester,
      api,
      session,
      storage: storage,
      files: [_file('setup.exe')],
    );
    await _fill(tester);
    await _add(tester, single: true);
    await tester.tap(
      find.byKey(const ValueKey('client-release-publish-batch')),
    );
    await tester.pumpAndSettle();
    for (var frame = 0; frame < 100 && api.packages.isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(api.packages, hasLength(1));
    session.replace(_identity(id: 'publisher-b'));
    await tester.pump();
    api.delayedUpload!.complete();
    await tester.pumpAndSettle();
    expect(api.publishIds, isEmpty);
    expect(find.textContaining('发布身份、权限或服务器已变化'), findsOneWidget);
    expect(storage.records, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android keeps APK publication as one target-specific item', (
    tester,
  ) async {
    final api = _Api();
    await _pump(
      tester,
      api,
      _Session(_identity()),
      platform: 'android',
      architecture: 'arm64',
      kind: 'update',
      files: [_file('uten.apk')],
    );
    await _fill(tester);
    await _add(tester, single: true);
    await _run(tester);
    expect(api.creates.single['platform'], 'android');
    expect(api.creates.single['architecture'], 'arm64');
    expect(api.packages, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  for (final (label, identity) in [
    ('missing permission', _identity(permissions: [])),
    ('impersonation', _identity(impersonating: true)),
    ('expired login', _identity(status: AuthStatus.unauthenticated)),
  ]) {
    testWidgets('direct page denies $label', (tester) async {
      final api = _Api();
      await _pump(tester, api, _Session(identity));
      expect(api.listCalls, 0);
      expect(find.text('批量添加'), findsNothing);
      expect(api.creates, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [375.0, 844.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final name =
            'publisher-${width.toInt()}-${brightness.name}-${(scale * 100).toInt()}';
        testWidgets('full publisher responsive $name', (tester) async {
          final key = GlobalKey();
          await _pump(
            tester,
            _Api(),
            _Session(_identity()),
            size: Size(width, 1100),
            brightness: brightness,
            scale: scale,
            boundaryKey: key,
          );
          await _fill(tester);
          await _add(tester);
          expect(find.textContaining('文件队列'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _capture(tester, key, name);
          await tester.ensureVisible(
            find.byKey(const ValueKey('client-release-publish-batch')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
