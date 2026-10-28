import '../../../shared/documents/imported_document_policy.dart';
import '../../basic_data/models/master_facet.dart';
import 'stock_doc.dart';

/// Status/read-source mapping shared by the document page and task segment.
List<MasterFacetBucket> stockDocHeaderStatuses({
  required bool history,
  required int? stage,
  bool includeLegacy = false,
  bool returnTaskLabels = false,
}) => [
  for (final status in history ? const [0, 1, -1] : [?stage])
    MasterFacetBucket(
      value: '$status',
      count: 0,
      label: returnTaskLabels
          ? switch (status) {
              0 => '待仓库收料',
              1 => '仓库已收料',
              _ => '已撤回',
            }
          : stockStatusLabel(status),
    ),
  if (history && includeLegacy)
    const MasterFacetBucket(
      value: 'LEGACY',
      count: 0,
      label: importedBusinessHistoryLabel,
    ),
];

int? stockDocHeaderStatus(String? selected, int? stage) =>
    selected == 'LEGACY' ? null : int.tryParse(selected ?? '') ?? stage;

BusinessDocumentOrigin? stockDocHeaderOrigin(
  String? selected, {
  required bool history,
  required bool includeLegacy,
}) => !history || !includeLegacy
    ? null
    : selected == null
    ? BusinessDocumentOrigin.all
    : selected == 'LEGACY'
    ? BusinessDocumentOrigin.legacy
    : BusinessDocumentOrigin.current;
