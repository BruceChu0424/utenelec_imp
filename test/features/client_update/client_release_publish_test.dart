import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/client_update/client_release_publish_dialog.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _apiSource = StateProvider<ApiClient>(
  (ref) => throw UnimplementedError(),
);

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
    superAdmin: admin,
    permissions: permissions,
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

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://fixture.test/api')));
  final creates = <Map<String, dynamic>>[];
  final packages = <String>[];
  final published = <String>{};
  final uploadedSha = <String, String>{};
  final uploadedBytes = <Uint8List>[];
  int listCalls = 0;
  int scopeCaptures = 0;
  int publishCalls = 0;
  final publishIds = <String>[];
  int withdrawCalls = 0;
  bool loseFirstPublishResponse = false;
  final losePublishResponseKinds = <String>{};
  final failPublishKinds = <String>{};
  final failRetentionOnceKinds = <String>{};
  final failCreateKinds = <String>{};
  Completer<Map<String, dynamic>>? delayedCreate;
  Completer<void>? delayedUpload;
  String? delayedUploadKind;
  Completer<void>? delayedScope;
  Future<void> Function(String kind)? afterPublish;
  final uploadProgress = <void Function(int, int)>[];

  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    scopeCaptures++;
    final scope = await super.captureRequestScope(isCurrent: isCurrent);
    final delay = delayedScope;
    if (delay != null) await delay.future;
    await scope.verify();
    return scope;
  }

  Map<String, dynamic> _release(Map<String, dynamic> body) => {
    ...body,
    'id': body['requestId'],
    'installMode': body['platform'] == 'windows'
        ? body['packageKind'] == 'installer'
              ? 'windows_setup'
              : 'windows_archive'
        : body['platform'] == 'android'
        ? 'android_package'
        : 'store',
    'sha256': uploadedSha[body['requestId']],
    'state': published.contains(body['requestId']) ? 'PUBLISHED' : 'DRAFT',
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/admin/client-releases');
    listCalls++;
    final known = {
      for (final body in creates)
        if (published.contains(body['requestId'])) body['requestId']: body,
    };
    return known.values.map(_release).toList();
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
      if (failCreateKinds.remove(draft['packageKind'] ?? 'update')) {
        throw ApiException('NETWORK_ERROR', 'fixture create response lost');
      }
      return delayedCreate?.future ?? _release(draft);
    }
    if (path.endsWith('/withdraw')) {
      withdrawCalls++;
      published.remove(path.split('/')[3]);
      return _release(creates.last);
    }
    expect(path, matches(r'^/admin/client-releases/[0-9a-f-]{36}/publish$'));
    publishCalls++;
    final identifier = path.split('/')[3];
    publishIds.add(identifier);
    final draft = creates.lastWhere((body) => body['requestId'] == identifier);
    final kind = draft['packageKind'] as String? ?? 'update';
    if (failPublishKinds.contains(kind)) {
      throw ApiException('CONFLICT', 'fixture package publication rejected');
    }
    published.add(identifier);
    await afterPublish?.call(kind);
    if (failRetentionOnceKinds.remove(kind)) {
      throw ApiException(
        'PRIMARY_UNAVAILABLE',
        'fixture retention failed after publication committed',
      );
    }
    if (loseFirstPublishResponse && publishCalls == 1 ||
        losePublishResponseKinds.remove(kind)) {
      // The command committed, but the client did not receive its receipt.
      throw ApiException('NETWORK_ERROR', 'fixture response lost');
    }
    return _release(draft);
  }

  @override
  Future<void> uploadClientPackage(
    String path,
    Uint8List bytes, {
    required void Function(int, int) onProgress,
  }) async {
    packages.add(path);
    expect(creates.last['platform'], anyOf('windows', 'android'));
    uploadedBytes.add(Uint8List.fromList(bytes));
    uploadProgress.add(onProgress);
    uploadedSha[path.split('/')[3]] = sha256.convert(bytes).toString();
    onProgress(bytes.length, bytes.length);
    final kind = creates.lastWhere(
      (body) => body['requestId'] == path.split('/')[3],
    )['packageKind'];
    if (delayedUpload != null &&
        (delayedUploadKind == null || kind == delayedUploadKind)) {
      await delayedUpload!.future;
    }
  }
}

