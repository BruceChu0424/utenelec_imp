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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/providers/session_provider.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../models/subcontract_outbound.dart';
import '../models/subcontract_outbound_execution.dart';
import '../widgets/subcontract_outbound_detail_table.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../repositories/subcontract_outbound_detail_loader.dart';
import '../navigation/warehouse_subcontract_outbound_navigation.dart';
import '../providers/warehouse_count_refresh.dart';
import 'warehouse_subcontract_outbound_batch_page.dart';

/// 批量校验提示：把同一类违规的**全部**行汇总成一句话。
///
/// 条目多时只列前 8 条再折成「等 N 行」——刷屏的提示和只报第一行一样没法用。
/// [issue] 可直接传 l10n 整句，故先去掉句末句号再接后半句。
String _rowIssueMessage(
  List<String> rowLabels,
  String issue, {
  required String action,
}) {
  const shownMax = 8;
  final shown = rowLabels.take(shownMax).join('、');
  final more = rowLabels.length > shownMax ? '等 ${rowLabels.length} 行' : '';
  final text = issue.replaceFirst(RegExp(r'[。.]$'), '');
  return '以下 ${rowLabels.length} 行$text，$action：$shown$more';
}

class WarehouseSubcontractOutboundEditPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundEditPage({super.key, required this.planId});

  final String planId;

  @override
  ConsumerState<WarehouseSubcontractOutboundEditPage> createState() =>
      _WarehouseSubcontractOutboundEditPageState();
}

