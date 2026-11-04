import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../basic_data/models/master_facet.dart';
import '../../../shared/providers/native_facet_options.dart';

const financeReportColumnCandidatePath = '/finance/reports/column-candidates';

/// Every report adapter retains its complete original query and declared columns.
Map<String, MasterFacetColumnLoader> financeReportFacetLoaders(
  WidgetRef ref, {
  required String report,
  required Iterable<String> fields,
  required Map<String, dynamic> query,
}) => {
  for (final field in fields)
    field: nativeFacetLoaders(
      ref,
      path: financeReportColumnCandidatePath,
      fields: const ['value'],
      filters: {...query, 'report': report, 'column': field},
    )['value']!,
};

Object financeReportFacetScope(
  WidgetRef ref, {
  required String report,
  required Map<String, dynamic> query,
}) => nativeFacetSearchScope(ref, financeReportColumnCandidatePath, {
  'report': report,
  ...query,
});
