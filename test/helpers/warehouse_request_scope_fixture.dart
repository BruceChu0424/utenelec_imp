import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../shared/drafts/memory_form_draft_storage.dart';
import 'badge_summary_fixture.dart';

final _fixtureClient = ApiClient(Dio());

class IdleWarehouseTestSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class IdleWarehouseTestSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

/// Repository fakes still run the real draft and request-scope guards. Supply a
/// settled local session instead of starting production credential restoration.
List<Override> warehouseRequestScopeFixture({
  ApiClient? api,
  bool includeClient = true,
  bool includeIdentity = true,
  bool includeBadges = true,
}) => [
  sessionProvider.overrideWith(IdleWarehouseTestSession.new),
  sessionSnapshotProvider.overrideWith(IdleWarehouseTestSnapshot.new),
  if (includeClient) apiClientProvider.overrideWithValue(api ?? _fixtureClient),
  if (includeIdentity)
    authenticatedScopeProvider.overrideWithValue(
      const AuthenticatedScope(userId: 'warehouse-user'),
    ),
  formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
  if (includeBadges) fixedBadgeSummaryOverride(),
];
