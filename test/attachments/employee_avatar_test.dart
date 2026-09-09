import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:uten_imp/components/data_display/uten_user_avatar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/employee_avatar.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  Uint8List picture(int red) => Uint8List.fromList(
    img.encodePng(
      img.Image(width: 2, height: 2)..setPixelRgba(0, 0, red, 70, 30, 255),
    ),
  );
  SessionState session(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: id, code: id, name: id, roles: const []),
  );

  Future<ProviderContainer> pumpAvatar(
    WidgetTester tester,
    _AvatarService service,
    _AvatarSession notifier, {
    String revision = 'selected-v1',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          attachmentServiceProvider.overrideWithValue(service),
          sessionProvider.overrideWith(() => notifier),
        ],
        child: MaterialApp(
          home: EmployeeAvatar(
            employeeId: 'employee-id',
            revision: revision,
            name: '员工',
            size: 56,
          ),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(EmployeeAvatar)),
    );
  }

  testWidgets(
    'avatar revision refreshes original bytes without showing the old image while loading',
    (tester) async {
      final service = _AvatarService();
      final notifier = _AvatarSession(session('viewer-a'));
      await pumpAvatar(tester, service, notifier);
      expect(service.employeeIds, ['employee-id']);
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        isNull,
      );
      final original = picture(40);
      service.pending[0].complete(original);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        same(original),
      );

      await pumpAvatar(tester, service, notifier, revision: 'selected-v2');
      expect(service.employeeIds, ['employee-id', 'employee-id']);
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        isNull,
      );
      final updated = picture(180);
      service.pending[1].complete(updated);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        same(updated),
      );
    },
  );

  testWidgets(
    'switching accounts discards cached and late avatar data; denied and logged-out sessions stay blank',
    (tester) async {
      final service = _AvatarService();
      final notifier = _AvatarSession(session('viewer-a'));
      await pumpAvatar(tester, service, notifier);
      final oldPicture = picture(40);
      service.pending[0].complete(oldPicture);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        same(oldPicture),
      );

      notifier.replace(session('viewer-b'));
      await tester.pump();
      expect(service.pending, hasLength(2));
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        isNull,
      );
      notifier.replace(session('viewer-c'));
      await tester.pump();
      expect(service.pending, hasLength(3));
      service.pending[1].complete(oldPicture);
      await tester.pump();
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        isNull,
      );
      service.pending[2].completeError(
        ApiException('NOT_FOUND', 'Employee not found'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenUserAvatar>(find.byType(UtenUserAvatar)).imageBytes,
        isNull,
      );
      expect(find.text('员'), findsOneWidget);
      notifier.replace(const SessionState());
      await tester.pumpAndSettle();
      expect(service.pending, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no selected avatar makes no byte request', (tester) async {
    final service = _AvatarService();
    await pumpAvatar(
      tester,
      service,
      _AvatarSession(session('viewer')),
      revision: '',
    );
    await tester.pumpAndSettle();
    expect(service.employeeIds, isEmpty);
    expect(find.text('员'), findsOneWidget);
  });
}

class _AvatarService extends AttachmentService {
  _AvatarService() : super(ApiClient(Dio()));
  final employeeIds = <String>[];
  final pending = <Completer<Uint8List>>[];

  @override
  Future<Uint8List> employeeAvatarBytes(String employeeId) {
    employeeIds.add(employeeId);
    final result = Completer<Uint8List>();
    pending.add(result);
    return result.future;
  }
}

class _AvatarSession extends SessionNotifier {
  _AvatarSession(this.initial);
  final SessionState initial;
  @override
  SessionState build() => initial;
  void replace(SessionState next) => state = next;
}
