// 委外目标件拣货出仓页（/warehouse/subcontract-outbound/:planId）。
//
// 与委外模块发料单编辑页分立设计（不复用、不跳转）：
//   - 全页无价格/金额/币种字段；
//   - 新流只展示服务端已放行的委外目标件，不在 Flutter 判断 BOM/生产/FQC/入仓；
//   - 本次出仓默认 = readyOutboundQty，可改小（分批出仓）；
//   - 发出仓必选、经办人默认当前登录人（默认部门仓储 SUB_WH）；
//   - 「审核出仓」确认弹明示效果：目标件出库 → 委外加工 → 回厂 IQC；
//   - LEGACY_BOM_COMPONENT 仅保留历史 BOM 子件发料兼容；
//   - 「不再出仓」关闭计划余量（必填原因）；无草稿时可「生成出仓草稿」。
// 数据走既有 /api/subcontract/material-issues 端点（数据通用），草稿 maker 为空时
// 服务端凭 subcontract_material_issue:edit 权限放行（V304 授权 SUB_WH）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../../shared/providers/session_provider.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../models/subcontract_outbound.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../providers/warehouse_count_refresh.dart';

class WarehouseSubcontractOutboundEditPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundEditPage({super.key, required this.planId});

  final String planId;

  @override
  ConsumerState<WarehouseSubcontractOutboundEditPage> createState() =>
      _WarehouseSubcontractOutboundEditPageState();
}

class _LineEdit {
  _LineEdit(
    this.line,
    this.draftItemId,
    String initialQty,
    String initialWeight,
  ) : qty = TextEditingController(text: initialQty),
      weight = TextEditingController(text: initialWeight);

  final OutboundPlanLine line;

  /// 草稿明细行 id（仅存引用，保存时以 planItemId/orderItemId 回传）。
  final String? draftItemId;
  final TextEditingController qty;
  final TextEditingController weight;

  void dispose() {
    qty.dispose();
    weight.dispose();
  }
}