class _WarehouseSubcontractOutboundEditPageState
    extends ConsumerState<WarehouseSubcontractOutboundEditPage> {
  final _remark = TextEditingController();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  OutboundTaskDetail? _detail;
  String? _draftId;
  SubcontractDocDetail? _draftDocument;
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliverDate;
  String? _warehouseId;
  String? _workerId;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _requiresReload = false;
  bool _requestUncertain = false;
  bool _writeStarted = false;
  bool _generatedDrafts = false;
  bool _showAllDrafts = false;
  List<SubcontractOutboundReadBundle>? _initialBundles;
  int _loadGeneration = 0;
  String? _error;
  List<SubcontractOutboundLineDraft> _lines = const [];

  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

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
    if (_requestUncertain) {
      await _verifyExecution();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final generation = ++_loadGeneration;
    try {
      final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final docRepo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      final results = await Future.wait([
        ref.read(mn.masterNameServiceProvider).ensureWarehousesLoaded(),
        loadSubcontractOutboundDetails(
          planIds: [widget.planId],
          taskDetail: repo.taskDetail,
          documentDetail: docRepo.detail,
        ),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final bundles = results[1] as List<SubcontractOutboundReadBundle>;
      final bundle = bundles.single;
      final detail = bundle.task;
      if (bundle.documents.length > 1) {
        if (mounted) {
          setState(() {
            _initialBundles = bundles;
            _showAllDrafts = true;
            _loading = false;
          });
        }
        return;
      }
      _draftId = null;
      _draftDocument = null;
      // 找未审草稿：有则载入草稿行（数量/表头），否则按计划行预填。
      OutboundDraftRef? draft;
      for (final d in detail.drafts) {
        if (d.status == 0) draft = d;
      }
      String? warehouseId;
      String? workerId;
      DateTime? deliverDate = _parseDate(detail.deliverDate);
      final remarkText = StringBuffer();
      final lines = <SubcontractOutboundLineDraft>[];
      if (draft != null) {
        final doc = bundle.documents.single;
        _draftId = doc.id;
        _draftDocument = doc;
        if (doc.status != 0) {
          throw ApiException(
            'CONFLICT',
            _l10n.warehouseSubcontractOutboundChanged,
            httpStatus: 409,
          );
        }
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
            SubcontractOutboundLineDraft(
              line,
              draftLine.id,
              _fmtQty(initial),
              draftLine.weight?.toString() ?? '',
              remark: draftLine.remark,
              unitRate: draftLine.unitRate,
            ),
          );
        }
        if (lines.length != doc.items.length) {
          for (final line in lines) {
            line.dispose();
          }
          throw ApiException(
            'CONFLICT',
            _l10n.warehouseSubcontractOutboundChanged,
            httpStatus: 409,
          );
        }
      } else {
        for (final line in detail.lines) {
          if (line.readyOutboundQty <= 0) continue;
          lines.add(
            SubcontractOutboundLineDraft(
              line,
              null,
              _fmtQty(line.readyOutboundQty),
              '',
            ),
          );
        }
      }
      // 经办人默认当前登录人。
      final user = ref.read(sessionProvider).user;
      workerId ??= user?.employeeId;
      if (workerId != null &&
          workerId == user?.employeeId &&
          user!.name.isNotEmpty) {
        _empCache[workerId] = UtenEmployeePickerItem(
          id: workerId,
          name: user.name,
          departmentName: user.department,
        );
      }
      _remark.text = remarkText.toString();
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
        _requiresReload = false;
      });
      unawaited(_preloadEmployees([workerId], generation));
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

  Future<void> _preloadEmployees(Iterable<String?> ids, int generation) async {
    final uniq = ids
        .whereType<String>()
        .where((id) => id.isNotEmpty && !_empCache.containsKey(id))
        .toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          if (!mounted || generation != _loadGeneration) return;
          setState(
            () => _empCache[id] = UtenEmployeePickerItem(
              id: p.id,
              name: p.fullName ?? '',
              employeeCode: p.code,
              departmentName: p.departmentName,
            ),
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
    if (_warehouseId == null ||
        (_warehouseId != _draftDocument?.warehouseId &&
            !WarehouseSelection(
              ref.read(mn.masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(_warehouseId))) {
      context.appError('请选择发出仓');
      return null;
    }
    // 明细整表扫完再报：原先首个违规就 return，多行时用户改一行存一次才看到下一行，
    // 观感像「怎么老是报错」。判定条件与逐行先后顺序不变，只把问题按类别各汇总成一条。
    final items = <Map<String, dynamic>>[];
    final badQty = <String>[];
    final overMaxQty = <String>[];
    final badWeight = <String>[];
    for (var index = 0; index < _lines.length; index++) {
      final e = _lines[index];
      final qty = double.tryParse(e.qty.text.trim()) ?? -1;
      final maxQty = e.maxEditableQty;
      final name = e.line.goodsName ?? e.line.goodsCode ?? '该目标件';
      final label = '第 ${index + 1} 行（$name）';
      if (!qty.isFinite || qty <= 0) {
        badQty.add(label);
        continue;
      }
      if (qty - maxQty > 0.0000001) {
        overMaxQty.add(label);
        continue;
      }
      final weightText = e.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty &&
          (weight == null || !weight.isFinite || weight <= 0)) {
        badWeight.add(label);
        continue;
      }
      items.add(e.toPayload());
    }
    final rowIssues = <String>[
      if (badQty.isNotEmpty)
        _rowIssueMessage(badQty, '的本次出仓量不是大于 0 的数字', action: '请改正后再提交'),
      if (overMaxQty.isNotEmpty)
        // 超量沿用明细表 validate 的同一句 l10n 文案，口径不分叉。
        _rowIssueMessage(
          overMaxQty,
          _l10n.warehouseSubcontractOutboundQuantityInvalid,
          action: '请改小后再提交',
        ),
      if (badWeight.isNotEmpty)
        _rowIssueMessage(badWeight, '的实际重量必须大于 0', action: '请改正后再提交'),
    ];
    if (rowIssues.isNotEmpty) {
      // 不同类别分行列出，混成一句会让人看不清到底要改哪几处。
      context.appError(rowIssues.join('\n'));
      return null;
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
      final fresh = await repo.detail(_draftId!);
      if (_draftDocument == null ||
          subcontractOutboundDraftFingerprint(fresh) !=
              subcontractOutboundDraftFingerprint(_draftDocument!)) {
        _requiresReload = true;
        throw ApiException(
          'CONFLICT',
          _l10n.warehouseSubcontractOutboundChanged,
          httpStatus: 409,
        );
      }
      _writeStarted = true;
      _draftDocument = await repo.update(_draftId!, body);
      return _draftId;
    }
    // 无草稿（红冲后补发等）：先经工作台按计划余量重建草稿，再写入表头/数量。
    _writeStarted = true;
    final newDraftId = await ref
        .read(warehouseSubcontractOutboundRepositoryProvider)
        .regenerateDraft(widget.planId);
    _draftId = newDraftId;
    _draftDocument = await repo.detail(newDraftId);
    // Generation may split the plan into several actual-warehouse drafts.
    // Return to review the generated documents before any update or approval.
    _requiresReload = true;
    _generatedDrafts = true;
    if (mounted) {
      context.appInfo(_l10n.warehouseSubcontractOutboundDraftsGenerated);
    }
    return null;
  }

  Future<void> _onSave() async {
    if (_saving || _confirming || _requiresReload) return;
    _writeStarted = false;
    setState(() => _saving = true);
    try {
      final id = await _saveDraft(silent: false);
      if (!mounted) return;
      if (_generatedDrafts) {
        await _reviewGeneratedDrafts();
        return;
      }
      if (id != null) {
        invalidateWarehouseTaskCounts(ref);
        context.appSuccess('出仓草稿已保存');
        context.pop(true);
      }
    } on ApiException catch (error) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain =
            _writeStarted &&
            (error.httpStatus == null || error.httpStatus! >= 500);
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain = _writeStarted;
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onApprove() async {
    if (_saving || _confirming || _requiresReload) return;
    _writeStarted = false;
    setState(() => _confirming = true);
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
    if (!confirmed || !mounted) {
      if (mounted) setState(() => _confirming = false);
      return;
    }
    setState(() {
      _confirming = false;
      _saving = true;
    });
    try {
      final id = await _saveDraft(silent: true);
      if (id == null) {
        if (mounted) setState(() => _saving = false);
        if (mounted && _generatedDrafts) await _reviewGeneratedDrafts();
        return;
      }
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      final fresh = await repo.detail(id);
      if (subcontractOutboundDraftFingerprint(fresh) !=
          subcontractOutboundDraftFingerprint(_draftDocument!)) {
        throw ApiException(
          'CONFLICT',
          _l10n.warehouseSubcontractOutboundChanged,
          httpStatus: 409,
        );
      }
      _writeStarted = true;
      final approved = await repo.approve(id);
      if (approved.status != 1) {
        throw ApiException(
          'UNKNOWN_RECEIPT',
          _l10n.warehouseSubcontractOutboundUncertain,
        );
      }
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('委外目标件出仓已审核，可交委外商加工');
      returnToSubcontractOutboundTasks(context);
    } on ApiException catch (error) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain =
            _writeStarted &&
            (error.httpStatus == null || error.httpStatus! >= 500);
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain = _writeStarted;
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reviewGeneratedDrafts() async {
    setState(() {
      _saving = false;
      _generatedDrafts = false;
      _showAllDrafts = true;
      _initialBundles = null;
    });
  }

  Future<void> _verifyExecution() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (_draftId != null) {
        final doc = await ref
            .read(
              subcontractRepositoryProvider(SubcontractDocType.materialIssue),
            )
            .detail(_draftId!);
        if (doc.status == 1 && mounted) {
          invalidateWarehouseTaskCounts(ref);
          context.appSuccess(_l10n.warehouseSubcontractOutboundDone);
          returnToSubcontractOutboundTasks(context);
          return;
        }
      }
      if (mounted) {
        context.appWarning(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) {
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
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
    if (_showAllDrafts) {
      return WarehouseSubcontractOutboundBatchPage(
        planIds: [widget.planId],
        initialBundles: _initialBundles,
        onCompleted: () => returnToSubcontractOutboundTasks(context),
      );
    }
    final detail = _detail;
    return PopScope(
      canPop: !_saving && !_confirming,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '委外拣货出仓',
          leading: UtenBackButton(
            onPressed: _saving || _confirming
                ? null
                : () => backTo(
                    context,
                    defaultPath: '/warehouse/subcontract-outbound',
                  ),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : _error != null
                    ? UtenEmpty.error(
                        message: _error,
                        actionLabel: '重新加载',
                        onAction: _load,
                      )
                    : detail == null
                    ? const UtenEmpty(message: '出仓任务不存在')
                    : AbsorbPointer(
                        absorbing: _saving || _confirming,
                        child: _buildBody(detail),
                      ),
              ),
            ),
            if (_saving)
              Positioned.fill(
                child: UtenBusyOverlay(title: _l10n.commonLoading),
              ),
          ],
        ),
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
        canEdit && permissions.contains(Perm.subcontractMaterialIssueApprove);
    final canClose =
        detail.status == 'OPEN' &&
        permissions.contains(Perm.subcontractOutboundClose);
    return UtenContentContainer.wide(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: [
          if (_requiresReload) ...[
            Text(_l10n.warehouseSubcontractOutboundUncertain),
            UtenButton(
              type: UtenButtonType.secondary,
              isLoading: _loading,
              onPressed: _saving || _loading ? null : _load,
              child: Text(_l10n.warehouseSubcontractOutboundVerify),
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
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
                    // V476：主/子层级（父仓置灰分组，出仓落具体仓）。
                    WarehouseHierarchyDropdown(
                      key: ValueKey('warehouse_$_warehouseId'),
                      entries: names.warehouseHierarchy,
                      value: _warehouseId,
                      labelText: '发出仓(必选)',
                      onChanged: (v) {
                        if (v != null) setState(() => _warehouseId = v);
                      },
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
                    SubcontractOutboundDetailTable(
                      rows: [
                        for (final line in _lines)
                          SubcontractOutboundTableRow(
                            draft: line,
                            warehouse: names.warehouse(_warehouseId),
                          ),
                      ],
                      editable: canEdit && !_saving,
                      onChanged: () => setState(() {}),
                    ),
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
                      onPressed: _saving || _requiresReload ? null : _onSave,
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
                      type: UtenButtonType.danger,
                      size: UtenButtonSize.large,
                      isLoading: _saving,
                      onPressed: _saving || _requiresReload ? null : _onApprove,
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
