// 预计到货工作台（可嵌入）：与财务「订货审批任务中心」同款表格工作台——列表只放
// 单据级概要（单号/供应商/数量/预计到货日/步骤），双击行按当前步骤直达对应办理
// 页（待登记→登记实际到货；已登记→继续送检；超量→到货异常；已送检→品质检查
// 结果），不再经过中间详情页（2026-09-05 用户口径：不要两步操作）。
//
// 2026-09-01 起「入库任务中心」采购入库/委外入库分段内嵌本组件（fixedOrderType
// 固定来源、embedded=true 不渲染自己的类型分段与搜索框——关键字由任务中心页级
// 工具条统一下发）；独立路由 /warehouse/inbound/expectations 由对应页面以
// embedded=false 包一层继续承接（委外模块卡片深链依赖它）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/session_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

class WarehouseInboundExpectationsView extends ConsumerStatefulWidget {
  const WarehouseInboundExpectationsView({
    super.key,
    this.fixedOrderType,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
  });

  /// 任务中心分段固定的订货来源（采购入库=PURCHASE / 委外入库=SUBCONTRACT）；
  /// null = 独立页模式（自带类型分段）。
  final ProcurementInboundOrderType? fixedOrderType;

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在任务中心分段内（无类型分段与搜索框，仅提示行 + 表格）。
  final bool embedded;

  @override
  ConsumerState<WarehouseInboundExpectationsView> createState() =>
      _WarehouseInboundExpectationsViewState();
}

