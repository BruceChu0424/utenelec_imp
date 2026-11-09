part of 'quality_pending_disposal_page_test.dart';

/// Test-server fixture: the widget receives only the requested page. Production
/// uses its SQL source ports; no source-list joining or cap lives in the widget.
///
/// 2026-11-09 行粒度镜像：IQC 一行 = 一条检验明细（fixture 按收货单摘要合成
/// itemCount 行）、检查单一行 = 一条实物批（fixture 合成单批）；草稿状态仍按
/// 单据粒度身份（iqc:类型:收货单 / sheet:检查单 / fqc:任务）标记。
class _FakeQueueRepository extends QualityPendingQueueRepository {
  _FakeQueueRepository(this.fqc, this.iqc, this.permissions) : super(fqc);
  final _FqcApi fqc;
  final _FakeIqcRepository iqc;
  final Set<String> Function() permissions;
  Future<List<Map<String, dynamic>>> _all(String path, {String? sheet}) async {
    final rows = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final response = await fqc.get(
        path,
        query: {'status': 'ACTIVE', 'page': page, 'size': 100, 'sheet': sheet},
      );
      final values = response['items'] as List;
      rows.addAll(
        values.map((value) => Map<String, dynamic>.from(value as Map)),
      );
      if (values.isEmpty || page >= (response['totalPages'] as num).toInt()) {
        break;
      }
      page++;
    }
    return rows;
  }

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
    final all = <QualityPendingEntry>[];
    final perms = permissions();
    if (perms.contains(Perm.procurementInspectionView)) {
      for (final value in await iqc.pendingReceipts()) {
        final lines = value.itemCount < 1 ? 1 : value.itemCount;
        for (var line = 1; line <= lines; line++) {
          final payload = <String, dynamic>{
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
          };
          all.add(
            _entry(
              'IQC',
              'iqc:${value.receiptType}:${value.receiptId}:'
                  'item-of-${value.receiptId}-$line',
              'iqc:${value.receiptType}:${value.receiptId}',
              value.receiptType,
              payload,
              {
                'billNo': value.billNo ?? value.receiptId,
                'party': value.supplierName ?? '—',
                'goods': value.goodsSummary ?? '—',
                'goodsCode': value.goodsCodeSummary ?? '—',
                'colorName': value.colorNameSummary ?? '—',
                'warehouse': value.preStockedWarehouseNames ?? '待检区',
                'place': value.preStockedPlaces ?? '—',
                'pendingQty': value.pendingQtyText ?? '—',
                'enteredAt': value.lastReceivedAt,
                'preStocked': value.hasPreStockedItems,
                'statusCode': 'PENDING',
              },
              'PENDING',
              draftStatuses,
            ),
          );
        }
      }
    }
    if (perms.contains(Perm.productionQualityInspectionView)) {
      for (final payload in await _all(
        ApiEndpoints.productionQualityInspectionSheets,
      )) {
        all.add(
          _entry(
            'FQC_SHEET',
            'sheet:${payload['id']}:lot-of-${payload['id']}',
            'sheet:${payload['id']}',
            'FQC',
            payload,
            {
              'billNo': payload['sheetNo'],
              'party': [
                payload['warehouseName'],
                if (payload['receiverName'] != null)
                  '收货 ${payload['receiverName']}',
                if (payload['reportNos'] != null) '报工 ${payload['reportNos']}',
              ].whereType<String>().join(' · '),
              'goods': payload['goodsSummary'] ?? '—',
              'goodsCode': payload['goodsCodeSummary'] ?? '—',
              'colorName': payload['colorNameSummary'] ?? '—',
              'warehouse': payload['warehouseName'] ?? '—',
              'place': payload['placeSummary'] ?? '—',
              'pendingQty': payload['pendingQtyText'] ?? '—',
              'enteredAt': payload['createdAt'],
              'preStocked': (payload['preStockedItemCount'] as num? ?? 0) > 0,
              'statusCode':
                  (payload['activeCount'] as num) <
                      (payload['itemCount'] as num)
                  ? 'PARTIAL'
                  : 'PENDING',
            },
            (payload['activeCount'] as num) < (payload['itemCount'] as num)
                ? 'PARTIAL'
                : 'PENDING',
            draftStatuses,
          ),
        );
      }
      for (final payload in await _all(
        ApiEndpoints.productionQualityInspections,
        sheet: 'NONE',
      )) {
        final remaining = (payload['remainingQty'] as num?)?.toDouble() ?? 0;
        all.add(
          _entry(
            'FQC',
            'fqc:${payload['id']}',
            'fqc:${payload['id']}',
            'FQC',
            payload,
            {
              'billNo': payload['reportNo'] ?? payload['id'],
              'party': '无检查单 · 计划 ${payload['planNo'] ?? '—'}',
              'goods': payload['goodsName'] ?? '—',
              'goodsCode': payload['goodsCode'] ?? '—',
              'colorName': payload['colorName'] ?? '—',
              'warehouse': payload['warehouseName'] ?? '—',
              'place': payload['place'] ?? '—',
              'pendingQty':
                  '${remaining.toString().replaceFirst(RegExp(r'\.0$'), '')} ${payload['unitName'] ?? ''}',
              'enteredAt': payload['createdAt'],
              'preStocked': payload['preStocked'] != null,
              'statusCode': payload['status'] as String,
            },
            payload['status'] as String,
            draftStatuses,
          ),
        );
      }
    }
    Iterable<String?> words(QualityPendingEntry entry) => [
      'billNo',
      'party',
      'goods',
      'goodsCode',
      'colorName',
      'warehouse',
      'place',
    ].map((key) => entry.values[key]?.toString());
    bool header(QualityPendingEntry entry) => columns.entries.every((filter) {
      if (filter.value == null || !filter.key.startsWith('search.')) {
        return true;
      }
      final key = filter.key.substring(7),
          value = entry.values[key]?.toString();
      if (key == 'enteredAt') return value?.startsWith(filter.value!) ?? false;
      return matchesKeywordSearch([value], filter.value!);
    });
    final eligible = rankedKeywordMatches(
      all.where(header),
      keyword,
      fields: words,
      primaryFields: (entry) => [entry.values['goods']?.toString()],
    );
    final selected = eligible
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
    List<MasterFacetBucket> facets(Iterable<String> values) {
      final counts = <String, int>{};
      for (final value in values) {
        counts.update(value, (v) => v + 1, ifAbsent: () => 1);
      }
      return [
        for (final entry in counts.entries)
          MasterFacetBucket(
            value: entry.key,
            label: entry.key,
            count: entry.value,
          ),
      ];
    }

    final pages = (selected.length + size - 1) ~/ size;
    final actual = page.clamp(1, pages == 0 ? 1 : pages).toInt();
    return QualityPendingPage(
      items: selected.skip((actual - 1) * size).take(size).toList(),
      page: actual,
      total: selected.length,
      totalPages: pages,
      facets: {
        'status': facets(
          eligible
              .where((entry) => docType == null || entry.kind == docType)
              .map((e) => e.status),
        ),
        'docType': facets(
          eligible
              .where((entry) => status == null || entry.status == status)
              .map((e) => e.kind),
        ),
      },
      sourceCounts: {
        for (final kind in ['PURCHASE', 'SUBCONTRACT', 'FQC'])
          kind: all.where((entry) => entry.kind == kind).length,
      },
    );
  }

  QualityPendingEntry _entry(
    String source,
    String id,
    String draftId,
    String kind,
    Map<String, dynamic> payload,
    Map<String, dynamic> values,
    String code,
    Map<String, String> drafts,
  ) {
    final prefix = kind == 'FQC'
        ? '成品'
        : kind == 'SUBCONTRACT'
        ? '委外'
        : '采购';
    return QualityPendingEntry(
      source: source,
      identity: id,
      kind: kind,
      status:
          '$prefix${drafts[draftId] ?? (code == 'PARTIAL' ? '部分已决定' : '待检')}',
      values: values,
      payload: payload,
    );
  }
}
