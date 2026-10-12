import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/warehouse_task_center_record.dart';

/// History reads keep the same source identity and warehouse authorization as the list.
class WarehouseTaskPhysicalDetailDialog extends ConsumerStatefulWidget {
  const WarehouseTaskPhysicalDetailDialog({
    super.key,
    required this.row,
    required this.warehouseScope,
  });
  final WarehouseTaskCenterRecord row;
  final WarehouseTaskScope warehouseScope;

  @override
  ConsumerState<WarehouseTaskPhysicalDetailDialog> createState() =>
      _WarehouseTaskPhysicalDetailDialogState();
}

class _WarehouseTaskPhysicalDetailDialogState
    extends ConsumerState<WarehouseTaskPhysicalDetailDialog> {
  Map<String, dynamic>? _detail;
  String? _error;
  bool _loading = true;
  bool _invalidated = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    void invalidate() {
      ++_revision;
      if (!mounted) return;
      setState(() {
        _detail = null;
        _invalidated = true;
        _loading = false;
        _error = '账号、权限或仓库范围已变化，请关闭后重新打开';
      });
    }

    ref.listenManual(authenticatedScopeProvider, (old, next) {
      if (old != next) invalidate();
    });
    ref.listenManual(apiBaseUrlProvider, (old, next) {
      if (old != next) invalidate();
    });
    ref.listenManual(currentPermissionsProvider, (old, next) {
      if (old != next) invalidate();
    });
    ref.listenManual(warehouseTaskScopeProvider, (old, next) {
      if (old != next) invalidate();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  String get _direction {
    final endpoint = widget.row.dataId('historyEndpoint');
    if (endpoint?.startsWith('/warehouse/task-center/outbound/') == true) {
      return 'outbound';
    }
    if (endpoint?.startsWith('/warehouse/task-center/inbound/') == true) {
      return 'inbound';
    }
    return {'SALES', 'DRAW'}.contains(widget.row.sourceType) ||
            widget.row.recordType == 'SUBCONTRACT_MATERIAL_ISSUE' ||
            widget.row.dataId('docType')?.endsWith('_OUT') == true
        ? 'outbound'
        : 'inbound';
  }

  Future<void> _load(int page) async {
    if (!mounted || _invalidated) return;
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _detail = null;
      _error = null;
    });
    try {
      final detail = await ref
          .read(apiClientProvider)
          .get(
            '/warehouse/task-center/$_direction/${Uri.encodeComponent(widget.row.rowKey)}/detail',
            query: {
              ...widget.warehouseScope.queryParameters,
              'linePage': page,
              'lineSize': 100,
            },
          );
      if (!mounted || _invalidated || revision != _revision) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '明细加载失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final lines =
        (detail?['lines'] as List<Object?>? ??
                detail?['items'] as List<Object?>? ??
                const [])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
    final page = (detail?['page'] as num?)?.toInt() ?? 1;
    final pages =
        (detail?['totalPages'] as num?)?.toInt() ?? (lines.isEmpty ? 0 : 1);
    final total = (detail?['total'] as num?)?.toInt() ?? lines.length;
    final document = detail?['row'] ?? detail?['document'];
    final row = document is Map<String, dynamic>
        ? WarehouseTaskCenterRecord.fromJson(document)
        : widget.row;
    final fields =
        <(String, String)>[
              ('goodsCode', '货品编号'),
              ('goodsName', '货品名称'),
              ('colorName', '颜色'),
              ('unitName', '单位'),
              ('quantity', '数量'),
              ('orderedQty', '订货数量'),
              (
                'acceptedQty',
                row.recordType == 'ARRIVAL_EXCEPTION' ? '批准接收数量' : '已接收数量',
              ),
              ('approvedRemainingQty', '批准量内可收'),
              ('requestedQuantity', '申请数量'),
              ('issuedQuantity', '已发数量'),
              ('countedQty', '点收数量'),
              ('giftQty', '赠品数量'),
              ('unacceptedQty', '待退回数量'),
              ('passedBaseQty', '合格基础数量'),
              ('failedBaseQty', '不合格基础数量'),
              ('stockedBaseQty', '已入库基础数量'),
              ('baseUnitName', '基础单位'),
              ('weightKg', '重量'),
              ('weight', '重量'),
              ('stockPlace', '库位'),
              ('place', '库位'),
              ('lotId', '产出批次'),
              ('sourceReportItemId', '来源报工明细'),
              ('stockDocumentNos', '进仓单号'),
              ('decisionReason', '财务处理说明'),
            ]
            .where((field) => lines.any((line) => line[field.$1] != null))
            .toList(growable: false);
    return AlertDialog(
      title: Text(_invalidated ? '单据详情' : row.statusLabel),
      content: SizedBox(
        width: 920,
        height: 480,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    if (!_invalidated)
                      TextButton(
                        onPressed: () => _load(page),
                        child: const Text('重试'),
                      ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '单据：${row.billNo ?? '—'}    来源：${row.sourceDocNo ?? '—'}',
                  ),
                  Text('仓库：${row.warehouseName ?? '未确定'}    明细：$total 行'),
                  if (row.recordType == 'ARRIVAL_EXCEPTION' && row.canHandle)
                    const Text('请在队列勾选本条，按财务批准量处理；提交时会再次核对原异常版本。'),
                  const SizedBox(height: 12),
                  Expanded(
                    child: fields.isEmpty
                        ? const Center(child: Text('当前记录没有物料明细'))
                        : SingleChildScrollView(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                columns: [
                                  for (final field in fields)
                                    DataColumn(label: Text(field.$2)),
                                ],
                                rows: [
                                  for (final line in lines)
                                    DataRow(
                                      cells: [
                                        for (final field in fields)
                                          DataCell(
                                            Text(
                                              line[field.$1]?.toString() ?? '—',
                                            ),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  if (pages > 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: page > 1 ? () => _load(page - 1) : null,
                          child: const Text('上一页'),
                        ),
                        Text('$page / $pages'),
                        TextButton(
                          onPressed: page < pages
                              ? () => _load(page + 1)
                              : null,
                          child: const Text('下一页'),
                        ),
                      ],
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
