import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'sales_quote_template.dart';

class SalesQuoteTemplateRepository {
  const SalesQuoteTemplateRepository(this.api);
  final ApiClient api;

  Future<List<SalesQuoteTemplate>> listForQuote(String quoteId) async {
    final rows = await api.getList('/sales/quotes/$quoteId/templates');
    return rows
        .map(SalesQuoteTemplate.fromJson)
        .where((template) => template.id.isNotEmpty)
        .toList(growable: false);
  }
}

final salesQuoteTemplateRepositoryProvider =
    Provider<SalesQuoteTemplateRepository>(
      (ref) => SalesQuoteTemplateRepository(ref.watch(apiClientProvider)),
    );
