// ADR-149: 仓库任务中心挑了仓时, 库存单据分段的「草稿」数与旁边列表同一个 scopeWarehouseId;
// 没挑仓不带参数(服务端按本人默认范围计数)。范围不同就是不同的一份计数(family 键不相等)。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>?>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.documentStatusCounts);
    queries.add(query);
    return {'DRAFT': query?['scopeWarehouseId'] == null ? 3 : 1};
  }
}

void main() {
  test('stock document segment counts carry the picked warehouse', () async {
    final api = _Api();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        isSuperAdminProvider.overrideWithValue(true),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
      ],
    );
    addTearDown(container.dispose);
    const all = DocumentStatusScope(
      DraftDocKind.stockDocument,
      docType: 'OTHER_OUT',
    );
    const picked = DocumentStatusScope(
      DraftDocKind.stockDocument,
      docType: 'OTHER_OUT',
      scopeWarehouseId: 'warehouse-b',
    );
    expect(all == picked, isFalse);
    expect(
      (await container.read(documentStatusCountsProvider(all).future))['DRAFT'],
      3,
    );
    expect(
      (await container.read(
        documentStatusCountsProvider(picked).future,
      ))['DRAFT'],
      1,
    );
    expect(api.queries.first, {
      'kind': 'stockDocument',
      'docType': 'OTHER_OUT',
    });
    expect(api.queries.last, {
      'kind': 'stockDocument',
      'docType': 'OTHER_OUT',
      'scopeWarehouseId': 'warehouse-b',
    });
  });
}
