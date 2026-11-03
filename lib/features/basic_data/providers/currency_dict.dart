import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/master_dictionary_repository.dart';
import '../models/currency_node.dart';

/// Reuses the session dictionary cache and its identity/revision invalidation.
final currencyDictProvider = FutureProvider<List<CurrencyListItem>>((
  ref,
) async {
  ref.watch(masterDictionaryRevisionProvider);
  final rows = await ref
      .watch(masterDictionaryRepositoryProvider)
      .load(ApiEndpoints.currenciesDict);
  return rows.map(CurrencyListItem.fromJson).toList();
});
