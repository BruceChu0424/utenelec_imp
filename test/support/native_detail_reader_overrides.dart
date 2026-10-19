import 'package:flutter_riverpod/misc.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import '../helpers/badge_summary_fixture.dart';

/// Native detail fixtures represent a logged-in reader, not an anonymous page
/// with forged permission constants. Explicit user/capability overrides win.
List<Override> nativeDetailReaderOverrides({
  bool includeSession = true,
  bool includeServer = true,
  bool includeSnapshot = true,
  bool includeBadge = true,
}) => [
  if (includeSession) sessionProvider.overrideWith(_NativeReaderSession.new),
  if (includeServer)
    apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
  if (includeSnapshot)
    sessionSnapshotProvider.overrideWith(_NativeReaderSnapshot.new),
  // Successful business writes still invoke refreshBadges. The page fixtures
  // check their writes/return behavior without starting an app-wide poll timer.
  if (includeBadge) fixedBadgeSummaryOverride(),
];

class _NativeReaderSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'native-detail-reader', code: 'reader', name: '测试读者'),
  );
}

class _NativeReaderSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(
    documentScopes: {
      for (final scope in DocumentDataScope.values)
        scope: DocumentScopeCapability(
          scope: scope.apiValue,
          writeAll: true,
          writableOwnerIds: const {},
        ),
    },
  );
}
