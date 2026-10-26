import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';

class PermissionTemplateRepository {
  PermissionTemplateRepository(this.api);
  final ApiClient api;
  static const path = '/admin/permission-templates';
  Future<List<PermissionTemplate>> list() async =>
      (await api.getList(path)).map(PermissionTemplate.fromJson).toList();
  Future<PermissionTemplate> save({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    final body = {
      'name': name.trim(),
      'description': description.trim(),
      'permissions': permissions.toList()..sort(),
      'expectedVersion': template?.version ?? 0,
    };
    final saved = template == null
        ? await api.post(path, body: body)
        : await api.put('$path/${template.id}', body: body);
    return PermissionTemplate.fromJson(saved);
  }

  Future<void> delete(PermissionTemplate template) async {
    await api.post(
      '$path/${template.id}/delete',
      body: {'expectedVersion': template.version},
    );
  }

  Map<String, dynamic> request(PermissionTemplate template, bool merge) => {
    'templateId': template.id,
    'templateVersion': template.version,
    'mode': merge ? 'MERGE' : 'REPLACE',
  };
  Future<PermissionTransferPreview> preview(
    String target,
    PermissionTemplate template,
    bool merge,
  ) async => PermissionTransferPreview.fromJson(
    await api.post(
      '/admin/users/$target/permission-template/preview',
      body: request(template, merge),
    ),
  );
  Future<void> apply(
    String target,
    PermissionTemplate template,
    bool merge,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  ) async {
    await api.post(
      '/admin/users/$target/permission-template',
      body: {
        'request': request(template, merge),
        'expectedFingerprint': preview.fingerprint,
        'sensitiveConfirmations': confirmations.toList()..sort(),
      },
    );
  }
}

final permissionTemplateRepositoryProvider = Provider(
  (ref) => PermissionTemplateRepository(ref.watch(apiClientProvider)),
);
final permissionTemplatesProvider = FutureProvider<List<PermissionTemplate>>((
  ref,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  return ref.watch(permissionTemplateRepositoryProvider).list();
});