class _WindowsPackagePicker extends FilePicker {
  _WindowsPackagePicker(
    this.bytes, {
    this.installer = false,
    this.android = false,
  });
  final Uint8List bytes;
  final bool installer;
  final bool android;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, [
      android
          ? 'apk'
          : installer
          ? 'exe'
          : 'zip',
    ]);
    expect(withData, isTrue);
    return FilePickerResult([
      PlatformFile(
        name: android
            ? 'uten-android-universal.apk'
            : installer
            ? 'uten-windows-x64-setup.exe'
            : 'uten-windows-x64.zip',
        size: bytes.length,
        bytes: bytes,
      ),
    ]);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Api api,
  _Session session, {
  Widget child = const ClientReleasePublishDialog(),
  Size size = const Size(900, 1200),
  double scale = 1,
  GlobalKey? boundaryKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _apiSource.overrideWith((ref) => api),
        apiClientProvider.overrideWith((ref) => ref.watch(_apiSource)),
        sessionProvider.overrideWith(() => session),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: boundaryKey, child: app!),
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillStore(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('ios').last);
  await tester.pumpAndSettle();
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), '2.5.28');
  await tester.enterText(fields.at(1), '2528');
  await tester.enterText(fields.at(2), '修复采购任务提醒');
  await tester.enterText(
    fields.at(3),
    'https://apps.apple.com/cn/app/id123456789',
  );
  await tester.pump();
}

Finder _publishAction() =>
    find.byKey(const ValueKey('client-release-publish-batch'));

Future<void> _publish(WidgetTester tester) async {
  final action = _publishAction();
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<Uint8List> _fillWindows(
  WidgetTester tester, {
  bool installer = false,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), '2.5.28');
  await tester.enterText(fields.at(1), '2528');
  await tester.enterText(fields.at(2), 'Windows 更新验证');
  return _chooseWindows(tester, installer: installer);
}

Future<Uint8List> _chooseWindows(
  WidgetTester tester, {
  bool installer = false,
}) async {
  // Synthetic bytes exercise UI upload/hash/retry; backend tests validate ZIP structure.
  final bytes = Uint8List.fromList([
    installer ? 0x4d : 0x50,
    installer ? 0x5a : 0x4b,
    3,
    4,
    10,
    20,
    30,
    40,
  ]);
  final previousPicker = FilePicker.platform;
  FilePicker.platform = _WindowsPackagePicker(bytes, installer: installer);
  addTearDown(() => FilePicker.platform = previousPicker);
  final choose = find.text(installer ? '选择完整客户端' : '选择更新包');
  await tester.ensureVisible(choose);
  await tester.tap(choose);
  await tester.pumpAndSettle();
  expect(
    find.text(
      installer ? 'uten-windows-x64-setup.exe' : 'uten-windows-x64.zip',
    ),
    findsOneWidget,
  );
  return bytes;
}

Finder _result(String kind) =>
    find.byKey(ValueKey('client-release-result-$kind'));

