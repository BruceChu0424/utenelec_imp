import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/permission_configuration.dart';

abstract interface class PermissionConfigurationRepository {
  Future<PermissionConfiguration> export();
  Future<PermissionTransferPreview> previewImport(Map<String, dynamic> request);
  Future<void> importConfiguration(
    Map<String, dynamic> request,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  );
  Future<PermissionCopySnapshot> copy(String userId);
  Future<PermissionTransferPreview> previewCopy(
    String targetId,
    PermissionCopySnapshot source,
  );
  Future<void> applyCopy(
    String targetId,
    PermissionCopySnapshot source,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  );
}

class DioPermissionConfigurationRepository
    implements PermissionConfigurationRepository {
  DioPermissionConfigurationRepository(this.api);
  final ApiClient api;
  static const _configuration = '/admin/permission-configuration';

  @override
  Future<PermissionConfiguration> export() async =>
      PermissionConfiguration.fromJson(await api.get('$_configuration/export'));

  @override
  Future<PermissionTransferPreview> previewImport(
    Map<String, dynamic> request,
  ) async => PermissionTransferPreview.fromJson(
    await api.post('$_configuration/import/preview', body: request),
  );

  @override
  Future<void> importConfiguration(
    Map<String, dynamic> request,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  ) async {
    await api.post(
      '$_configuration/import',
      body: {
        'request': request,
        'expectedFingerprint': preview.fingerprint,
        'sensitiveConfirmations': confirmations.toList()..sort(),
      },
    );
  }

  @override
  Future<PermissionCopySnapshot> copy(String userId) async =>
      PermissionCopySnapshot.fromJson(
        await api.get('/admin/users/$userId/permission-copy'),
      );

  @override
  Future<PermissionTransferPreview> previewCopy(
    String targetId,
    PermissionCopySnapshot source,
  ) async => PermissionTransferPreview.fromJson(
    await api.post(
      '/admin/users/$targetId/permission-copy/preview',
      body: source.toRequest(),
    ),
  );

  @override
  Future<void> applyCopy(
    String targetId,
    PermissionCopySnapshot source,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  ) async {
    await api.post(
      '/admin/users/$targetId/permission-copy',
      body: {
        'request': source.toRequest(),
        'expectedFingerprint': preview.fingerprint,
        'sensitiveConfirmations': confirmations.toList()..sort(),
      },
    );
  }
}

final permissionConfigurationRepositoryProvider =
    Provider<PermissionConfigurationRepository>(
      (ref) =>
          DioPermissionConfigurationRepository(ref.watch(apiClientProvider)),
    );

/// In-app clipboard: never persisted or shared across accounts/servers.
final permissionCopyClipboardProvider = StateProvider<PermissionCopySnapshot?>((
  ref,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  return null;
});

/// Refreshes local data-scope panels after an import or an uncertain command.
final permissionConfigurationRevisionProvider = StateProvider<int>((ref) {
  ref.watch(sensitiveReadBoundaryProvider);
  return 0;
});
