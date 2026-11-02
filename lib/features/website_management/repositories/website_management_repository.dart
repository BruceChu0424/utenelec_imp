import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
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

/// LocalTest never asks the backend to contact the company's CMS bridge.
class LocalTestWebsiteManagementRepository
    implements WebsiteManagementRepository {
  const LocalTestWebsiteManagementRepository();
  static const notice = '本地测试不接入公司网站或外部管理后台。';
  @override
  Future<WebsiteManagementInfo> load() async => const WebsiteManagementInfo(
    version: 0,
    displayName: '本地测试',
    publicOrigin: '',
    adminOrigin: '',
    enabled: false,
    configured: false,
    tokenConfigured: false,
    lastError: notice,
  );
  @override
  Future<WebsiteConnectionCheck> check() async =>
      WebsiteConnectionCheck.fromJson({
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'reachable': false,
        'ready': false,
        'message': notice,
      });
  @override
  Future<WebsiteManagementInfo> configure({
    required int expectedVersion,
    required String displayName,
    required String publicOrigin,
    required bool enabled,
  }) => Future.error(ApiException('LOCAL_TEST_EXTERNAL_DISABLED', notice));
  @override
  Future<WebsiteEditorGrant> open({
    required String section,
    required String codeChallenge,
  }) => Future.error(ApiException('LOCAL_TEST_EXTERNAL_DISABLED', notice));
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