Future<void> _captureDualUpload(WidgetTester tester, GlobalKey key) async {
  if (!const bool.fromEnvironment('SOFTWARE_DOWNLOADS_SCREENSHOTS')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/software-downloads-20261026/previews');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/windows-dual-upload.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('SOFTWARE_DOWNLOADS_SCREENSHOTS')) {
      await (FontLoader(
        'NotoSansSC',
      )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  setUp(() => FilePicker.platform = _WindowsPackagePicker(Uint8List(0)));

  testWidgets('Windows shows both upload areas with one shared metadata form', (
    tester,
  ) async {
    final api = _Api();
    final key = GlobalKey();
    await _pump(
      tester,
      api,
      _Session(_identity()),
      size: const Size(1440, 1100),
      boundaryKey: key,
    );
    await _fillWindows(tester, installer: true);
    await _chooseWindows(tester);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    expect(find.text('Windows 安装程序（Setup.exe）'), findsOneWidget);
    expect(find.text('Windows 更新包（ZIP）'), findsOneWidget);
    expect(find.text('uten-windows-x64-setup.exe'), findsOneWidget);
    expect(find.text('uten-windows-x64.zip'), findsOneWidget);
    expect(find.text('上传并发布'), findsOneWidget);
    for (final kind in ['installer', 'update']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('client-release-area-$kind')),
          matching: find.text('上传并发布'),
        ),
        findsNothing,
      );
    }
    expect(api.creates, isEmpty);
    expect(tester.takeException(), isNull);
    await _captureDualUpload(tester, key);
  });

  testWidgets(
    'one footer action publishes both selected Windows packages with shared metadata and scope',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, _Session(_identity()));
      final setup = await _fillWindows(tester, installer: true);
      final update = await _chooseWindows(tester);
      final scopesBefore = api.scopeCaptures;
      await _publish(tester);
      expect(find.text('uten-windows-x64.zip'), findsOneWidget);
      expect(api.creates, hasLength(2));
      expect(api.scopeCaptures - scopesBefore, 1);
      expect(api.creates.map((body) => body['packageKind']), [
        'installer',
        'update',
      ]);
      expect(api.creates[0]['requestId'], isNot(api.creates[1]['requestId']));
      for (final key in [
        'platform',
        'architecture',
        'version',
        'buildNumber',
        'releaseNotes',
      ]) {
        expect(api.creates[0][key], api.creates[1][key]);
      }
      expect(api.uploadedBytes, [setup, update]);
      expect(api.published, hasLength(2));
      expect(api.publishCalls, 2);
      expect(find.text('客户端新版本已发布'), findsNWidgets(2));
      expect(tester.widget<UtenButton>(_publishAction()).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one successful package stays published when the other fails and retries',
    (tester) async {
      final api = _Api()..failPublishKinds.add('update');
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await _publish(tester);
      expect(api.published, hasLength(1));
      expect(
        find.descendant(
          of: _result('installer'),
          matching: find.text('客户端新版本已发布'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _result('update'),
          matching: find.textContaining('尚未确认发布'),
        ),
        findsOneWidget,
      );
      expect(find.text('客户端新版本已发布'), findsOneWidget);
      expect(tester.widget<UtenButton>(_publishAction()).onPressed, isNotNull);
      final installerCreates = api.creates
          .where((body) => body['packageKind'] == 'installer')
          .length;
      api.failPublishKinds.clear();
      await _publish(tester);
      expect(
        api.creates.where((body) => body['packageKind'] == 'installer'),
        hasLength(installerCreates),
      );
      expect(api.packages, hasLength(2));
      expect(api.published, hasLength(2));
      expect(api.creates[1]['requestId'], api.creates[2]['requestId']);
      expect(find.text('客户端新版本已发布'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost receipts retain independent Setup and ZIP request identities',
    (tester) async {
      final api = _Api()
        ..losePublishResponseKinds.addAll(['installer', 'update']);
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await _publish(tester);
      await _publish(tester);
      expect(api.creates, hasLength(4));
      expect(api.creates[0]['requestId'], api.creates[2]['requestId']);
      expect(api.creates[1]['requestId'], api.creates[3]['requestId']);
      expect(api.creates[0]['requestId'], isNot(api.creates[1]['requestId']));
      expect(api.packages, hasLength(2));
      expect(api.publishCalls, 4);
      expect(api.published, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows retries the same published release after pair retention fails without reuploading',
    (tester) async {
      final api = _Api()..failRetentionOnceKinds.add('update');
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await _publish(tester);
      final updateId = api.creates.last['requestId'];
      expect(api.published, hasLength(2));
      expect(api.publishCalls, 2);
      expect(
        find.descendant(
          of: _result('update'),
          matching: find.textContaining('尚未确认发布'),
        ),
        findsOneWidget,
      );

      await _publish(tester);

      expect(api.creates, hasLength(3));
      expect(api.creates[1], api.creates[2]);
      expect(
        api.creates.map((body) => body['requestId']).toSet(),
        hasLength(2),
      );
      expect(api.publishIds, [
        api.creates.first['requestId'],
        updateId,
        updateId,
      ]);
      expect(api.packages, hasLength(2));
      expect(api.uploadedBytes, hasLength(2));
      expect(find.text('客户端新版本已发布'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'copying metadata or changing only equivalent text preserves an unknown receipt UUID',
    (tester) async {
      final api = _Api()..loseFirstPublishResponse = true;
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _publish(tester);
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      fields[0].controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 6,
      );
      fields[2].controller!.selection = const TextSelection.collapsed(
        offset: 1,
      );
      await tester.enterText(find.byType(TextField).at(0), '2.5.28 ');
      await tester.enterText(find.byType(TextField).at(1), '02528');
      await tester.pump();
      await _publish(tester);
      expect(api.creates, hasLength(2));
      expect(api.creates[0]['requestId'], api.creates[1]['requestId']);
      expect(api.packages, hasLength(1));
      expect(api.publishCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'semantic shared metadata changes start fresh identities for both selected files',
    (tester) async {
      final api = _Api()..failCreateKinds.addAll(['installer', 'update']);
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await _publish(tester);
      await tester.enterText(find.byType(TextField).at(2), '新的共同更新说明');
      await _publish(tester);
      expect(api.creates, hasLength(4));
      expect(api.creates[0]['requestId'], isNot(api.creates[2]['requestId']));
      expect(api.creates[1]['requestId'], isNot(api.creates[3]['requestId']));
      expect(api.creates[2]['releaseNotes'], '新的共同更新说明');
      expect(api.creates[3]['releaseNotes'], '新的共同更新说明');
      expect(api.published, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing architecture clears both selected files before another publication',
    (tester) async {
      await _pump(tester, _Api(), _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      final architecture = find.byType(DropdownButtonFormField<String>).last;
      await tester.ensureVisible(architecture);
      await tester.tap(architecture);
      await tester.pumpAndSettle();
      await tester.tap(find.text('arm64').last);
      await tester.pumpAndSettle();
      expect(find.text('uten-windows-x64-setup.exe'), findsNothing);
      expect(find.text('uten-windows-x64.zip'), findsNothing);
      expect(tester.widget<UtenButton>(_publishAction()).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an active upload locks both areas and metadata and revocation fences both files',
    (tester) async {
      final api = _Api()..delayedUpload = Completer<void>();
      final session = _Session(_identity());
      await _pump(tester, api, session);
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await tester.ensureVisible(_publishAction());
      await tester.tap(_publishAction());
      await tester.pump();
      expect(api.packages, hasLength(1));
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.enabled == false),
        isTrue,
      );
      for (final kind in ['installer', 'update']) {
        expect(tester.widget<UtenButton>(_publishAction()).onPressed, isNull);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(ValueKey('client-release-choose-$kind')),
              )
              .onPressed,
          isNull,
        );
      }
      session.replace(_identity(permissions: const []));
      await tester.pump();
      session.replace(_identity());
      await tester.pump();
      api.delayedUpload!.complete();
      await tester.pumpAndSettle();
      expect(api.publishCalls, 0);
      expect(api.creates, hasLength(1));
      expect(find.text('客户端新版本已发布'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(375, 1000), const Size(844, 390)]) {
    testWidgets('dual Windows areas stay reachable at 2x text $size', (
      tester,
    ) async {
      await _pump(tester, _Api(), _Session(_identity()), size: size, scale: 2);
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      final footer = tester.getRect(_publishAction());
      for (final kind in ['installer', 'update']) {
        await tester.ensureVisible(
          find.byKey(ValueKey('client-release-choose-$kind')),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(_publishAction()), footer);
        expect(_publishAction().hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a failed first package does not prevent the other selected upload',
    (tester) async {
      final api = _Api()..failPublishKinds.add('installer');
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await _publish(tester);

      expect(api.creates, hasLength(2));
      expect(api.packages, hasLength(2));
      expect(api.published, hasLength(1));
      expect(
        find.descendant(
          of: _result('installer'),
          matching: find.textContaining('尚未确认发布'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _result('update'),
          matching: find.text('客户端新版本已发布'),
        ),
        findsOneWidget,
      );
      final updateId = api.creates[1]['requestId'];
      api.failPublishKinds.clear();
      await _publish(tester);
      expect(api.creates, hasLength(3));
      expect(api.creates[0]['requestId'], api.creates[2]['requestId']);
      expect(api.publishIds.where((id) => id == updateId), hasLength(1));
      expect(api.packages, hasLength(2));
      expect(api.published, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a batch holds one busy operation across repeated activation', (
    tester,
  ) async {
    final api = _Api()..delayedUpload = Completer<void>();
    await _pump(tester, api, _Session(_identity()));
    await _fillWindows(tester, installer: true);
    await _chooseWindows(tester);
    final captures = api.scopeCaptures;
    await tester.tap(_publishAction());
    await tester.tap(_publishAction());
    await tester.pump();

    expect(api.creates, hasLength(1));
    expect(api.packages, hasLength(1));
    expect(api.scopeCaptures - captures, 1);
    expect(tester.widget<UtenButton>(_publishAction()).onPressed, isNull);
    api.delayedUpload!.complete();
    await tester.pumpAndSettle();
    expect(api.creates, hasLength(2));
    expect(api.publishCalls, 2);
    expect(api.scopeCaptures - captures, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed file cannot overwrite the next file progress', (
    tester,
  ) async {
    final api = _Api()
      ..delayedUpload = Completer<void>()
      ..delayedUploadKind = 'update';
    await _pump(tester, api, _Session(_identity()));
    await _fillWindows(tester, installer: true);
    await _chooseWindows(tester);
    await tester.tap(_publishAction());
    await tester.pump();
    expect(api.packages, hasLength(2));
    expect(api.published, hasLength(1));
    api.uploadProgress[1](1, 2);
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    api.uploadProgress[0](1, 10);
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    api.delayedUpload!.complete();
    await tester.pumpAndSettle();
    expect(api.published, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final boundary in ['publisher', 'actor', 'permission', 'server']) {
    testWidgets(
      'changing $boundary between packages stops the remaining batch',
      (tester) async {
        final api = _Api();
        final replacement = _Api();
        final session = _Session(_identity());
        await _pump(tester, api, session);
        await _fillWindows(tester, installer: true);
        await _chooseWindows(tester);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ClientReleasePublishDialog)),
        );
        api.afterPublish = (kind) async {
          if (kind != 'installer') return;
          switch (boundary) {
            case 'publisher':
              session.replace(_identity(id: 'publisher-b'));
            case 'actor':
              session.replace(_identity(impersonating: true));
            case 'permission':
              session.replace(_identity(permissions: const []));
            case 'server':
              container.read(_apiSource.notifier).state = replacement;
          }
        };
        await _publish(tester);
        expect(api.creates, hasLength(1));
        expect(api.packages, hasLength(1));
        expect(api.publishCalls, 1);
        expect(replacement.creates, isEmpty);
        expect(find.text('客户端新版本已发布'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'metadata mutation cannot change an in-flight batch or send its second package',
    (tester) async {
      final api = _Api()..delayedUpload = Completer<void>();
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester, installer: true);
      await _chooseWindows(tester);
      await tester.tap(_publishAction());
      await tester.pump();
      expect(api.creates, hasLength(1));
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text =
          'changed while pending';
      api.delayedUpload!.complete();
      await tester.pumpAndSettle();
      expect(api.creates.single['releaseNotes'], 'Windows 更新验证');
      expect(api.creates, hasLength(1));
      expect(api.publishCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android keeps its single APK publication flow', (tester) async {
    final api = _Api();
    await _pump(tester, api, _Session(_identity()));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('android').last);
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '2.5.28');
    await tester.enterText(fields.at(1), '2528');
    await tester.enterText(fields.at(2), 'Android 更新验证');
    FilePicker.platform = _WindowsPackagePicker(
      Uint8List.fromList([1, 2, 3, 4]),
      android: true,
    );
    await tester.ensureVisible(find.text('选择更新包'));
    await tester.tap(find.text('选择更新包'));
    await tester.pumpAndSettle();
    expect(find.text('Windows 安装程序（Setup.exe）'), findsNothing);
    expect(find.text('上传并发布'), findsOneWidget);
    await _publish(tester);
    expect(api.creates.single['platform'], 'android');
    expect(api.creates.single['fileName'], 'uten-android-universal.apk');
    expect(api.packages, hasLength(1));
    expect(api.publishCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('software download publication uses a complete installer kind', (
    tester,
  ) async {
    final api = _Api();
    await _pump(
      tester,
      api,
      _Session(_identity()),
      child: const ClientReleasePublishDialog(packageKind: 'installer'),
    );
    await _fillWindows(tester, installer: true);
    await _publish(tester);
    expect(api.creates.single['packageKind'], 'installer');
    expect(api.creates.single['platform'], 'windows');
    expect(api.packages, hasLength(1));
    expect(api.publishCalls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Windows upload hashes the selected bytes and publishes once', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, _Session(_identity()));
    final bytes = await _fillWindows(tester);
    await _publish(tester);
    expect(api.creates.single['platform'], 'windows');
    expect(api.creates.single['architecture'], 'x64');
    expect(
      api.creates.single['expectedSha256'],
      sha256.convert(bytes).toString(),
    );
    expect(api.uploadedBytes.single, bytes);
    expect(api.packages, hasLength(1));
    expect(api.publishCalls, 1);
    expect(find.text('客户端新版本已发布'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows lost publication receipt retries idempotent publish without reuploading',
    (tester) async {
      final api = _Api()..loseFirstPublishResponse = true;
      await _pump(tester, api, _Session(_identity()));
      await _fillWindows(tester);
      await _publish(tester);
      await _publish(tester);
      expect(api.creates, hasLength(2));
      expect(api.creates[0]['requestId'], api.creates[1]['requestId']);
      expect(api.packages, hasLength(1));
      expect(api.publishCalls, 2);
      expect(find.text('客户端新版本已发布'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'revoking permission during Windows upload prevents publication',
    (tester) async {
      final api = _Api()..delayedUpload = Completer<void>();
      final session = _Session(_identity());
      await _pump(tester, api, session);
      await _fillWindows(tester);
      await tester.ensureVisible(_publishAction());
      await tester.tap(_publishAction());
      await tester.pump();
      expect(api.packages, hasLength(1));
      session.replace(_identity(permissions: const []));
      await tester.pump();
      session.replace(_identity());
      await tester.pump();
      api.delayedUpload!.complete();
      await tester.pumpAndSettle();
      expect(api.publishCalls, 0);
      expect(find.text('客户端新版本已发布'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'withdrawal preparation handles permission loss without an uncaught future',
    (tester) async {
      const id = '69fdcabe-0ae7-47cd-8d49-8136b21a4321';
      final api = _Api()
        ..creates.add({
          'requestId': id,
          'platform': 'ios',
          'architecture': 'universal',
          'version': '2.5.28',
          'buildNumber': 2528,
          'storeUrl': 'https://apps.apple.com/cn/app/id123456789',
        })
        ..published.add(id);
      final session = _Session(_identity());
      await _pump(tester, api, session);
      api.delayedScope = Completer<void>();
      await tester.ensureVisible(find.text('撤回发布'));
      await tester.tap(find.text('撤回发布'));
      await tester.pump();
      session.replace(_identity(permissions: const []));
      await tester.pump();
      api.delayedScope!.complete();
      await tester.pumpAndSettle();
      expect(api.withdrawCalls, 0);
      expect(find.text('撤回后，其他设备将不再收到此版本。已经更新的设备不会降级。确定撤回吗？'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'iOS store release publishes without selecting or uploading a file',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, _Session(_identity()));
      await _fillStore(tester);
      expect(find.text('选择更新包'), findsNothing);
      await _publish(tester);
      expect(api.creates, hasLength(1));
      expect(api.creates.single, containsPair('platform', 'ios'));
      expect(
        api.creates.single,
        containsPair('storeUrl', 'https://apps.apple.com/cn/app/id123456789'),
      );
      expect(api.creates.single.containsKey('fileName'), isFalse);
      expect(api.creates.single.containsKey('expectedSha256'), isFalse);
      expect(api.packages, isEmpty);
      expect(api.publishCalls, 1);
      expect(find.text('客户端新版本已发布'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost publication receipt recovers the same request without publishing twice',
    (tester) async {
      final api = _Api()..loseFirstPublishResponse = true;
      await _pump(tester, api, _Session(_identity()));
      await _fillStore(tester);
      await _publish(tester);
      expect(api.publishCalls, 1);
      expect(find.text('客户端新版本已发布'), findsNothing);
      await _publish(tester);
      expect(api.creates, hasLength(2));
      expect(api.creates[1]['requestId'], api.creates[0]['requestId']);
      expect(api.publishCalls, 1);
      expect(api.packages, isEmpty);
      expect(find.text('客户端新版本已发布'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changed publisher cannot finish a prior account draft', (
    tester,
  ) async {
    final api = _Api()..delayedCreate = Completer();
    final session = _Session(_identity());
    await _pump(tester, api, session);
    await _fillStore(tester);
    await tester.ensureVisible(find.text('上传并发布'));
    await tester.tap(find.text('上传并发布'));
    await tester.pump();
    expect(api.creates, hasLength(1));
    session.replace(_identity(id: 'publisher-b'));
    api.delayedCreate!.complete(api._release(api.creates.single));
    await tester.pumpAndSettle();
    expect(api.publishCalls, 0);
    expect(api.packages, isEmpty);
    expect(find.text('客户端新版本已发布'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (label, identity) in [
    ('ordinary employee', _identity(permissions: const [])),
    (
      'employee with unrelated management permission',
      _identity(permissions: const [Perm.authorizationManage]),
    ),
    (
      'admin with only the old management permission',
      _identity(admin: true, permissions: const [Perm.authorizationManage]),
    ),
    (
      'admin without publishing permission',
      _identity(admin: true, permissions: const []),
    ),
    ('impersonated publisher', _identity(impersonating: true)),
    (
      'publisher who must change password',
      _identity(status: AuthStatus.mustChangePassword),
    ),
    ('signed out publisher', _identity(status: AuthStatus.unauthenticated)),
  ]) {
    testWidgets('publishing entry is hidden for $label', (tester) async {
      final api = _Api();
      await _pump(
        tester,
        api,
        _Session(identity),
        child: const ClientReleasePublishTile(),
      );
      expect(find.text('发布客户端版本'), findsNothing);
      expect(api.creates, isEmpty);
      expect(api.publishCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'authorized employee can open publishing without admin privileges',
    (tester) async {
      final api = _Api();
      await _pump(
        tester,
        api,
        _Session(_identity()),
        child: const ClientReleasePublishTile(),
      );
      expect(find.text('发布客户端版本'), findsOneWidget);
      await tester.tap(find.text('发布客户端版本'));
      await tester.pumpAndSettle();
      expect(find.text('选择更新包'), findsOneWidget);
      expect(api.listCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening a publishing dialog directly cannot bypass permission', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, _Session(_identity(permissions: const [])));
    expect(find.text('发布客户端版本'), findsNothing);
    expect(find.text('选择更新包'), findsNothing);
    expect(api.listCalls, 0);
    expect(api.creates, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permission revocation closes the dialog and fences its pending draft',
    (tester) async {
      final api = _Api()..delayedCreate = Completer();
      final session = _Session(_identity());
      await _pump(
        tester,
        api,
        session,
        child: const ClientReleasePublishTile(),
      );
      await tester.tap(find.text('发布客户端版本'));
      await tester.pumpAndSettle();
      await _fillStore(tester);
      await tester.ensureVisible(find.text('上传并发布'));
      await tester.tap(find.text('上传并发布'));
      await tester.pump();
      expect(api.creates, hasLength(1));
      session.replace(_identity(permissions: const []));
      await tester.pumpAndSettle();
      expect(find.text('发布客户端版本'), findsNothing);
      expect(find.text('上传并发布'), findsNothing);
      session.replace(_identity());
      await tester.pump();
      api.delayedCreate!.complete(api._release(api.creates.single));
      await tester.pumpAndSettle();
      expect(api.publishCalls, 0);
      expect(api.packages, isEmpty);
      expect(find.text('客户端新版本已发布'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
