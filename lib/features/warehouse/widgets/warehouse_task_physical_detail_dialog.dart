import 'dart:async';
import 'dart:convert';

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/layout/uten_pagination.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_store.dart' show describeSubmitError;
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../shared/search/table_column_query.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_task_center_record.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import 'arrival_registration_failure.dart' show isDefiniteArrivalRejection;
import 'arrival_registration_reversal_dialog.dart';

/// Only an explicitly confirmed reversal returns true. Historical browsing stays read-only.
Future<bool> showWarehouseTaskPhysicalDetailDialog(
  BuildContext context, {
  required WarehouseTaskCenterRecord row,
  required WarehouseTaskScope warehouseScope,
  bool allowFinishedRegistrationReversal = false,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: !allowFinishedRegistrationReversal,
      builder: (_) => WarehouseTaskPhysicalDetailDialog(
        row: row,
        warehouseScope: warehouseScope,
        allowFinishedRegistrationReversal: allowFinishedRegistrationReversal,
      ),
    ) ??
    false;

/// History reads keep the same source identity and warehouse authorization as the list.
class WarehouseTaskPhysicalDetailDialog extends ConsumerStatefulWidget {
  const WarehouseTaskPhysicalDetailDialog({
    super.key,
    required this.row,
    required this.warehouseScope,
    this.allowFinishedRegistrationReversal = false,
  });
  final WarehouseTaskCenterRecord row;
  final WarehouseTaskScope warehouseScope;
  final bool allowFinishedRegistrationReversal;

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
  bool _reversing = false;
  String? _reversalMessage;
  String? _pendingReason;
  String? _pendingKey;
  bool _uncertain = false;
  TableColumnQuery _columns = const TableColumnQuery();
  final Set<String> _knownFields = {};
  static const _numericFields = {
    'quantity',
    'orderedQty',
    'acceptedQty',
    'approvedRemainingQty',
    'requestedQuantity',
    'issuedQuantity',
    'countedQty',
    'giftQty',
    'unacceptedQty',
    'passedBaseQty',
    'failedBaseQty',
    'stockedBaseQty',
    'weightKg',
    'weight',
  };

  /// 人名列在两个口径都可能为空；空值统一显示为「—」。
  static String _person(String? value) =>
      value == null || value.isEmpty ? '—' : value;

  WarehouseTaskCenterRecord? _registrationRow(Map<String, dynamic>? detail) {
    final original = widget.row;
    if (!widget.allowFinishedRegistrationReversal ||
        original.action != 'FINISHED_ARRIVAL_DETAIL' ||
        original.sourceType != 'FINISHED' ||
        original.recordType != 'FINISHED_REGISTRATION' ||
        original.dataId('reportId') == null ||
        original.dataId('registrationId') != original.id) {
      return null;
    }
    final document = detail?['row'];
    if (document is! Map<String, dynamic>) return null;
    final current = WarehouseTaskCenterRecord.fromJson(document);
    if (current.sourceType != 'FINISHED' ||
        current.recordType != 'FINISHED_REGISTRATION' ||
        current.id != original.id ||
        current.targetId != original.id ||
        current.dataId('reportId') != original.dataId('reportId') ||
        current.dataId('registrationId') != original.id) {
      return null;
    }
    return current;
  }

  bool get _canReverseRegistration {
    if (_invalidated || _loading || _error != null) return false;
    final actor = ref.read(authenticatedScopeProvider);
    final permissions = ref.read(currentPermissionsProvider);
    final row = _registrationRow(_detail);
    return actor != null &&
        !actor.readOnly &&
        actor.actorId == null &&
        permissions.contains(Perm.stockDocView) &&
        permissions.contains(Perm.stockDocApprove) &&
        row != null &&
        row.action == 'FINISHED_ARRIVAL_DETAIL' &&
        row.canHandle &&
        row.actionData['reversible'] == true;
  }

  Future<void> _reverseRegistration({bool recover = false}) async {
    if (_reversing || !_canReverseRegistration) return;
    final row = _registrationRow(_detail)!;
    final originalDetail = _detail;
    final revision = _revision;
    final actor = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final permissions = ref.read(currentPermissionsProvider);
    final warehouse = ref.read(warehouseTaskScopeProvider);
    final hadUncertainResult = _uncertain;
    var attemptedPost = false;
    bool isCurrent() =>
        mounted &&
        !_invalidated &&
        revision == _revision &&
        identical(originalDetail, _detail) &&
        actor == ref.read(authenticatedScopeProvider) &&
        server == ref.read(apiBaseUrlProvider) &&
        permissions == ref.read(currentPermissionsProvider) &&
        warehouse == ref.read(warehouseTaskScopeProvider) &&
        _canReverseRegistration;
    setState(() => _reversing = true);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: isCurrent);
      if (!mounted || !isCurrent()) return;
      final reason = recover
          ? _pendingReason
          : await showArrivalRegistrationReversalDialog(
              context,
              title: '撤回本登记批（仅品质未处理）',
              summary:
                  '报工单 ${row.billNo ?? '—'} · ${row.warehouseName ?? '—'} · '
                  '${row.sourceDocNo == null ? '' : '检查单 ${row.sourceDocNo} · '}'
                  '撤回整个原登记批（包含当前未显示的明细），'
                  '当前可见 ${_detail?['total'] ?? 0} 行。',
            );
      if (!mounted || reason == null || !isCurrent()) return;
      // An immutable registration can be reversed only once. Re-entering with
      // the same actor, registration and reason also retains the original key.
      final key = recover
          ? _pendingKey
          : businessIdempotencyKey(
              'arrival-reverse',
              jsonEncode([actor!.userId, row.id, reason]),
            );
      if (key == null) return;
      _pendingReason = reason;
      _pendingKey = key;
      final result = await scope.run(() {
        if (!isCurrent()) throw AuthenticatedRequestScope.changed();
        attemptedPost = true;
        return ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .reverseArrivalRegistration(
              row.id,
              reason: reason,
              idempotencyKey: key,
            );
      });
      if (!mounted || !isCurrent()) return;
      if (result.registrationId != row.id ||
          result.reportId != row.dataId('reportId') ||
          result.reversedAt == null) {
        throw const FormatException('服务端未确认原登记批的撤回结果');
      }
      context.appSuccess('本登记批已撤回，相关待检任务已取消');
      unawaited(
        invalidateWarehouseTaskCounts(ref).catchError((Object error) {
          debugPrint('登记撤回后的任务计数刷新失败: $error');
        }),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted || _invalidated) return;
      final definite =
          error is ApiException &&
          !isSessionBoundaryError(error) &&
          isDefiniteArrivalRejection(error);
      final uncertain = hadUncertainResult || (attemptedPost && !definite);
      final message = uncertain
          ? '撤回结果未确认，请核对原登记批；原原因和请求标识已保留，'
                '可使用原请求恢复结果。'
                '${describeSubmitError(error, fallback: '服务器响应暂时无法确认')}'
          : attemptedPost
          ? describeSubmitError(error, fallback: '撤回被拒绝，请重新核对原登记批')
          : '尚未发送撤回请求。'
                '${describeSubmitError(error, fallback: '请核对身份后重试')}';
      setState(() {
        _uncertain = uncertain && _pendingKey != null;
        _reversalMessage = message;
      });
      context.appError(message);
      if (definite) await _load(1);
    } finally {
      if (mounted) setState(() => _reversing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    void invalidate() {
      ++_revision;
      if (!mounted) return;
      setState(() {
        _detail = null;
        _knownFields.clear();
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
      final detailRowKey =
          widget.allowFinishedRegistrationReversal &&
              widget.row.action == 'FINISHED_ARRIVAL_DETAIL'
          ? widget.row.documentRowKey
          : widget.row.rowKey;
      final detail = await ref
          .read(apiClientProvider)
          .get(
            '/warehouse/task-center/$_direction/${Uri.encodeComponent(detailRowKey)}/detail',
            query: {
              ...widget.warehouseScope.queryParameters,
              'linePage': page,
              'lineSize': 100,
              ...tableColumnParameters(
                _columns.searches,
                _columns.sort,
                _columns.ascending,
              ),
            },
          );
      if (!mounted || _invalidated || revision != _revision) return;
      if (widget.allowFinishedRegistrationReversal) {
        final row = _registrationRow(detail);
        final lines = detail['lines'] ?? detail['items'];
        if (row == null ||
            lines is! List ||
            (lines.isEmpty && _columns.searches.isEmpty) ||
            lines.any(
              (line) => line is! Map || line['registrationId'] != row.id,
            )) {
          throw ApiException('CONFLICT', '原登记批身份或明细已变化，请关闭后刷新重选');
        }
      }
      setState(() {
        _detail = detail;
        final lines = detail['lines'] ?? detail['items'];
        if (lines is List) {
          for (final line in lines.whereType<Map<String, dynamic>>()) {
            _knownFields.addAll(
              line.entries
                  .where((entry) => entry.value != null)
                  .map((entry) => entry.key),
            );
          }
        }
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
    final fields = <(String, String)>[
      ('goodsName', '货品名称'),
      ('goodsCode', '货品编号'),
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
    ].where((field) => _knownFields.contains(field.$1)).toList(growable: false);
    return PopScope<bool>(
      canPop: !_reversing,
      child: UtenAlertDialog(
        showCloseButton: true,
        onClose: _reversing ? null : () => Navigator.pop(context, false),
        closeEnabled: !_reversing,
        maxWidth: 920,
        scrollable: false,
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
                    Text(
                      '负责人：${_person(row.responsibleName)}    制单人：${_person(row.makerName)}',
                    ),
                    if (_reversalMessage != null) ...[
                      Text(_reversalMessage!),
                      if (_uncertain && _pendingReason != null)
                        Text('原撤回原因：$_pendingReason'),
                    ],
                    if (row.recordType == 'ARRIVAL_EXCEPTION' && row.canHandle)
                      const Text('请在队列勾选本条，按财务批准量处理；提交时会再次核对原异常版本。'),
                    const SizedBox(height: 12),
                    Expanded(
                      child: fields.isEmpty
                          ? const Center(child: Text('当前记录没有物料明细'))
                          : MasterDataTableView<Map<String, dynamic>>(
                              tableKey:
                                  'warehouse.task-center.physical-detail.${row.recordType}',
                              columns: [
                                for (final field in fields)
                                  MasterColumnDef(
                                    key: field.$1,
                                    label: field.$2,
                                    width: switch (field.$1) {
                                      'goodsName' || 'decisionReason' => 240,
                                      'lotId' ||
                                      'sourceReportItemId' ||
                                      'stockDocumentNos' => 220,
                                      _ => 140,
                                    },
                                    type: _numericFields.contains(field.$1)
                                        ? 'number'
                                        : 'text',
                                    sortable: true,
                                    columnSearchEnabled: true,
                                    info:
                                        field.$1 == 'weight' ||
                                            field.$1 == 'weightKg'
                                        ? '按原始千克（kg）检索重量。'
                                        : null,
                                    exactValueOf:
                                        _numericFields.contains(field.$1)
                                        ? (line) =>
                                              (line['${field.$1}Exact'] ??
                                                      line[field.$1])
                                                  ?.toString()
                                        : null,
                                    value: (line) {
                                      final value =
                                          _numericFields.contains(field.$1)
                                          ? line['${field.$1}Exact'] ??
                                                line[field.$1]
                                          : line[field.$1];
                                      return value is List
                                          ? value
                                                .map((item) => item.toString())
                                                .join('、')
                                          : value?.toString();
                                    },
                                  ),
                              ],
                              items: lines,
                              serverColumnSearchKeys: fields
                                  .map((field) => field.$1)
                                  .toSet(),
                              currentPage: page,
                              totalPages: pages,
                              showPaginationControls: false,
                              facets: const {},
                              nullCounts: const {},
                              filters: _columns.searches,
                              onFilterChanged: (key, value) {
                                if (_reversing || _invalidated) return;
                                setState(
                                  () => _columns = _columns.search(key, value),
                                );
                                _load(1);
                              },
                              sortColumn: _columns.sort,
                              sortAscending: _columns.ascending,
                              onSortChange: (key, ascending) {
                                if (_reversing || _invalidated) return;
                                setState(
                                  () => _columns = _columns.sorted(
                                    key,
                                    ascending,
                                  ),
                                );
                                _load(1);
                              },
                              headerFilterScopeDescription:
                                  '检索覆盖本条记录当前授权的全部实物明细；不会改变整批撤回或其它业务动作的范围。',
                              emptyMessage: '当前记录没有物料明细',
                            ),
                    ),
                    if (pages > 1)
                      Align(
                        alignment: Alignment.centerRight,
                        child: UtenPagination(
                          currentPage: page,
                          totalPages: pages,
                          busy: _loading || _reversing || _invalidated,
                          onPageChanged: _load,
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          if (_canReverseRegistration)
            FilledButton.icon(
              key: const Key('finished-registration-detail-reverse'),
              onPressed: _reversing
                  ? null
                  : () => _reverseRegistration(recover: _uncertain),
              icon: const Icon(Icons.undo_rounded),
              label: Text(
                _reversing
                    ? '正在核对撤回结果'
                    : _uncertain
                    ? '使用原请求恢复结果'
                    : '撤回本登记批',
              ),
            ),
        ],
      ),
    );
  }
}
