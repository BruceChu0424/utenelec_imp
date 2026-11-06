import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../shared/drafts/memory_form_draft_storage.dart';

const financeCommandTestActor = '00000000-0000-0000-0000-000000000101';
late SharedPreferences _preferences;
Future<void> prepareFinanceCommandTest() async {
  SharedPreferences.setMockInitialValues({});
  _preferences = await SharedPreferences.getInstance();
}

class _CommandSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

List<Override> financeCommandTestOverrides({
  bool permissions = true,
  bool identity = true,
  FormDraftStorage? storage,
}) => [
  apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
  sessionProvider.overrideWith(_CommandSession.new),
  if (identity)
    authenticatedScopeProvider.overrideWithValue(
      const AuthenticatedScope(userId: financeCommandTestActor),
    ),
  sharedPreferencesProvider.overrideWithValue(_preferences),
  formDraftStorageProvider.overrideWithValue(
    storage ?? MemoryFormDraftStorage(),
  ),
  if (permissions)
    currentPermissionsProvider.overrideWithValue({
      Perm.financeReportView,
      Perm.paymentStyleEdit,
      Perm.financeViewAll,
      Perm.arApLedgerView,
      Perm.financePostExecute,
      Perm.supplierSettlementConfirm,
      Perm.goodsCostView,
    }),
];
Map<String, dynamic> financeCommandTestReceipt({
  required String operation,
  required String method,
  required String path,
  required Object? body,
  Object? result,
  String identityField = 'requestId',
  String actorId = financeCommandTestActor,
  String outcome = 'SUCCEEDED',
}) => {
  'found': true,
  'outcome': outcome,
  'requestId': (body as Map)[identityField],
  'actorId': actorId,
  'operation': operation,
  'method': method,
  'path': path,
  'requestBody': Map<String, dynamic>.from(body),
  'result': result,
};

/// Exercises the same Uten menu as the financial original-request launcher.
Future<void> tapFinanceOriginalAction(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.tap(find.text('原请求操作'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label));
}
