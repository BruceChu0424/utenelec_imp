import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Files extends AttachmentService {
  _Files() : super(ApiClient(Dio()));
  final calls = <BusinessAttachmentOwner>[];
  final pending = <Completer<List<Attachment>>>[];
  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) {
    calls.add((type: ownerType, id: ownerId));
    final result = Completer<List<Attachment>>();
    pending.add(result);
    return result.future;
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => _state('viewer-a');
  void change(String id) => state = _state(id);
  static SessionState _state(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: id, code: id, name: id, roles: const []),
  );
}

Attachment _file(String name) => Attachment(
  id: name,
  ownerType: 'SALES_ORDER',
  ownerId: 'order-a',
  storageKey: 'private/$name',
  originalName: name,
  sizeBytes: 1,
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    _Files files,
    _Session session, {
    String id = 'order-a',
    bool canView = true,
    bool canManage = true,
    Set<String> permissions = const {
      Perm.attachmentView,
      Perm.attachmentUpload,
      Perm.attachmentDelete,
    },
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          attachmentServiceProvider.overrideWithValue(files),
          currentPermissionsProvider.overrideWithValue(permissions),
          sessionProvider.overrideWith(() => session),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BusinessAttachmentSection(
              ownerType: 'SALES_ORDER',
              ownerId: id,
              canView: canView,
              canManage: canManage,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'masked or unauthorized documents never request or expose filenames',
    (tester) async {
      final files = _Files();
      final session = _Session();
      await pump(tester, files, session, canView: false);
      expect(files.calls, isEmpty);
      await pump(tester, files, session, permissions: {Perm.attachmentUpload});
      expect(files.calls, isEmpty);
      expect(find.byType(AttachmentSection), findsNothing);
    },
  );

  testWidgets(
    'approved read-only document lists files without upload or delete',
    (tester) async {
      final files = _Files();
      final session = _Session();
      await pump(tester, files, session, canManage: false);
      expect(files.calls, [(type: 'SALES_ORDER', id: 'order-a')]);
      files.pending.single.complete([_file('客户确认.pdf')]);
      await tester.pumpAndSettle();
      expect(find.text('客户确认.pdf'), findsOneWidget);
      expect(find.text('上传'), findsNothing);
      final section = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(section.ownerCanDelete, isFalse);
    },
  );

  testWidgets(
    'changing documents ignores the previous request that finishes late',
    (tester) async {
      final files = _Files();
      final session = _Session();
      await pump(tester, files, session);
      await pump(tester, files, session, id: 'order-b');
      files.pending[0].complete([_file('另一订单.pdf')]);
      files.pending[1].complete([_file('本单.pdf')]);
      await tester.pumpAndSettle();
      expect(find.text('另一订单.pdf'), findsNothing);
      expect(find.text('本单.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'switching viewers clears old filenames and rechecks object access',
    (tester) async {
      final files = _Files();
      final session = _Session();
      await pump(tester, files, session);
      files.pending[0].complete([_file('内部合同.pdf')]);
      await tester.pumpAndSettle();
      session.change('viewer-b');
      await tester.pump();
      await tester.pump();
      expect(find.text('内部合同.pdf'), findsNothing);
      expect(files.calls, hasLength(2));
      files.pending[1].completeError(
        StateError('private server detail must not appear'),
      );
      await tester.pumpAndSettle();
      expect(find.text('内部合同.pdf'), findsNothing);
      expect(find.textContaining('private server detail'), findsNothing);
      await tester.tap(find.text('重新读取'));
      await tester.pump();
      files.pending[2].complete([]);
      await tester.pumpAndSettle();
      expect(find.text('上传'), findsOneWidget);
    },
  );

  testWidgets('completed upload/delete refreshes only this document list', (
    tester,
  ) async {
    final files = _Files();
    final session = _Session();
    await pump(tester, files, session);
    files.pending[0].complete([_file('旧文件.pdf')]);
    await tester.pumpAndSettle();
    tester
        .widget<AttachmentSection>(find.byType(AttachmentSection))
        .onChanged();
    await tester.pump();
    await tester.pump();
    expect(find.text('旧文件.pdf'), findsNothing);
    files.pending[1].complete([_file('新文件.pdf')]);
    await tester.pumpAndSettle();
    expect(find.text('新文件.pdf'), findsOneWidget);
    expect(files.calls, hasLength(2));
  });
}
