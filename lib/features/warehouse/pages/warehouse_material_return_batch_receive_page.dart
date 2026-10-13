// 生产退料批量收料页（2026-09-27 用户口径「生产退料里应该支持多选批量入库，
// 和其他的比如出库可以批量操作一样」）：从仓库任务中心「生产退料」段勾选多张
// 待收料单进入；每张单选一个实际收料仓（范围=退料单主仓下的有效正常仓，与单张
// 详情页的收料弹窗同一约束），右下「确认批量收料(N)」逐张提交——幂等键与单张
// 收料同配方（material-return-confirm|单据|仓库），单张失败即停并保留进度。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class WarehouseMaterialReturnBatchReceivePage extends ConsumerStatefulWidget {
  const WarehouseMaterialReturnBatchReceivePage({
    super.key,
    required this.documentIds,
  });

  final List<String> documentIds;

  @override
  ConsumerState<WarehouseMaterialReturnBatchReceivePage> createState() =>
      _WarehouseMaterialReturnBatchReceivePageState();
}

class _Row {
  _Row(this.detail);

  final StockDocDetail detail;
  String? warehouseId;
  bool done = false;
}

class _WarehouseMaterialReturnBatchReceivePageState
    extends ConsumerState<WarehouseMaterialReturnBatchReceivePage>
    with FormDraftMixin<WarehouseMaterialReturnBatchReceivePage> {
  final List<_Row> _rows = [];
  bool _loading = false;
  bool _saving = false;
  String? _error;
  String? _pendingDocumentId;
  bool _uncertain = false;

  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.materialReturnBatchReceive.spec(
        title: '批量生产退料收仓',
        route: Uri(
          path: FormDraftCatalog.materialReturnBatchReceive.route,
          queryParameters: {'documentIds': widget.documentIds.join(',')},
        ).toString(),
      );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'documentIds': widget.documentIds,
    'pendingDocumentId': _pendingDocumentId,
    'uncertain': _uncertain,
    'rows': [
      for (final row in _rows)
        {
          'documentId': row.detail.id,
          'warehouseId': row.warehouseId,
          'done': row.done,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final sources = draftStrings(data['documentIds']).toSet();
    if (sources.length != widget.documentIds.toSet().length ||
        !sources.containsAll(widget.documentIds)) {
      throw const FormatException('原批次退料来源不一致，填写保留，请返回任务中心核对');
    }
    final saved = {
      for (final row in draftMaps(data['rows'])) row['documentId']: row,
    };
    for (final row in _rows) {
      final checkpoint = saved[row.detail.id];
      if (checkpoint == null) continue;
      row.warehouseId = checkpoint['warehouseId'] as String?;
      row.done = checkpoint['done'] == true;
    }
    _pendingDocumentId = data['pendingDocumentId'] as String?;
    _uncertain = data['uncertain'] == true || formDraftHasUnknownSubmission;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load();
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(stockDocRepositoryProvider(StockDocType.wdraw));
      final details = await Future.wait(
        widget.documentIds.map((id) => repo.detail(id)),
      );
      if (!formDraftIdentityIsCurrent) return;
      final previous = {for (final row in _rows) row.detail.id: row};
      setState(() {
        _rows
          ..clear()
          ..addAll([
            for (final detail in details)
              _Row(detail)
                ..warehouseId =
                    previous[detail.id]?.warehouseId ??
                    _initialWarehouse(detail)
                ..done = previous[detail.id]?.done ?? false,
          ]);
      });
      await initializeFormDraft();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '退料单没有加载出来：${e.message}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '退料单没有加载出来，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 默认收料仓：单据自带仓在本主仓有效范围内就直接沿用，否则留空待选。
  String? _initialWarehouse(StockDocDetail detail) {
    final allowed = _allowedWarehouseIds(detail);
    final initial = detail.warehouseId;
    return initial != null && allowed.contains(initial) ? initial : null;
  }

  Set<String> _allowedWarehouseIds(StockDocDetail detail) {
    final hierarchy = ref.read(masterNameServiceProvider).warehouseHierarchy;
    final eligible = WarehouseSelection(
      hierarchy,
      use: WarehouseUse.goodIn,
    ).selectableIds;
    final mainId = detail.materialReturnMainWarehouseId;
    return hierarchy
        .where(
          (entry) =>
              mainId != null &&
              warehousesShareMain(hierarchy, mainId, entry.id),
        )
        .map((entry) => entry.id)
        .where(eligible.contains)
        .toSet();
  }

  bool get _allPicked =>
      _rows.isNotEmpty &&
      _rows.every((row) => row.done || row.warehouseId != null);

  Future<void> _submit() async {
    if (_saving || !_allPicked) return;
    if (!formDraftIdentityIsCurrent ||
        (!ref.read(isSuperAdminProvider) &&
            !ref
                .read(currentPermissionsProvider)
                .contains(Perm.stockDocApprove))) {
      return;
    }
    if (!_uncertain &&
        _rows.any(
          (row) =>
              !row.done &&
              !_allowedWarehouseIds(row.detail).contains(row.warehouseId),
        )) {
      context.appWarning('实际收料仓范围已变化，请重新选择；已填写内容保留');
      return;
    }
    setState(() => _saving = true);
    final repo = ref.read(stockDocRepositoryProvider(StockDocType.wdraw));
    try {
      var done = 0;
      _uncertain = true;
      await runFormDraftSubmission(() async {
        for (final row in _rows) {
          if (row.done) continue;
          if (!mounted ||
              !formDraftIdentityIsCurrent ||
              (!ref.read(isSuperAdminProvider) &&
                  !ref
                      .read(currentPermissionsProvider)
                      .contains(Perm.stockDocApprove))) {
            throw ApiException('SESSION_CHANGED', '身份或收料权限已变化，已成功收料保留，本次停止');
          }
          final warehouseId = row.warehouseId!;
          _pendingDocumentId = row.detail.id;
          await saveFormDraftNow();
          await repo.confirmMaterialReturn(
            row.detail.id,
            warehouseId: warehouseId,
            idempotencyKey: businessIdempotencyKey(
              'material-return-confirm',
              '${row.detail.id}|$warehouseId',
            ),
          );
          row.done = true;
          _pendingDocumentId = null;
          done++;
          await saveFormDraftNow();
        }
      });
      if (!mounted) return;
      _uncertain = false;
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess('已收料 $done 张退料单，库存与车间台账已更新');
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        backTo(context, defaultPath: RouteName.warehouseTasks);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError('${e.message}（已收成功的都保留了，重试只会补收还没收的单）');
      if (e.httpStatus == 400 ||
          e.httpStatus == 422 ||
          (e.httpStatus == 409 && e.code == 'CONFLICT')) {
        _uncertain = false;
        _pendingDocumentId = null;
        await saveFormDraftNow();
      }
    } catch (_) {
      if (!mounted) return;
      context.appError('批量收料中断，已收成功的都保留了；请稍后重试，重试只会补收还没收的单');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final canApprove =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.stockDocApprove);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '批量收料 · ${widget.documentIds.length} 张退料单',
          leading: const UtenBackButton(),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: _saving,
                child: UtenContentContainer.wide(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!),
                              const SizedBox(height: UtenSpacing.s8),
                              UtenButton(
                                onPressed: _load,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          itemCount: _rows.length,
                          itemBuilder: (context, index) {
                            final row = _rows[index];
                            final detail = row.detail;
                            final allowed = _allowedWarehouseIds(detail);
                            final scoped = names.warehouseHierarchy
                                .where((entry) => allowed.contains(entry.id))
                                .toList();
                            final billDate = detail.billDate ?? '';
                            return Card(
                              margin: const EdgeInsets.only(
                                bottom: UtenSpacing.s8,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          detail.billNo ?? detail.id,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(width: UtenSpacing.s8),
                                        Expanded(
                                          child: Text(
                                            '${billDate.length >= 10 ? billDate.substring(0, 10) : billDate} · '
                                            '${names.department(detail.departmentId)} · '
                                            '${detail.items.length} 行物料',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                        if (row.done)
                                          Text(
                                            '已收料',
                                            style: theme.textTheme.labelLarge
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: UtenSpacing.s8),
                                    UtenDropdownField(
                                      key: ValueKey(
                                        'material-return-batch-warehouse-${detail.id}',
                                      ),
                                      label: '实际收料仓库',
                                      required: true,
                                      allowClear: false,
                                      value: row.warehouseId,
                                      items: warehouseHierarchyItems(
                                        scoped,
                                        use: WarehouseUse.goodIn,
                                      ),
                                      info: '余料进入这里选择的正常仓库；来源记录用于追溯。',
                                      errorMessage:
                                          detail.materialReturnMainWarehouseId ==
                                              null
                                          ? '来源主仓还没读到，请刷新'
                                          : allowed.isEmpty
                                          ? '此主仓下暂无有效正常收料仓库'
                                          : null,
                                      enabled: !row.done && !_uncertain,
                                      onChanged: (value) => setState(() {
                                        if (row.done || _uncertain) return;
                                        row.warehouseId =
                                            allowed.contains(value)
                                            ? value
                                            : null;
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (Navigator.of(context).canPop()) {
                              Navigator.of(context).pop(false);
                            } else {
                              backTo(
                                context,
                                defaultPath: RouteName.warehouseTasks,
                              );
                            }
                          },
                    child: const Text('取消'),
                  ),
                  UtenButton(
                    key: const Key('material-return-batch-confirm'),
                    icon: Icons.move_to_inbox_rounded,
                    isLoading: _saving,
                    onPressed: _saving || !_allPicked || !canApprove
                        ? null
                        : _submit,
                    child: Text(
                      '确认批量收料(${_rows.where((r) => !r.done).length})',
                    ),
                  ),
                ],
              ),
              if (_saving) const UtenBusyOverlay(title: '正在批量收料'),
            ],
          ),
        ),
      ),
    );
  }
}
