import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/auth/session_snapshot_provider.dart';

class PostingStyleRole {
  const PostingStyleRole({
    required this.roleKey,
    required this.description,
    required this.requiredCategory,
    required this.updatedAt,
    required this.usable,
    this.canConfigure = false,
    this.styleId,
    this.styleName,
  });

  factory PostingStyleRole.fromJson(Map<String, dynamic> row) =>
      PostingStyleRole(
        roleKey: row['roleKey'] as String,
        description: row['description'] as String,
        requiredCategory: row['requiredCategory'] as String,
        updatedAt: row['updatedAt'] as String,
        usable: row['usable'] == true,
        canConfigure: row['canConfigure'] == true,
        styleId: row['styleId'] as String?,
        styleName: row['styleName'] as String?,
      );
  final String roleKey, description, requiredCategory, updatedAt;
  final String? styleId, styleName;
  final bool usable;
  final bool canConfigure;
}

abstract interface class PostingStyleRoleRepository {
  Future<AuthenticatedRequestScope> captureScope({
    required bool Function() isCurrent,
  });
  Future<List<PostingStyleRole>> list(AuthenticatedRequestScope scope);
  Future<PostingStyleRole> configure(
    PostingStyleRole role,
    String styleId,
    AuthenticatedRequestScope scope,
  );
}

class DioPostingStyleRoleRepository implements PostingStyleRoleRepository {
  DioPostingStyleRoleRepository(this.api);
  final ApiClient api;
  static const path = '/finance/posting-style-roles';

  @override
  Future<AuthenticatedRequestScope> captureScope({
    required bool Function() isCurrent,
  }) => api.captureRequestScope(isCurrent: isCurrent);
  @override
  Future<List<PostingStyleRole>> list(AuthenticatedRequestScope scope) =>
      scope.run(() async {
        final rows = await api.getList(path);
        await scope.verify();
        return rows.map(PostingStyleRole.fromJson).toList(growable: false);
      });
  @override
  Future<PostingStyleRole> configure(
    PostingStyleRole role,
    String styleId,
    AuthenticatedRequestScope scope,
  ) => scope.run(() async {
    final row = await api.put(
      '$path/${Uri.encodeComponent(role.roleKey)}',
      body: {'styleId': styleId, 'expectedUpdatedAt': role.updatedAt},
    );
    await scope.verify();
    return PostingStyleRole.fromJson(row);
  });
}

final postingStyleRoleRepositoryProvider = Provider<PostingStyleRoleRepository>(
  (ref) => DioPostingStyleRoleRepository(ref.watch(apiClientProvider)),
);

/// Visibility comes from a successful authorized read, tied to this reader and Me revision.
final postingStyleRoleVisibilityProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final identity = ref.watch(authenticatedScopeProvider);
  final snapshot = confirmedSessionSnapshot(ref.watch(sessionSnapshotProvider));
  if (identity == null || snapshot == null) return false;
  final repository = ref.watch(postingStyleRoleRepositoryProvider);
  var alive = true;
  ref.onDispose(() => alive = false);
  final scope = await repository.captureScope(
    isCurrent: () =>
        alive &&
        ref.read(authenticatedScopeProvider) == identity &&
        confirmedSessionSnapshot(
              ref.read(sessionSnapshotProvider),
            )?.generation ==
            snapshot.generation,
  );
  try {
    await repository.list(scope);
    await scope.verify();
    return true;
  } on ApiException catch (error) {
    if (error.code == 'FORBIDDEN' || error.code == 'NOT_FOUND') return false;
    rethrow;
  }
});