class _WarehouseSubcontractOutboundEditPageState
    extends ConsumerState<WarehouseSubcontractOutboundEditPage> {
  final _remark = TextEditingController();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  OutboundTaskDetail? _detail;
  String? _draftId;
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliverDate;
  String? _warehouseId;
  String? _workerId;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<_LineEdit> _lines = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _remark.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(mn.masterNameServiceProvider).ensureLoaded();
      final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final detail = await repo.taskDetail(widget.planId);
      // 找未审草稿：有则载入草稿行（数量/表头），否则按计划行预填。
      OutboundDraftRef? draft;
      for (final d in detail.drafts) {
        if (d.status == 0) draft = d;
      }
      String? warehouseId;
      String? workerId;
      DateTime? deliverDate = _parseDate(detail.deliverDate);
      final remarkText = StringBuffer();
      final lines = <_LineEdit>[];
      if (draft != null) {
        final doc = await ref
            .read(
              subcontractRepositoryProvider(SubcontractDocType.materialIssue),
            )
            .detail(draft.issueId);
        _draftId = doc.id;
        warehouseId = doc.warehouseId;
        workerId = doc.workerId;
        deliverDate = _parseDate(doc.deliverDate) ?? deliverDate;
        if (doc.remark != null && doc.remark!.isNotEmpty) {
          remarkText.write(doc.remark);
        }
        if (doc.billDate != null) {
          final parsed = _parseDate(doc.billDate);
          if (parsed != null) _billDate = parsed;
        }
        // 草稿行 → 计划行（按 planItemId 对齐；草稿数量为本次出仓默认值）。
        final byPlanItem = <String, SubcontractDocItem>{
          for (final it in doc.items)
            if (it.planItemId != null) it.planItemId!: it,
        };
        for (final line in detail.lines) {
          final draftLine = byPlanItem[line.planItemId];
          if (draftLine == null) continue;
          final initial = draftLine.qty ?? 0;
          lines.add(
            _LineEdit(
              line,
              draftLine.id,
              _fmtQty(initial),
              draftLine.weight?.toString() ?? '',
            ),
          );
        }
      } else {
        for (final line in detail.lines) {
          if (line.readyOutboundQty <= 0) continue;
          lines.add(_LineEdit(line, null, _fmtQty(line.readyOutboundQty), ''));
        }
      }
      // 经办人默认当前登录人。
      workerId ??= ref.read(sessionProvider).user?.employeeId;
      _remark.text = remarkText.toString();
      await _preloadEmployees([workerId]);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _warehouseId = warehouseId;
        _workerId = workerId;
        _deliverDate = deliverDate;
        for (final old in _lines) {
          old.dispose();
        }
        _lines = lines;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '出仓任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          _empCache[id] = UtenEmployeePickerItem(
            id: p.id,
            name: p.fullName ?? '',
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  /// 保存（或新建）出仓草稿；返回草稿 id。数量校验：>0 且 ≤ 该行剩余量。
  Future<String?> _saveDraft({required bool silent}) async {
    final detail = _detail;
    if (detail == null) return null;
    if (_warehouseId == null) {
      context.appError('请选择发出仓');
      return null;
    }
    final items = <Map<String, dynamic>>[];
    for (final e in _lines) {
      final qty = double.tryParse(e.qty.text.trim()) ?? -1;
      final maxQty = e.line.maxEditableQty;
      final name = e.line.goodsName ?? e.line.goodsCode ?? '该目标件';
      if (qty <= 0) {
        context.appError('$name 的本次出仓量必须大于 0');
        return null;
      }
      if (qty > maxQty + 0.0001) {
        context.appError('$name 的本次出仓量不能超过计划剩余量 ${_fmtQty(maxQty)}');
        return null;
      }
      final weightText = e.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('$name 的实际重量必须大于 0');
        return null;
      }
      items.add(e.line.toMaterialIssueItemPayload(qty: qty, weight: weight));
    }
    if (items.isEmpty) {
      context.appError('出仓明细为空');
      return null;
    }
    final body = <String, dynamic>{
      'billDate':
          '${_billDate.year}-${_billDate.month.toString().padLeft(2, '0')}-${_billDate.day.toString().padLeft(2, '0')}',
      // 委外商随草稿来源（订货单）固定，防改坏来源关联。
      'supplierId': detail.supplierId,
      'warehouseId': _warehouseId,
      if (_workerId != null) 'workerId': _workerId,
      if (_deliverDate != null)
        'deliverDate':
            '${_deliverDate!.year}-${_deliverDate!.month.toString().padLeft(2, '0')}-${_deliverDate!.day.toString().padLeft(2, '0')}',
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'items': items,
    };
    final repo = ref.read(
      subcontractRepositoryProvider(SubcontractDocType.materialIssue),
    );
    if (_draftId != null) {
      await repo.update(_draftId!, body);
      return _draftId;
    }
    // 无草稿（红冲后补发等）：先经工作台按计划余量重建草稿，再写入表头/数量。
    final newDraftId = await ref
        .read(warehouseSubcontractOutboundRepositoryProvider)
        .regenerateDraft(widget.planId);
    await repo.update(newDraftId, body);
    return newDraftId;
  }

  Future<void> _onSave() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final id = await _saveDraft(silent: false);
      if (!mounted) return;
      if (id != null) {
        invalidateWarehouseTaskCounts(ref);
        context.appSuccess('出仓草稿已保存');
        context.pop(true);
      }
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onApprove() async {
    if (_saving) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '审核出仓确认',
      confirmLabel: '确认出仓',
      actionLabel: '委外目标件出仓审核',
      responsibilityDescription: '确认后，系统将以此登录员工记录本次委外目标件出仓审核责任。',
      message:
          '审核后将：\n'
          '① 已放行的委外目标件从所选仓库出库，交委外商加工；\n'
          '② 有子层级的目标件必须已经完成前置自制、FQC 和成品入仓，本页不能绕过；\n'
          '③ 加工完成回厂后仍需登记回仓、品质检查，合格后才正式入仓。',
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      final id = await _saveDraft(silent: true);
      if (id == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.materialIssue))
          .approve(id);
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('委外目标件出仓已审核，可交委外商加工');
      context.pop(true);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('审核失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onClosePlan() async {
    final reasonCtl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('不再出仓'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('关闭后本计划的剩余量不再出仓(委外商料已够/订单变更等)。该操作会留痕。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: reasonCtl,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '关闭原因(必填)',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (reasonCtl.text.trim().isEmpty) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('确认关闭'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(warehouseSubcontractOutboundRepositoryProvider)
          .closePlan(widget.planId, reasonCtl.text.trim());
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('已关闭剩余出仓计划');
      context.pop(true);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('关闭失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外拣货出仓',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: '/warehouse/subcontract-outbound'),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : detail == null
            ? const UtenEmpty(message: '出仓任务不存在')
            : _buildBody(detail),
      ),
    );
  }

  Widget _buildBody(OutboundTaskDetail detail) {
    final names = ref.watch(mn.masterNameServiceProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final openWithLines = detail.status == 'OPEN' && _lines.isNotEmpty;
    final canExecute = permissions.contains(Perm.subcontractOutboundExecute);
    final canEdit =
        openWithLines &&
        canExecute &&
        permissions.contains(Perm.subcontractMaterialIssueEdit);
    final canApprove =
        openWithLines &&
        canExecute &&
        permissions.contains(Perm.subcontractMaterialIssueApprove);
    final canClose =
        detail.status == 'OPEN' &&
        permissions.contains(Perm.subcontractOutboundClose);
    return UtenContentContainer.narrow(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: [
          // —— 表头信息（订货单/委外商只读，防改坏来源关联）——
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HeadLine(label: '委外订货单', value: detail.orderBillNo ?? '—'),
                  _HeadLine(label: '委外商', value: detail.supplierName ?? '—'),
                  _HeadLine(
                    label: '计划状态',
                    value: switch (detail.status) {
                      'OPEN' => '出仓中',
                      'CLOSED' => '已关闭(不再出仓)',
                      'CANCELED' => '已取消(订货已红冲)',
                      _ => detail.status ?? '—',
                    },
                  ),
                  if (detail.closeReason != null)
                    _HeadLine(label: '关闭原因', value: detail.closeReason!),
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (canEdit) ...[
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: UtenFormGrid(
                  children: [
                    UtenDateField(
                      label: '出仓日期',
                      required: true,
                      value: _billDate,
                      onChanged: (d) => setState(() => _billDate = d),
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey('warehouse_$_warehouseId'),
                      initialValue: _warehouseId,
                      decoration: const InputDecoration(labelText: '发出仓(必选)'),
                      items: [
                        for (final e in names.warehouseEntries.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _warehouseId = v),
                    ),
                    UtenEmployeePicker(
                      key: ValueKey('worker_$_workerId'),
                      label: '经办人',
                      hint: '请选择经办人',
                      sheetTitle: '选择经办人',
                      initial: _workerId == null ? null : _empCache[_workerId],
                      loader: (kw) async {
                        final deptId = (kw == null || kw.isEmpty)
                            ? (ref
                                      .read(departmentCodeIdMapProvider)
                                      .valueOrNull ??
                                  const {})['SUB_WH']
                            : null;
                        final res = await ref
                            .read(employeeRepositoryProvider)
                            .list(
                              size: 30,
                              search: kw,
                              departmentId: deptId,
                              includeSubtree: true,
                            );
                        return [
                          for (final e in res.items)
                            UtenEmployeePickerItem(
                              id: e.id,
                              name: e.fullName,
                              employeeCode: e.code,
                              departmentName: e.departmentName,
                            ),
                        ];
                      },
                      onChanged: (item) {
                        if (item != null) _empCache[item.id] = item;
                        setState(() => _workerId = item?.id);
                      },
                    ),
                    UtenDateField(
                      label: '交货日期',
                      value: _deliverDate ?? ChinaDateTime.today(),
                      onChanged: (d) => setState(() => _deliverDate = d),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          // —— 目标件（服务端已放行数量/已出仓/本次出仓；无价格字段）——
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '委外目标件出仓明细',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  if (_lines.isEmpty)
                    Text(
                      '当前没有服务端放行的可出仓目标件',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    for (final e in _lines) _buildLineEditor(e, canEdit),
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (canEdit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
              child: TextField(
                controller: _remark,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: '备注',
                  alignLabelWithHint: true,
                ),
              ),
            ),
          if (detail.drafts.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '出仓记录',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    for (final d in detail.drafts)
                      Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s8),
                        child: Row(
                          children: [
                            Icon(
                              d.status == 1
                                  ? Icons.check_circle_outline
                                  : d.status == 0
                                  ? Icons.pending_actions_outlined
                                  : Icons.undo_rounded,
                              size: 16,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Expanded(
                              child: Text(
                                '${d.billNo ?? '—'} · ${_fmtQty(d.totalQty ?? 0)}'
                                '${d.warehouseName != null ? ' · ${d.warehouseName}' : ''}'
                                '${d.approverName != null ? ' · ${d.approverName}' : ''}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Text(
                              switch (d.status) {
                                1 => '已出仓',
                                0 => '草稿',
                                _ => '已红冲',
                              },
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s20),
          if (canEdit || canApprove)
            Row(
              children: [
                if (canEdit)
                  Expanded(
                    child: UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.save_outlined,
                      isLoading: _saving,
                      onPressed: _saving ? null : _onSave,
                      child: const Text('保存草稿'),
                    ),
                  ),
                if (canEdit && canApprove)
                  const SizedBox(width: UtenSpacing.s12),
                if (canApprove)
                  Expanded(
                    flex: 2,
                    child: UtenButton(
                      icon: Icons.outbound_rounded,
                      isLoading: _saving,
                      onPressed: _saving ? null : _onApprove,
                      child: const Text('审核出仓'),
                    ),
                  ),
              ],
            ),
          if (canClose) ...[
            const SizedBox(height: UtenSpacing.s12),
            Center(
              child: TextButton.icon(
                onPressed: _saving ? null : _onClosePlan,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('不再出仓(关闭剩余计划)'),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s24),
        ],
      ),
    );
  }

  Widget _buildLineEditor(_LineEdit e, bool canEdit) {
    final theme = Theme.of(context);
    final line = e.line;
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${line.goodsCode ?? ''} ${line.goodsName ?? ''}'.trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                if (line.flowMode ==
                    SubcontractOutboundFlowMode.legacyBomComponent)
                  Text(
                    '历史父件 ${line.parentGoodsCode ?? ''} ${line.parentGoodsName ?? ''}'
                        .trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Text(
                    '${line.flowMode.label} · ${line.preparationStatus.label}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                Text(
                  line.flowMode ==
                          SubcontractOutboundFlowMode.legacyBomComponent
                      ? '历史单耗 ${_fmtQty(line.bomUnitQty)}'
                            '${line.unitName != null ? ' ${line.unitName}' : ''}'
                            '${line.goodsStockPlace != null ? ' · 库位 ${line.goodsStockPlace}' : ''}'
                            ' · 计划 ${_fmtQty(line.plannedQty)} / 已出仓 ${_fmtQty(line.issuedQty)}'
                      : '目标件总量 ${_fmtQty(line.plannedQty)}'
                            ' · 已完成前置自制 ${_fmtQty(line.preparedQty)}'
                            ' · 当前可出 ${_fmtQty(line.readyOutboundQty)}'
                            ' · 已出仓 ${_fmtQty(line.issuedQty)}'
                            '${line.goodsStockPlace != null ? ' · 库位 ${line.goodsStockPlace}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(
            width: 140,
            child: TextField(
              controller: e.qty,
              enabled: canEdit,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}')),
              ],
              decoration: InputDecoration(
                labelText: '本次出仓',
                helper: UtenFieldMessage.helper(
                  '本次最多 ${_fmtQty(line.maxEditableQty)}',
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 120,
            child: TextField(
              controller: e.weight,
              enabled: canEdit,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}')),
              ],
              decoration: const InputDecoration(
                labelText: '实际重量',
                hintText: '可选',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadLine extends StatelessWidget {
  const _HeadLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        children: [
          Text(
            '$label：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
