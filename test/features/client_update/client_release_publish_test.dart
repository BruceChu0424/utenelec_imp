import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/client_update/client_release_publish_dialog.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

SessionState _identity({
  String id = 'publisher-a',
  bool admin = true,
  List<String> permissions = const [Perm.authorizationManage],
  bool impersonating = false,
}) => SessionState(
  status: AuthStatus.authenticated,
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
  int publishCalls = 0;
  bool loseFirstPublishResponse = false;
  Completer<Map<String, dynamic>>? delayedCreate;

  Map<String, dynamic> _release(Map<String, dynamic> body) => {
    ...body,
    'id': body['requestId'],
    'installMode': 'store',
    'state': published.contains(body['requestId']) ? 'PUBLISHED' : 'DRAFT',
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/admin/client-releases');
    return creates
        .where((body) => published.contains(body['requestId']))
        .map(_release)
        .toList();
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
      return delayedCreate?.future ?? _release(draft);
    }
    expect(path, matches(r'^/admin/client-releases/[0-9a-f-]{36}/publish$'));
    publishCalls++;
    published.add(path.split('/')[3]);
    if (loseFirstPublishResponse && publishCalls == 1) {
      // The command committed, but the client did not receive its receipt.
      throw ApiException('NETWORK_ERROR', 'fixture response lost');
    }
    return _release(creates.last);
  }

  @override
  Future<void> uploadClientPackage(
    String path,
    Uint8List bytes, {
    required void Function(int, int) onProgress,
  }) async {
    packages.add(path);
    throw StateError(
      'Store publishing must never upload an installation package',
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Api api,
  _Session session, {
  Widget child = const ClientReleasePublishDialog(),
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(() => session),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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

Future<void> _publish(WidgetTester tester) async {
  await tester.ensureVisible(find.text('上传并发布'));
  await tester.tap(find.text('上传并发布'));
  await tester.pumpAndSettle();
}

void main() {
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
    ('ordinary employee', _identity(admin: false, permissions: const [])),
    ('non-admin with management permission', _identity(admin: false)),
    ('admin without management permission', _identity(permissions: const [])),
    ('impersonated admin', _identity(impersonating: true)),
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
}
