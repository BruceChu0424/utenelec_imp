import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/company_file.dart';

class CompanyFileRepository {
  const CompanyFileRepository(this.api);
  final ApiClient api;
  static const base = '/company-files';

  Future<CompanyFileListing> list({
    String? parentId,
    String search = '',
    String sort = 'name',
    String direction = 'asc',
    bool trash = false,
    int page = 0,
    int size = 100,
  }) async => CompanyFileListing.fromJson(
    await api.get(
      base,
      query: {
        'parentId': ?parentId,
        if (search.isNotEmpty) 'search': search,
        'sort': sort,
        'direction': direction,
        'trash': trash,
        'page': page,
        'size': size,
      },
    ),
  );

  Future<CompanyFile> get(String id) async =>
      CompanyFile.fromJson(await api.get('$base/$id'));

  Future<CompanyFile> createFolder({
    String? parentId,
    required String name,
    String? description,
  }) async => CompanyFile.fromJson(
    await api.post(
      '$base/folders',
      body: {'parentId': parentId, 'name': name, 'description': description},
    ),
  );

  Future<CompanyFile> reserveFile({
    String? parentId,
    required String name,
    required String requestId,
  }) async => CompanyFile.fromJson(
    await api.post(
      '$base/files',
      body: {'parentId': parentId, 'name': name, 'requestId': requestId},
    ),
  );

  Future<CompanyFile> complete(CompanyFile file, String attachmentId) async =>
      CompanyFile.fromJson(
        await api.post(
          '$base/${file.id}/complete',
          body: {'version': file.version, 'attachmentId': attachmentId},
        ),
      );

  Future<CompanyFile> rename(
    CompanyFile file, {
    required String name,
    required String description,
  }) async => CompanyFile.fromJson(
    await api.patch(
      '$base/${file.id}',
      body: {'version': file.version, 'name': name, 'description': description},
    ),
  );

  Future<void> move(CompanyFile file, String? parentId) async {
    await api.post(
      '$base/${file.id}/move',
      body: {'version': file.version, 'parentId': parentId},
    );
  }

  Future<void> reorder(String? parentId, List<CompanyFile> ordered) async {
    await api.post(
      '$base/reorder',
      body: {
        'parentId': parentId,
        'orderedIds': ordered.map((e) => e.id).toList(),
        'versions': {for (final e in ordered) e.id: e.version},
      },
    );
  }

  Future<void> delete(CompanyFile file) =>
      api.delete('$base/${file.id}', query: {'version': file.version});

  Future<void> restore(CompanyFile file) async {
    await api.post('$base/${file.id}/restore', body: {'version': file.version});
  }

  Future<CompanyFileAccess> access(String id) async =>
      CompanyFileAccess.fromJson(await api.get('$base/$id/permissions'));

  Future<void> saveAccess(
    String id, {
    required int version,
    required bool inheritPermissions,
    required List<CompanyFileAccessRule> rules,
  }) async {
    await api.put(
      '$base/$id/permissions',
      body: {
        'version': version,
        'inheritPermissions': inheritPermissions,
        'rules': rules.map((r) => r.toJson()).toList(),
      },
    );
  }

  Future<void> setPassword(CompanyFile file, String? password) async {
    await api.put(
      '$base/${file.id}/password',
      body: {'version': file.version, 'password': password},
    );
  }

  Future<void> unlock(String id, String password) async {
    await api.post('$base/$id/unlock', body: {'password': password});
  }

  Future<void> lock(String id) async {
    await api.post('$base/$id/lock');
  }

  Future<List<CompanyFilePrincipal>> principals({
    required String type,
    String search = '',
  }) async => (await api.getList(
    '$base/principals',
    query: {'type': type, 'search': search},
  )).map(CompanyFilePrincipal.fromJson).toList(growable: false);
}

final companyFileRepositoryProvider = Provider<CompanyFileRepository>(
  (ref) => CompanyFileRepository(ref.watch(apiClientProvider)),
);
