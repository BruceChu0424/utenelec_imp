import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/security/tab_scoped_store.dart';
import '../models/business_data_reset_attempt.dart';

/// Stores no credential and never sends a request. Scope is the trusted backend
/// plus the original user UUID. Web storage follows the existing per-tab session
/// policy, and uses a separate key that auth token clearing does not remove.
class BusinessDataResetJournal {
  const BusinessDataResetJournal(this._store);

  final TabScopedStore _store;

  String _key(String server, String operatorId) =>
      'uten.business-reset.pending.v1.${Uri.encodeComponent(server)}.$operatorId';

  Future<BusinessDataResetAttempt?> read(
    String server,
    String operatorId,
  ) async {
    final raw = await _store.read(_key(server, operatorId));
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('清空请求的本地待确认记录无效');
    }
    final attempt = BusinessDataResetAttempt.fromJson(json);
    if (attempt.server != server || attempt.operatorId != operatorId) {
      throw const FormatException('清空请求的目标或操作者不一致');
    }
    return attempt;
  }

  Future<void> save(BusinessDataResetAttempt attempt) => _store.write(
    _key(attempt.server, attempt.operatorId),
    jsonEncode(attempt.toJson()),
  );

  Future<void> removeIfSame(BusinessDataResetAttempt attempt) async {
    final current = await read(attempt.server, attempt.operatorId);
    if (current?.id == attempt.id) {
      await _store.delete(_key(attempt.server, attempt.operatorId));
    }
  }
}

final businessDataResetJournalProvider = Provider<BusinessDataResetJournal>(
  (ref) => BusinessDataResetJournal(
    defaultSessionScopeStore(const FlutterSecureStorage()),
  ),
);
