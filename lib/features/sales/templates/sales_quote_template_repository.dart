import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'sales_quote_template.dart';

class SalesQuoteTemplateRepository {
  const SalesQuoteTemplateRepository(this.api);
  final ApiClient api;

  Future<Map<String, dynamic>> learningContext(String quoteId) =>
      api.get('/sales/quotes/$quoteId/templates/learning-context');

  Future<SalesQuoteTemplate> adopt(String quoteId, String jobId) async =>
      SalesQuoteTemplate.fromJson(
        await api.post(
          '/sales/quotes/$quoteId/templates/adopt',
          body: {'jobId': jobId},
        ),
      );

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
