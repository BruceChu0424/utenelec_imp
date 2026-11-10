/// Exact read-only master/reference summaries may opt into a single response
/// whose internal pages remain bounded. This is independent of file downloads.
const summaryStreamRequestKey = 'uten.summary.stream';
const summaryStreamContentType = 'application/x-ndjson';
const summaryStreamErrorBytes = 64 * 1024;

bool isSummaryStreamPath(String path) {
  final local = path.startsWith('/api/') ? path.substring(4) : path;
  return const {
    '/master/goods/summaries',
    '/master/clients/summaries',
    '/master/suppliers/summaries',
    '/master/moulds/summaries',
    '/master/colors/summaries',
    '/master/units/summaries',
    '/master/currencies/summaries',
    '/master/accounts/summaries',
    '/master/reference-methods/settlement-admin/summaries',
    '/business-references/goods/summaries',
    '/business-references/clients/summaries',
    '/business-references/suppliers/summaries',
    '/stock/instant-inventory/summaries',
  }.contains(local);
}