class _WarehouseInboundExpectationsViewState
    extends ConsumerState<WarehouseInboundExpectationsView> {
  PagedResult<InboundExpectation>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  /// 类型筛选（表头筛选与类型分段按钮共用这一个口径）：null = 全部待到货。
  /// 进页面不预选（不选=不过滤），点分段后才算选中；任务中心嵌入时由
  /// [WarehouseInboundExpectationsView.fixedOrderType] 固定。
  ProcurementInboundOrderType? _orderType;
  bool _typeSelected = false;

  /// 按类型计数（后端全量口径）；null = 尚未返回，分段按钮显示 '—'。
  Map<String, int>? _typeCounts;

  /// 搜索关键字（订货单号/供应商/货品编码或名称），UtenSearchBar 300ms 防抖后回写。
  String _keyword = '';

  /// 已送检待品质放行的收货单张数（口径提示用；null = 尚未返回或无查看权限）。
  int? _inspectionPendingCount;

  /// 批量送检多选（与到货异常批量入库同款选择指纹幂等键范式）。
  /// 必须是可变 Set：_load 里会对它 removeWhere 清理失效选择，
  /// const Set 在 Web 上无条件抛「Cannot modify constant Set」。
  Set<String> _selectedIds = <String>{};
  bool _batchSending = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

  /// 品质待检计数仅对有查看权限者拉取（服务端接口独立鉴权兜底）。
  bool get _canViewInspection =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.procurementInspectionView);

  @override
  void initState() {
    super.initState();
    _orderType = widget.fixedOrderType;
    _typeSelected = widget.fixedOrderType != null;
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(1);
    });
  }

  @override
  void didUpdateWidget(WarehouseInboundExpectationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.fixedOrderType != widget.fixedOrderType) {
      _keyword = widget.keyword;
      if (oldWidget.fixedOrderType != widget.fixedOrderType) {
        _orderType = widget.fixedOrderType;
        _typeSelected = widget.fixedOrderType != null;
        _selectedIds.clear();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(1);
      });
    }
  }

  /// 当前筛选口径的提示文案（与财务审批任务中心同款：说明放工具条下方整行提示）。
  String get _scopeHint {
    final base = switch (_orderType) {
      ProcurementInboundOrderType.purchase => '只显示财务已批准、可准备收货的采购订货单。',
      ProcurementInboundOrderType.subcontract => '只显示目标件已经真实委外出仓、可能回厂的委外订货单。',
      _ => '采购在财务批准后显示；委外必须先完成目标件真实出仓，才进入预计到货。',
    };
    const selection =
        '双击行直达下一步（待登记→登记实际到货）；'
        '多选「批量登记送检」：待登记行进批量登记页（实收+行级入库仓库），'
        '已登记 · 待送检行直接送检。';
    if (_orderType != null) return '$base$selection';
    final pending = _inspectionPendingCount;
    if (pending == null) {
      return '$base$selection'
          '已送检任务移交品质部；检查进度与结果请在「品质部检查结果」页查看。';
    }
    return '$base$selection'
        '另有 $pending 张已送检等待品质结果；'
        '检查进度与结果请在「品质部检查结果」页查看。';
  }

  void _selectType(ProcurementInboundOrderType? type) {
    if (_orderType == type && _typeSelected) return;
    setState(() {
      _orderType = type;
      _typeSelected = true;
      _selectedIds = <String>{};
    });
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (_keyword == normalized) return;
    setState(() {
      _keyword = normalized;
      _selectedIds = <String>{};
    });
    _load(1);
  }

  void _setSelectedIds(Set<String> next) {
    setState(() => _selectedIds = next);
  }

  /// 「已登记 · 待送检」断点行（挂有草稿收货单）与「待登记」行都可多选：
  /// 2026-09-05「登记并送检」一步化后断点行基本不再出现，只放开断点行会让
  /// 多选形同虚设（用户口径：任务中心要能多选批量送检）。待登记行走
  /// 批量登记页（实收数量+行级入库仓库必填），断点行直接批量送检。
  bool _canBatchOperate(InboundExpectation expectation) =>
      _canBatchSend(expectation) || expectation.canCreateReceipt;

  /// 「已登记 · 待送检」且挂有草稿收货单的任务才可走既有批量送检通道。
  bool _canBatchSend(InboundExpectation expectation) =>
      expectation.arrivalStep == InboundArrivalStep.draftPendingInspection &&
      expectation.draftReceiptIds.isNotEmpty;

  bool get _canBatchSendAny {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.warehouseInboundStockIn);
  }

  String _batchKey(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final fingerprint = sorted.join('|');
    if (_batchSelectionFingerprint != fingerprint ||
        _batchIdempotencyKey == null) {
      _batchSelectionFingerprint = fingerprint;
      _batchIdempotencyKey = 'arrival-batch-complete-${const Uuid().v4()}';
    }
    return _batchIdempotencyKey!;
  }

  /// 多选「批量登记送检」编排：待登记行进批量登记页（实收+行级入库仓库），
  /// 断点「已登记 · 待送检」行直接批量送检（既有 batch-complete 通道）。
  /// 单张超量隔离不回滚其他单（与单册「继续送检」口径一致）。
  Future<void> _batchRegisterAndSend(Set<String> selectedIds) async {
    if (_batchSending || selectedIds.isEmpty) {
      if (selectedIds.isEmpty) {
        context.appWarning('请先选择预计到货任务');
      }
      return;
    }
    final currentItems = _result?.items ?? const <InboundExpectation>[];
    final selected = currentItems
        .where((task) => selectedIds.contains(task.id))
        .toList(growable: false);
    if (selected.length != selectedIds.length ||
        selected.any((task) => !_canBatchOperate(task))) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final drafts = selected.where(_canBatchSend).toList(growable: false);
    final ready = selected
        .where((task) => !drafts.contains(task))
        .toList(growable: false);
    // 1) 断点草稿单：确认后一个事务逐张送检（同幂等键安全重放）。
    if (drafts.isNotEmpty) {
      final receiptIds = [for (final task in drafts) ...task.draftReceiptIds];
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('批量送检 ${drafts.length} 张'),
          content: Text(
            '将把 ${receiptIds.length} 张已登记的草稿收货单一键送品质部待检(IQC)：'
            '检验合格后转仓库待入库任务，仓库确认实物与库位后库存才增加。'
            '实到超过财务批准量的单会自动隔离并通知财务审核组，不会入库、不会生成应付，'
            '也不影响其余单继续送检。单价按订货单自动带入，无需填写。',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('确认批量送检'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _batchSending = true);
      try {
        final result = await ref
            .read(procurementInboundRepositoryProvider)
            .batchCompleteArrivals(
              receiptIds: receiptIds,
              idempotencyKey: _batchKey(
                selectedIds
                    .where((id) => drafts.any((task) => task.id == id))
                    .toSet(),
              ),
            );
        if (!mounted) return;
        invalidateWarehouseTaskCounts(ref);
        final quarantined = result.items
            .where(
              (item) =>
                  item.outcome ==
                  WarehouseArrivalRegistrationOutcome.excessQuarantined,
            )
            .length;
        final replayed = result.items
            .where((item) => item.alreadyCompleted)
            .length;
        final message = StringBuffer(
          quarantined > 0
              ? '已批量送检 ${result.processedCount - quarantined} 张；'
                    '$quarantined 张实到超量已隔离，待财务在「到货异常」定案'
              : '已批量送检 ${result.processedCount} 张收货单',
        );
        if (replayed > 0) message.write('（其中 $replayed 张此前已处理，安全重放）');
        message.write('；检查进度与结果请在「品质部检查结果」页查看');
        quarantined > 0
            ? context.appWarning(message.toString())
            : context.appSuccess(message.toString());
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
        return;
      } catch (_) {
        if (mounted) context.appError('批量送检失败，请保持当前选择后重试');
        return;
      } finally {
        if (mounted) setState(() => _batchSending = false);
      }
    }
    if (!mounted) return;
    // 2) 待登记行：进批量登记页（实收数量默认=批准剩余，入库仓库行级必填）。
    if (ready.isNotEmpty) {
      final prefills = <ProcurementReceiptPrefill>[];
      for (final task in ready) {
        final prefill = task.toReceiptPrefill();
        if (prefill == null) {
          context.appWarning('部分所选任务已不可登记，请刷新后重新选择');
          return;
        }
        prefills.add(prefill);
      }
      final batch = await context.push<WarehouseArrivalRegistrationBatch>(
        RouteName.warehouseArrivalReceiptBatch,
        extra: prefills,
      );
      if (!mounted) return;
      if (batch != null) _announceRegistration(batch);
    }
    setState(() => _selectedIds = <String>{});
    _batchSelectionFingerprint = null;
    _batchIdempotencyKey = null;
    await _load(_result?.page ?? 1);
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0
            ? '多选预计到货任务：待登记行进批量登记页，已登记行直接送检'
            : '待登记行进批量登记页（实收+行级入库仓库）；已登记行一个事务逐张送检；超量单自动隔离待财务',
        child: UtenButton(
          key: const Key('inbound-expectation-batch-send-inspection'),
          size: UtenButtonSize.large,
          type: UtenButtonType.danger,
          icon: Icons.fact_check_outlined,
          isLoading: _batchSending,
          onPressed: _batchSending || count == 0
              ? null
              : () => _batchRegisterAndSend(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择预计到货任务')
              : null,
          child: Text(count == 0 ? '批量登记送检' : '批量登记送检($count)'),
        ),
      ),
    ];
  }

  int? _typeCount(ProcurementInboundOrderType type) {
    final counts = _typeCounts;
    if (counts == null) return null;
    return switch (type) {
      ProcurementInboundOrderType.purchase => counts['PURCHASE'] ?? 0,
      ProcurementInboundOrderType.subcontract => counts['SUBCONTRACT'] ?? 0,
      _ => 0,
    };
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    final session = ref.read(sessionProvider);
    bool current() =>
        mounted &&
        version == _requestVersion &&
        identical(session, ref.read(sessionProvider));
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      final result = await repo.expectations(
        page: page,
        orderType: _orderType,
        keyword: _keyword.isEmpty ? null : _keyword,
      );
      if (!current()) return;
      // 类型计数失败不阻断列表（分段按钮降级为 '—'）。
      repo
          .expectationTypeCounts()
          .then((counts) {
            if (current()) setState(() => _typeCounts = counts);
          })
          .catchError((_) {});
      // 已送检待品质计数同理：失败仅不显示该句提示。
      if (_canViewInspection) {
        ref
            .read(procurementInspectionRepositoryProvider)
            .pendingCount()
            .then((count) {
              if (current() && _canViewInspection) {
                setState(() => _inspectionPendingCount = count);
              }
            })
            .catchError((_) {});
      }
      if (!current()) return;
      setState(() {
        _result = result;
        _loading = false;
        final currentIds = result.items
            .where(_canBatchOperate)
            .map((task) => task.id)
            .toSet();
        _selectedIds.removeWhere((id) => !currentIds.contains(id));
      });
      ref.invalidate(warehouseInboundExpectationCountProvider);
    } on ApiException catch (error) {
      if (!current()) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error, stackTrace) {
      // Keep diagnostics out of the employee-facing error message.
      debugPrint('预计到货加载异常: $error\n$stackTrace');
      if (!current()) return;
      setState(() {
        _error =
            (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                    AppLocalizationsZh())
                .commonError;
        _loading = false;
      });
    }
  }

  /// 双击行：按当前到货步骤直达下一步操作（2026-09-05 用户口径：不要
  /// 「到货详情」中间页，双击即到对应办理页）——待登记→登记实际到货页；
  /// 已登记待送检→继续送检确认；超量→到货异常任务中心；已送检→品质部
  /// 检查结果页；返回后任务中心就地刷新。
  Future<void> _openTask(InboundExpectation expectation) async {
    switch (expectation.arrivalStep) {
      case InboundArrivalStep.readyToRegister:
        await _createReceipt(expectation);
      case InboundArrivalStep.draftPendingInspection:
        await _completeRegistration(expectation);
      case InboundArrivalStep.excessPendingFinance:
        await context.push<void>(RouteName.warehouseArrivalExceptions);
      case InboundArrivalStep.awaitingQuality:
        await context.push<void>(RouteName.warehouseQualityResults);
      case InboundArrivalStep.blocked:
        context.appWarning('该任务数据或授权不完整，暂不能办理；请刷新后重试');
    }
    if (!mounted) return;
    await _load(_result?.page ?? 1);
  }

  Future<void> _createReceipt(InboundExpectation expectation) async {
    final prefill = expectation.toReceiptPrefill();
    final route = expectation.orderType.receiptCreateRoute;
    if (prefill == null || route == null) {
      context.appWarning('该预计到货任务暂不能登记，请刷新后重试');
      return;
    }
    // 登记页「登记并送检」一步完成（保存+审核同事务）：返回结果即终态——
    // 正常已转品质部待检，超量已隔离待财务。回本页就地刷新一次并提示下一步，
    // 不再跳采购/委外收货单详情页（仓库流程全程留在仓储模块，也消除闪跳）。
    // 2026-09-05 行级入库仓库起，一次提交可能按仓分组返回多张收货单结果。
    final batch = await context.push<WarehouseArrivalRegistrationBatch>(
      route,
      extra: prefill,
    );
    if (batch == null || !mounted) return;
    await _load(_result?.page ?? 1);
    if (mounted) _announceRegistration(batch);
  }

  /// 断点恢复：草稿收货单一键「继续送检」（服务端按订货单修复币族后走同一审核
  /// 链路）——中途退出的仓库人员在详情弹窗里直接完成停止的步骤，不进采购/委外单据页。
  Future<void> _completeRegistration(InboundExpectation expectation) async {
    if (expectation.draftReceiptIds.isEmpty) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '继续送检',
      actionLabel: '送检',
      confirmLabel: '确认送检',
      message:
          '将把已登记的到货数量送品质部待检(IQC)：检验合格后转仓库待入库任务，'
          '仓库确认实物与库位后库存才增加；'
          '实到超过财务批准量时系统自动隔离并通知财务审核组，不会入库、不会生成应付。'
          '单价按订货单自动带入，无需填写。',
    );
    if (confirmed != true) return;
    try {
      final registration = await ref
          .read(procurementInboundRepositoryProvider)
          .completeArrival(expectation.draftReceiptIds.first);
      if (!mounted) return;
      await _load(_result?.page ?? 1);
      if (mounted) {
        _announceRegistration(
          WarehouseArrivalRegistrationBatch(registrations: [registration]),
        );
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('送检失败，请稍后重试');
    }
  }

  /// 到货登记/送检结果的下一步提示（正常 → 品质检验 → 仓库确认入库；超量 → 财务定案）。
  /// 成功即失效全部仓库任务计数：分段徽章/hub 卡/工作台角标立即联动。
  void _announceRegistration(WarehouseArrivalRegistrationBatch batch) {
    invalidateWarehouseTaskCounts(ref);
    final quarantined = batch.quarantinedCount;
    final total = batch.registrations.length;
    if (quarantined > 0) {
      context.appWarning(
        '已登记送检 ${total - quarantined} 张收货单；'
        '$quarantined 张实到超量已隔离：待财务在到货异常审批定案后，'
        '可在「到货异常任务中心」一键入库',
      );
      return;
    }
    final billNos = [
      for (final item in batch.registrations)
        if (item.receiptBillNo != null) item.receiptBillNo!,
    ];
    context.appSuccess(
      '到货已送检${billNos.isEmpty ? '' : '(${billNos.join('、')})'}：'
      '检查进度与结果请在「品质部检查结果」页查看；'
      '合格后在同一页核对实物与库位确认入库',
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return _loading && result == null
        ? const UtenSkeletonList()
        : _error != null && result == null
        ? UtenEmpty.error(
            message: _error,
            actionLabel: '重新加载',
            onAction: () => _load(1),
          )
        : _buildList(result);
  }

  Widget _buildList(PagedResult<InboundExpectation>? value) {
    final result =
        value ??
        const PagedResult<InboundExpectation>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded) ..._buildToolbar(result),
        if (widget.embedded) _scopeHintRow(),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _InlineError(message: _error!, onRetry: () => _load(result.page)),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: MasterDataTableView<InboundExpectation>(
            key: const Key('inbound-expectation-task-table'),
            columns: _columns,
            items: result.items,
            facets: {
              'orderType': [
                MasterFacetBucket(
                  value: 'PURCHASE',
                  count: _typeCount(ProcurementInboundOrderType.purchase) ?? 0,
                  label: '采购订货',
                ),
                MasterFacetBucket(
                  value: 'SUBCONTRACT',
                  count:
                      _typeCount(ProcurementInboundOrderType.subcontract) ?? 0,
                  label: '委外订货',
                ),
              ],
            },
            nullCounts: const {},
            filters: {'orderType': _orderType?.name.toUpperCase()},
            onFilterChanged: (key, value) {
              if (key != 'orderType' || widget.fixedOrderType != null) return;
              _selectType(switch (value) {
                'PURCHASE' => ProcurementInboundOrderType.purchase,
                'SUBCONTRACT' => ProcurementInboundOrderType.subcontract,
                _ => null,
              });
            },
            selectable: _canBatchSendAny,
            idOf: (expectation) =>
                _canBatchOperate(expectation) ? expectation.id : null,
            selectedIds: _selectedIds,
            onSelectedIdsChanged: _setSelectedIds,
            batchActionsBuilder: _canBatchSendAny ? _batchActions : null,
            onRowTap: _openTask,
            rowMenuBuilder: (expectation) => [
              if (expectation.arrivalStep == InboundArrivalStep.readyToRegister)
                UtenMenuItem(
                  label: '登记实际到货',
                  icon: Icons.inventory_2_outlined,
                  onTap: () => _createReceipt(expectation),
                ),
              if (expectation.arrivalStep ==
                  InboundArrivalStep.draftPendingInspection)
                UtenMenuItem(
                  label: '继续送检',
                  icon: Icons.fact_check_outlined,
                  onTap: () => _completeRegistration(expectation),
                ),
              if (expectation.arrivalStep == InboundArrivalStep.awaitingQuality)
                UtenMenuItem(
                  label: '查看品质检查结果',
                  icon: Icons.plagiarism_outlined,
                  onTap: () => context.push(RouteName.warehouseQualityResults),
                ),
              if (expectation.arrivalStep ==
                  InboundArrivalStep.excessPendingFinance)
                UtenMenuItem(
                  label: '前往到货异常任务中心',
                  icon: Icons.account_balance_outlined,
                  onTap: () => context.go(RouteName.warehouseArrivalExceptions),
                ),
            ],
            isLoading: _loading,
            loadingMore: _loading && _result != null,
            error: result.items.isEmpty ? _error : null,
            onRetry: () => _load(result.page),
            emptyMessage: _keyword.isNotEmpty || _orderType != null
                ? '没有匹配的预计到货'
                : '目前没有预计到货',
            currentPage: result.page,
            totalPages: result.totalPages,
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildToolbar(PagedResult<InboundExpectation> result) {
    final theme = Theme.of(context);
    return [
      Semantics(
        header: true,
        label: '共有 ${result.total} 张待到货订货单',
        // 全平台统一筛选工具条：分段 + 胶囊搜索框，计数取后端全量口径。
        // 计数形态：两个来源段都是「等我收货」的队列 → 红徽章；
        // 「全部待到货」不传 count（没有总量段与之重复红一次）。
        child: UtenFilterToolbar<String>(
          segmentsKey: const Key('inbound-expectation-type-segments'),
          searchKey: const Key('inbound-expectation-search'),
          segments: [
            const UtenFilterSegment(value: 'all', label: '全部待到货'),
            UtenFilterSegment(
              value: 'purchase',
              label: '采购订货',
              count: _typeCount(ProcurementInboundOrderType.purchase),
              countForm: UtenSegmentCountForm.actionable,
            ),
            UtenFilterSegment(
              value: 'subcontract',
              label: '委外订货',
              count: _typeCount(ProcurementInboundOrderType.subcontract),
              countForm: UtenSegmentCountForm.actionable,
            ),
          ],
          selected: _typeSelected
              ? {
                  _orderType == null
                      ? 'all'
                      : _orderType == ProcurementInboundOrderType.purchase
                      ? 'purchase'
                      : 'subcontract',
                }
              : const {},
          onSelectionChanged: (value) => _selectType(switch (value) {
            'purchase' => ProcurementInboundOrderType.purchase,
            'subcontract' => ProcurementInboundOrderType.subcontract,
            _ => null,
          }),
          searchHint: '搜索订货单号 / 供应商 / 货品',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applyKeyword,
          trailing: Text(
            '共 ${result.total} 张 · 双击直达下一步办理',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      const SizedBox(height: UtenSpacing.s8),
      _scopeHintRow(),
    ];
  }

  Widget _scopeHintRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(_scopeHint, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  List<MasterColumnDef<InboundExpectation>> get _columns => [
    MasterColumnDef(
      key: 'orderType',
      label: '订货类型',
      width: 110,
      value: (expectation) => expectation.orderType.label,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '订货单号',
      width: 170,
      value: (expectation) => expectation.billNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 210,
      value: (expectation) => expectation.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'expectedDate',
      label: '预计到货日',
      width: 120,
      type: 'date',
      value: (expectation) => expectation.expectedDate ?? '—',
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '明细行数',
      width: 100,
      type: 'number',
      value: (expectation) => expectation.items.length.toString(),
    ),
    MasterColumnDef(
      key: 'step',
      label: '到货步骤',
      width: 170,
      value: (expectation) => _stepColumnLabel(expectation),
      cellColor: (context, expectation) {
        if (expectation.arrivalStep != InboundArrivalStep.awaitingQuality) {
          return null;
        }
        return Theme.of(context).brightness == Brightness.dark
            ? UtenColors.warning.withValues(alpha: 0.18)
            : UtenColors.warningBg;
      },
    ),
    MasterColumnDef(
      key: 'ownerEmployeeName',
      label: '负责人',
      width: 140,
      value: (expectation) => expectation.ownerEmployeeName ?? '—',
    ),
  ];
}

/// 到货步骤列文案：列表只放单据级概要，数量化的进度（超量笔数等）随步骤带出。
String _stepColumnLabel(InboundExpectation expectation) {
  final step = expectation.arrivalStep;
  return switch (step) {
    InboundArrivalStep.readyToRegister => '待登记到货',
    InboundArrivalStep.draftPendingInspection => '已登记 · 待送检',
    InboundArrivalStep.excessPendingFinance =>
      expectation.openArrivalExceptions > 0
          ? '超量待财务(${expectation.openArrivalExceptions})'
          : '超量待财务',
    InboundArrivalStep.awaitingQuality => '已送检 · 结果见「品质部检查结果」',
    InboundArrivalStep.blocked => '暂不能登记',
  };
}

/// 预计到货详情弹窗：单据概要 + 待收明细 + 按当前步骤收口的动作按钮
/// （待登记→登记实际到货；已登记→继续送检；超量→去异常中心；已送检→只读）。

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
