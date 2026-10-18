import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add(Map.of(query ?? const {}));
    return {'DRAFT': 4, 'ACTIONABLE_DRAFT': 2};
  }
}

void main() {
  test(
    'customer shipment view reads only its explicitly requested slice',
    () async {
      final api = _Api();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesOtherShipmentView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      const customer = DocumentStatusScope(
        DraftDocKind.salesShipment,
        shipmentKind: 'DIRECT_CUSTOMER',
      );
      expect(
        await container.read(documentStatusCountsProvider(customer).future),
        containsPair('ACTIONABLE_DRAFT', 2),
      );
      expect(api.queries.single['shipmentKind'], 'DIRECT_CUSTOMER');
      const allShipments = DocumentStatusScope(DraftDocKind.salesShipment);
      expect(
        await container.read(documentStatusCountsProvider(allShipments).future),
        isEmpty,
      );
      expect(api.queries, hasLength(1));
    },
  );
}
