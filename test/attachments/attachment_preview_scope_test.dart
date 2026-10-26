import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_dialog.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _api = ApiClient(Dio(BaseOptions(baseUrl: 'https://library.test/api')));

class _Session extends SessionNotifier {
  @override
  SessionState build() => _state('a');
  void change(String user) => state = _state(user);
  static SessionState _state(String user) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: user, code: user, name: user),
  );
}

class _Files extends AttachmentService {
  _Files() : super(_api);
  Completer<Uint8List>? gate;
  int downloads = 0;
  @override
  Future<Uint8List> downloadBytes(Attachment attachment) async {
    downloads++;
    return gate == null ? Uint8List.fromList([97, 98, 99]) : gate!.future;
  }

  @override
  Future<Uint8List> previewBytes(Attachment attachment) async =>
      Uint8List.fromList('%PDF-1.4 minimal'.codeUnits);
}

Future<void> _mount(
  WidgetTester tester,
  _Session session,
  _Files files, {
  bool office = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(() => session),
        apiClientProvider.overrideWithValue(_api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        attachmentServiceProvider.overrideWithValue(files),
        currentPermissionsProvider.overrideWithValue({Perm.attachmentDownload}),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AttachmentSection(
            ownerType: 'EXPENSE_CLAIM',
            ownerId: 'owner',
            attachments: [
              Attachment(
                id: 'file',
                ownerType: 'EXPENSE_CLAIM',
                ownerId: 'owner',
                storageKey: 'private',
                originalName: office ? '合同.docx' : '原件.txt',
                contentType: office ? 'application/msword' : 'text/plain',
                sizeBytes: 3,
              ),
            ],
            ownerCanUpload: false,
            ownerCanDelete: false,
            onChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a late original never opens after A B A with equal permissions',
    (tester) async {
      final session = _Session();
      final files = _Files()..gate = Completer<Uint8List>();
      await _mount(tester, session, files);
      await tester.tap(find.byTooltip('预览'));
      await tester.pump();
      expect(files.downloads, 1);
      session.change('b');
      await tester.pump();
      session.change('a');
      files.gate!.complete(Uint8List.fromList([97, 98, 99]));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('an open preview retires permanently after an identity change', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session, _Files());
    await tester.tap(find.byTooltip('预览'));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
    session.change('b');
    await tester.pump();
    session.change('a');
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentPreviewDialog), findsNothing);
    expect(find.text('附件访问权限已变化，请重新打开'), findsOneWidget);
  });

  testWidgets(
    'Office preview downloads the original under the captured scope',
    (tester) async {
      final session = _Session();
      final files = _Files()..gate = Completer<Uint8List>();
      await _mount(tester, session, files, office: true);
      await tester.tap(find.byTooltip('预览'));
      await tester.pump();
      await tester.pump();
      final preview = tester.widget<AttachmentPreviewDialog>(
        find.byType(AttachmentPreviewDialog),
      );
      expect(preview.onDownload, isNotNull);
      expect(files.downloads, 0);
      final download = Future<void>.sync(preview.onDownload!);
      await tester.pump();
      expect(files.downloads, 1);
      final rejected = expectLater(download, throwsA(isA<ApiException>()));
      session.change('b');
      files.gate!.complete(Uint8List.fromList([97, 98, 99]));
      await rejected;
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
      tester.takeException();
    },
  );
}
