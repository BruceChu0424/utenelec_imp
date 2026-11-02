// Business picker instances share the existing query algorithms.
// Master providers and every detail/CRUD endpoint retain their original source.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/client_node.dart';
import '../models/supplier_node.dart';
import 'client_repository.dart';
import 'account_repository.dart';
import 'client_category_repository.dart';
import 'supplier_repository.dart';
import 'supplier_category_repository.dart';
import 'goods_repository.dart';
import 'goods_facet_repository.dart';
import 'product_category_repository.dart';

Map<String, dynamic> _partyIdentity(Map<String, dynamic> row) => {
  for (final key in [
    'id',
    'code',
    'name',
    'categoryId',
    'status',
    'defaultSettlementMethodId',
  ])
    if (row.containsKey(key)) key: row[key],
};

final businessAccountReferenceRepositoryProvider = Provider<AccountRepository>((
  ref,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  return DioAccountRepository(
    ref.watch(apiClientProvider),
    dictPath: ApiEndpoints.businessReferenceAccounts,
  );
});

final businessSupplierReferenceRepositoryProvider =
    Provider<SupplierRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioSupplierRepository(
        ref.watch(apiClientProvider),
        queryBasePath: ApiEndpoints.businessReferenceSuppliers,
        selectionFlagsInBody: true,
        decodeListItem: (row) => SupplierListItem.fromJson(_partyIdentity(row)),
      );
    });
final businessClientReferenceRepositoryProvider = Provider<ClientRepository>((
  ref,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  return DioClientRepository(
    ref.watch(apiClientProvider),
    queryBasePath: ApiEndpoints.businessReferenceClients,
    selectionFlagsInBody: true,
    decodeListItem: (row) => ClientListItem.fromJson(_partyIdentity(row)),
  );
});
final businessSupplierCategoryRepositoryProvider =
    Provider<SupplierCategoryRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioSupplierCategoryRepository(
        ref.watch(apiClientProvider),
        treePath: ApiEndpoints.businessReferenceSupplierCategories,
      );
    });
final businessClientCategoryRepositoryProvider =
    Provider<ClientCategoryRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioClientCategoryRepository(
        ref.watch(apiClientProvider),
        treePath: ApiEndpoints.businessReferenceClientCategories,
      );
    });
final businessGoodsReferenceRepositoryProvider = Provider<GoodsRepository>((
  ref,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  return DioGoodsRepository(
    ref.watch(apiClientProvider),
    queryBasePath: ApiEndpoints.businessReferenceGoods,
  );
});
final businessGoodsCategoryRepositoryProvider =
    Provider<ProductCategoryRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DioProductCategoryRepository(
        ref.watch(apiClientProvider),
        treePath: ApiEndpoints.businessReferenceGoodsCategories,
      );
    });
final businessGoodsFacetRepositoryProvider = Provider<GoodsFacetRepository?>((
  ref,
) {
  final repository = ref.watch(businessGoodsReferenceRepositoryProvider);
  return repository is DioGoodsRepository
      ? GoodsFacetRepository(
          repository.api,
          queryBasePath: repository.queryBasePath,
        )
      : null;
});
