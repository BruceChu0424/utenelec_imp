import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/widgets/finance_document_unapproval_action.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/native_detail_reader_overrides.dart';

class _Reader extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'A', name: '财务A'),
  );
  void switchIdentity() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'b', code: 'B', name: '财务B'),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int posts = 0;
  String? postedPath;
  Object? postedBody;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'supported': true,
    'permitted': true,
    'eligible': true,
    'nextAction': 'UNAPPROVE_TO_DRAFT',
    'factsSnapshot': 'a' * 64,
    'reasons': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts++;
    postedPath = path;
    postedBody = body;
    return {'id': 'successor', 'unapprovalOriginalId': 'original', 'status': 0};
  }
}

void main() {
  testWidgets(
    'finance history confirmation uses the shared snapshot-bound successor transaction',
    (tester) async {
      final api = _Api();
      var completed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(includeSession: false),
            sessionProvider.overrideWith(_Reader.new),
            apiClientProvider.overrideWithValue(api),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FinanceDocumentUnapprovalAction(
                family: 'salesOrder',
                documentId: 'original',
                revision: 'r1',
                onCompleted: () => completed++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 0);
      await tester.tap(find.widgetWithText(TextButton, '确认反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 1);
      expect(api.postedPath, '/documents/salesOrder/original/unapprove');
      expect((api.postedBody as Map)['expectedSnapshot'], 'a' * 64);
      expect(completed, 1);
    },
  );
  testWidgets(
    'finance history reversal cannot submit after identity changes in its confirmation',
    (tester) async {
      final api = _Api();
      var completed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(includeSession: false),
            sessionProvider.overrideWith(_Reader.new),
            apiClientProvider.overrideWithValue(api),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FinanceDocumentUnapprovalAction(
                family: 'purchaseOrder',
                documentId: 'original',
                revision: 'r1',
                onCompleted: () => completed++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocumentUnapprovalAction)),
      );
      (container.read(sessionProvider.notifier) as _Reader).switchIdentity();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '确认反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 0);
      expect(completed, 0);
    },
  );
}
