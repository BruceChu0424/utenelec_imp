import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/quality/repositories/quality_pending_queue_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

// The queue now has its own server endpoint. Keep the existing synthetic IQC
// facts behind that paged boundary rather than allowing a real HTTP request.
class ReceiptQualityQueueFixture extends QualityPendingQueueRepository {
  ReceiptQualityQueueFixture(super.api, this.repository);
  final ProcurementInspectionRepository repository;

  @override
  Future<QualityPendingPage> query({
    int page = 1,
    int size = 10,
    String keyword = '',
    String? docType,
    String? status,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
    Map<String, String> draftStatuses = const {},
  }) async {
    if (columns.values.any((value) => value?.isNotEmpty ?? false)) {
      throw UnsupportedError('Add explicit typed-column fixture coverage');
    }
    final all = <QualityPendingEntry>[
      for (final value in await repository.pendingReceipts())
        QualityPendingEntry(
          source: 'IQC',
          identity: 'iqc:${value.receiptType}:${value.receiptId}',
          kind: value.receiptType,
          status:
              '${value.receiptType == 'SUBCONTRACT' ? '委外' : '采购'}'
              '${draftStatuses['iqc:${value.receiptType}:${value.receiptId}'] ?? '待检'}',
          values: {
            'billNo': value.billNo ?? value.receiptId,
            'party': value.supplierName ?? '—',
            'goods': value.goodsSummary ?? '—',
            'goodsCode': value.goodsCodeSummary ?? '—',
            'colorName': value.colorNameSummary ?? '—',
            'warehouse': value.preStockedWarehouseNames ?? '待检区',
            'place': value.preStockedPlaces ?? '—',
            'pendingQty': value.pendingQtyText ?? '—',
            'itemCount': value.itemCount,
            'enteredAt': value.lastReceivedAt,
          },
          payload: {
            'receiptType': value.receiptType,
            'receiptId': value.receiptId,
            'billNo': value.billNo,
            'supplierId': value.supplierId,
            'supplierName': value.supplierName,
            'warehouseId': value.warehouseId,
            'itemCount': value.itemCount,
            'pendingBaseQty': value.pendingBaseQty,
            'firstReceivedAt': value.firstReceivedAt,
            'lastReceivedAt': value.lastReceivedAt,
            'preStockedItemCount': value.preStockedItemCount,
            'preStockedWarehouseNames': value.preStockedWarehouseNames,
            'preStockedPlaces': value.preStockedPlaces,
            'goodsSummary': value.goodsSummary,
            'goodsCodeSummary': value.goodsCodeSummary,
            'colorNameSummary': value.colorNameSummary,
            'pendingQtyText': value.pendingQtyText,
          },
        ),
    ];
    final matching = all.where(
      (entry) => entry.values.values.any(
        (value) => (value?.toString() ?? '').toLowerCase().contains(
          keyword.toLowerCase(),
        ),
      ),
    );
    final selected = matching
        .where(
          (entry) =>
              (docType == null || entry.kind == docType) &&
              (status == null || entry.status == status),
        )
        .toList();
    if (sort != null) {
      selected.sort((a, b) {
        final left = a.values[sort], right = b.values[sort];
        final comparison = left is num && right is num
            ? left.compareTo(right)
            : (left?.toString() ?? '').compareTo(right?.toString() ?? '');
        return ascending ? comparison : -comparison;
      });
    }
    final totalPages = (selected.length + size - 1) ~/ size;
    final actualPage = page.clamp(1, totalPages == 0 ? 1 : totalPages).toInt();
    return QualityPendingPage(
      items: selected.skip((actualPage - 1) * size).take(size).toList(),
      page: actualPage,
      total: selected.length,
      totalPages: totalPages,
      facets: {
        'status': [
          for (final value in {
            for (final entry in matching)
              if (docType == null || entry.kind == docType) entry.status,
          })
            MasterFacetBucket(
              value: value,
              label: value,
              count: matching
                  .where(
                    (entry) =>
                        entry.status == value &&
                        (docType == null || entry.kind == docType),
                  )
                  .length,
            ),
        ],
        'docType': [
          for (final kind in ['PURCHASE', 'SUBCONTRACT'])
            MasterFacetBucket(
              value: kind,
              label: kind == 'PURCHASE' ? '采购收货' : '委外回厂',
              count: matching
                  .where(
                    (entry) =>
                        entry.kind == kind &&
                        (status == null || entry.status == status),
                  )
                  .length,
            ),
        ],
      },
      sourceCounts: {
        for (final kind in ['PURCHASE', 'SUBCONTRACT', 'FQC'])
          kind: matching.where((entry) => entry.kind == kind).length,
      },
    );
  }
}
