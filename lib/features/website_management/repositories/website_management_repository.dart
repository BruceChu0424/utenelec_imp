import '../../../core/network/api_client.dart';
import '../models/website_management.dart';

abstract interface class WebsiteManagementRepository {
  Future<WebsiteManagementInfo> load();
  Future<WebsiteConnectionCheck> check();
  Future<WebsiteManagementInfo> configure({
    required int expectedVersion,
    required String displayName,
    required String publicOrigin,
    required bool enabled,
  });
  Future<WebsiteEditorGrant> open({
    required String section,
    required String codeChallenge,
  });
}

class DioWebsiteManagementRepository implements WebsiteManagementRepository {
  DioWebsiteManagementRepository(this.api);
  final ApiClient api;
  static const path = '/website-management';
  @override
  Future<WebsiteManagementInfo> load() async =>
      WebsiteManagementInfo.fromJson(await api.get(path));
  @override
  Future<WebsiteConnectionCheck> check() async =>
      WebsiteConnectionCheck.fromJson(await api.post('$path/check'));
  @override
  Future<WebsiteManagementInfo> configure({
    required int expectedVersion,
    required String displayName,
    required String publicOrigin,
    required bool enabled,
  }) async => WebsiteManagementInfo.fromJson(
    await api.put(
      '$path/config',
      body: {
        'expectedVersion': expectedVersion,
        'displayName': displayName,
        'publicOrigin': publicOrigin,
        'enabled': enabled,
      },
    ),
  );
  @override
  Future<WebsiteEditorGrant> open({
    required String section,
    required String codeChallenge,
  }) async => WebsiteEditorGrant.fromJson(
    await api.post(
      '$path/open',
      body: {'section': section, 'codeChallenge': codeChallenge},
    ),
  );
}
