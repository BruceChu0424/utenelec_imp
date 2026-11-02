import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

final _permissions = StateProvider<Set<String>>((ref) => {Perm.stockDocView});

void main() {
  test(
    'brief departures reuse exact-scope counts; writes and read boundaries revalidate',
    () async {
      final api = _Api();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'fixture'),
          ),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_permissions),
          ),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      const a = DocumentStatusScope(
        DraftDocKind.stockDocument,
        docType: 'OTHER_OUT',
        scopeWarehouseId: 'a',
      );
      const b = DocumentStatusScope(
        DraftDocKind.stockDocument,
        docType: 'OTHER_OUT',
        scopeWarehouseId: 'b',
      );
      final subscription = container.listen(
        documentStatusCountsProvider(a),
        (_, _) {},
      );
      expect(
        (await container.read(documentStatusCountsProvider(a).future))['DRAFT'],
        7,
      );
      subscription.close();
      await container.pump();
      expect(
        (await container.read(documentStatusCountsProvider(a).future))['DRAFT'],
        7,
      );
      expect(api.reads, 1);
      expect(
        (await container.read(documentStatusCountsProvider(b).future))['DRAFT'],
        2,
      );
      expect(api.reads, 2);
      container.read(dataWriteRevisionProvider.notifier).state++;
      await container.pump();
      await container.read(documentStatusCountsProvider(a).future);
      expect(api.reads, greaterThan(2));
      final before = api.reads;
      container.read(readScopeRevisionProvider.notifier).state++;
      await container.pump();
      await container.read(documentStatusCountsProvider(a).future);
      expect(api.reads, greaterThan(before));
      container.read(_permissions.notifier).state = {};
      await container.pump();
      expect(
        await container.read(documentStatusCountsProvider(a).future),
        isEmpty,
      );
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int reads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    return {'DRAFT': query?['scopeWarehouseId'] == 'a' ? 7 : 2};
  }
}
