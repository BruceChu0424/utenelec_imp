// 先入库后质检(V596 / ADR-090)：把「等待检查结果」的收货单逐行上架到实际叶仓与库位。
//
// 只写位置事实、不写库存：品质合格时系统按这里记录的位置自动完成正式入库(不再需要仓库
// 再点一次确认)，不合格由仓库从库位取出走既有退回登记。入口：品质部检查结果列表行菜单
// 「先入库上架」/ 详情页悬浮按钮；到货登记页点「先入库后质检」按钮则在登记同事务里完成，
// 不经过本页。

import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../repositories/warehouse_iqc_stock_in_repository.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_slice_table.dart'
    show warehouseQualityQuantity;
import '../widgets/warehouse_quality_stock_in_warehouse_picker.dart';
import '../../../shared/badges/badge_registry.dart';

class WarehouseQualityPreStockInPage extends ConsumerStatefulWidget {
  const WarehouseQualityPreStockInPage({
    super.key,
    required this.receiptType,
    required this.receiptId,
  });

  final String receiptType;
  final String receiptId;

  @override
  ConsumerState<WarehouseQualityPreStockInPage> createState() =>
      _WarehouseQualityPreStockInPageState();
}

class _WarehouseQualityPreStockInPageState
    extends ConsumerState<WarehouseQualityPreStockInPage>
    with FormDraftMixin<WarehouseQualityPreStockInPage> {
  WarehouseIqcPreStockInCommand? _pendingCommand;
  @override
  bool get formDraftBusy => _saving || _loading;
  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    await _load(preserveInputs: false);
    if (_error != null) throw StateError(_error!);
  };
  @override
  bool get formDraftCanReplaySubmission => _pendingCommand != null;
  @override
  bool get formDraftHasUnknownSubmission => _pendingCommand != null;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.warehouseQualityPreStockIn.spec(
        route: RouteName.warehouseQualityPreStockIn(
          widget.receiptType,
          widget.receiptId,
        ),
      );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _grid,
    for (final row in _grid.rows) row.place,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'receipts': [
      {'receiptType': widget.receiptType, 'receiptId': widget.receiptId},
    ],
    'rows': [
      for (final row in _grid.rows)
        {
          'inspectionItemId': row.line.inspectionItemId,
          'selected': row.selected,
          'warehouseId': row.warehouseId,
          'warehouseName': row.warehouseName,
          'place': row.place.text,
        },
    ],
    'pendingCommand': _pendingCommand?.toJson(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final pending = data['pendingCommand'];
    _pendingCommand = pending is Map
        ? WarehouseIqcPreStockInCommand.fromDraft(
            Map<String, dynamic>.from(pending),
          )
        : null;
    final rows = data['rows'];
    if (rows is! List) throw const FormatException('上架草稿缺少来源明细');
    final current = {
      for (final row in _grid.rows) row.line.inspectionItemId: row,
    };
    for (final input in rows.cast<Map<Object?, Object?>>()) {
      final row = current[input['inspectionItemId']];
      if (row == null) {
        if (_pendingCommand == null) {
          throw const FormatException('原待检明细已变化，请保留草稿并核对');
        }
        continue;
      }
      row.restoreInput(input);
    }
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => _pendingCommand == null
      ? null
      : UtenButton(
          onPressed: _saving || _loading || !_canPreStockIn
              ? null
              : _verifyPreStockIn,
          icon: Icons.refresh_rounded,
          child: const Text('核对原上架提交'),
        );
  WarehouseQualityResultDetail? _detail;
  final _grid = UtenEditableGridController<WarehousePreStockRow>();
  int _requestVersion = 0;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    _load();
  }

  // 2026-09-22 全站表格滚动口径：网格表头吸顶 + 置顶后才显示页面滚动条
  // （与单据编辑页同款：stickyHeaderPinned + UtenGridPageScrollbar 门控）。
  final ScrollController _pageScroll = ScrollController();
  final _gridPinned = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _pageScroll.dispose();
    _gridPinned.dispose();
    _grid.dispose();
    super.dispose();
  }

  bool get _canPreStockIn {
    if (ref.read(authenticatedScopeProvider)?.readOnly == true) return false;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInBeforeInspection);
  }

  List<WarehousePreStockRow> get _selected =>
      _grid.rows.where((row) => row.selected).toList(growable: false);

  Future<void> _load({bool preserveInputs = true}) async {
    final version = ++_requestVersion;
    final previous = {
      for (final row in _grid.rows)
        if (preserveInputs)
          row.line.inspectionItemId: {
            'selected': row.selected,
            'warehouseId': row.warehouseId,
            'warehouseName': row.warehouseName,
            'place': row.place.text,
          },
    };
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(warehouseQualityResultRepositoryProvider)
          .detail(widget.receiptType, widget.receiptId);
      if (!mounted ||
          !formDraftIdentityIsCurrent ||
          version != _requestVersion) {
        return;
      }
      final rows = [
        for (final line in detail.preStockableLines) WarehousePreStockRow(line),
      ];
      try {
        final identities = rows.map((row) => row.line.inspectionItemId).toSet();
        if (_pendingCommand == null &&
            previous.keys.any((id) => !identities.contains(id))) {
          throw const FormatException('待检明细已变化，原仓库和库位输入已保留，请重新核对来源');
        }
        for (final row in rows) {
          final input = previous[row.line.inspectionItemId];
          if (input != null) row.restoreInput(input);
        }
      } catch (_) {
        for (final row in rows) {
          row.dispose();
        }
        rethrow;
      }
      setState(() {
        _detail = detail;
        _grid.replaceAll(rows);
        _loading = false;
      });
      await initializeFormDraft();
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error is FormatException ? error.message : '待检明细加载失败，请稍后重试';
        _loading = false;
      });
      if (error is FormatException) holdFormDraftForSourceReload(error);
    }
  }

  Future<void> _pickWarehouse(WarehousePreStockRow row) async {
    if (_saving || _loading || _pendingCommand != null || !_canPreStockIn) {
      return;
    }
    try {
      final picked = await pickWarehouseLeafForStockIn(
        context,
        ref,
        initialWarehouseId: row.warehouseId,
        title: '选择上架仓库 · ${row.goodsLabel}',
      );
      if (picked == null || !mounted || !_grid.rows.contains(row)) return;
      setState(() => row.selectWarehouse(id: picked.id, name: picked.label));
    } catch (_) {
      if (mounted) context.appError('仓库资料加载失败，请重试');
    }
  }

  Future<void> _submit() async {
    if (_saving || _loading || _pendingCommand != null || !_canPreStockIn) {
      return;
    }
    final selected = _selected;
    if (selected.isEmpty) {
      setState(() => _error = '请至少勾选一行要上架的待检明细');
      return;
    }
    for (final row in selected) {
      final error = row.validate();
      if (error != null) {
        setState(() => _error = error);
        return;
      }
    }
    await _executePreStockIn(
      WarehouseIqcPreStockInCommand(
        items: [for (final row in selected) row.toItem()],
      ),
    );
  }

  Future<void> _executePreStockIn(WarehouseIqcPreStockInCommand command) async {
    if (_saving || !_canPreStockIn) return;
    _pendingCommand = command;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await runFormDraftSubmission(
        () {
          if (!_canPreStockIn) {
            throw ApiException(
              'FORBIDDEN',
              '当前账号不能先入库上架，请重新核对权限',
              httpStatus: 403,
            );
          }
          return ref
              .read(warehouseIqcStockInRepositoryProvider)
              .preStockIn(widget.receiptType, widget.receiptId, command);
        },
        isDefiniteRejection: (error) =>
            error.code == 'FORBIDDEN' ||
            error.httpStatus == 400 ||
            error.httpStatus == 422 ||
            (error.httpStatus == 409 && error.code == 'CONFLICT'),
      );
      if (!mounted || !formDraftIdentityIsCurrent) return;
      // 打源头 type-counts: 红黄两支都是它的派生, 失效派生不会重新发请求。
      refreshBadges(ref);
      _pendingCommand = null;
      await completeFormDraft();
      if (!mounted) return;
      final replayed = result.replayedLineCount;
      context.appSuccess(
        '已先入库上架 ${result.stockedLineCount} 行'
        '${replayed > 0 ? '($replayed 行位置未变化)' : ''}：'
        '品质部会到库位检验，合格后系统自动转正入库，不合格再从库位取出登记退回',
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        await resetFormDraftAfterSubmission(prepare: () => _load());
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.httpStatus == 400 ||
          error.httpStatus == 403 ||
          error.httpStatus == 422 ||
          error.code == 'CONFLICT') {
        _pendingCommand = null;
      }
      setState(() => _error = error.message);
      await checkpointFormDraftAfterCreation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeSubmitError(error, fallback: '上架提交待核对，请核对原提交'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _verifyPreStockIn() async {
    final command = _pendingCommand;
    if (command == null || _saving || _loading || !_canPreStockIn) return;
    setState(() => _loading = true);
    try {
      final latest = await ref
          .read(warehouseQualityResultRepositoryProvider)
          .detail(widget.receiptType, widget.receiptId);
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final lines = {
        for (final line in latest.lines) line.inspectionItemId: line,
      };
      final confirmed = command.items.every((item) {
        final location = lines[item.inspectionItemId]?.preStocked;
        return location?.warehouseId == item.warehouseId &&
            location?.place?.trim() == item.place.trim();
      });
      if (confirmed) {
        _pendingCommand = null;
        await resetFormDraftAfterSubmission(
          prepare: () => _load(preserveInputs: false),
        );
        if (mounted && formDraftIdentityIsCurrent) {
          context.appSuccess('已核对：原上架仓库和库位已记录');
        }
        refreshBadges(ref);
        return;
      }
      final stillPending = command.items.every((item) {
        final line = lines[item.inspectionItemId];
        return line != null &&
            line.lineStatus.toUpperCase() == 'PENDING' &&
            line.passedBaseQty == 0 &&
            line.failedBaseQty == 0;
      });
      if (!stillPending) {
        context.appWarning('原待检明细已变化，原提交继续保留，请核对上架记录后处理');
        return;
      }
      await _executePreStockIn(command);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(describeSubmitError(error, fallback: '核对原上架记录失败'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(authenticatedScopeProvider);
    final theme = Theme.of(context);
    final detail = _detail;
    return withFormDraft(
      PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: UtenAppBar(
            title: '先入库上架 · ${detail?.billNo ?? widget.receiptId}',
            leading: UtenBackButton(
              color: _saving ? theme.disabledColor : null,
              onPressed: _saving
                  ? null
                  : () => popOrBackTo(
                      context,
                      defaultPath: RouteName.warehouseQualityResults,
                    ),
            ),
            actions: [
              UtenAppBarActionButton(
                key: const Key('warehouse-quality-pre-stock-refresh'),
                label: '刷新',
                icon: Icons.refresh_rounded,
                isLoading: _loading,
                onPressed: _loading || _saving ? null : _load,
              ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton:
              _canPreStockIn &&
                  !_loading &&
                  (_grid.rows.isNotEmpty || _pendingCommand != null)
              ? _buildBottomBar()
              : null,
          body: SafeArea(
            child: _loading
                ? const UtenSkeletonList()
                : Stack(
                    children: [
                      AbsorbPointer(
                        absorbing: _saving,
                        child: UtenGridPageScrollbar(
                          pinned: _gridPinned,
                          controller: _pageScroll,
                          child: UtenContentContainer.wide(
                            child: detail == null || _grid.rows.isEmpty
                                ? UtenEmpty.error(
                                    message: _error ?? '本单没有可先入库上架的待检明细',
                                    description:
                                        '只有仍在等待检查结果、尚未上架的明细行才能先入库；'
                                        '已出结论的行请按原流程办理。',
                                    actionLabel: '重新加载',
                                    onAction: _load,
                                  )
                                : _buildBody(theme, detail),
                          ),
                        ),
                      ),
                      if (_saving)
                        const Positioned.fill(
                          child: UtenBusyOverlay(
                            title: '正在先入库上架',
                            description: '只记录上架仓与库位，不改变库存数量。',
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, WarehouseQualityResultDetail detail) {
    return ListView(
      controller: _pageScroll,
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenFloatingActionGroup.scrollClearance,
      ),
      children: [
        UtenInlineNotice(
          key: const Key('warehouse-quality-pre-stock-notice'),
          title: '先入库后质检：只落位置，不改库存',
          message:
              '把实物先放到上架仓与库位，本页只记录位置；品质部会按这个位置到储放区域检验。'
              '合格后系统自动按此位置转正入库(无需仓库再确认)，不合格由仓库从库位取出登记退回。'
              '${_canPreStockIn ? '' : '当前账号没有「到货先入库后质检」权限，只能查看。'}',
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '${detail.receiptType.label} ${detail.billNo ?? detail.receiptId}'
          '${detail.supplierName == null ? '' : ' · ${detail.supplierName}'}'
          ' · 收货参考仓 ${detail.warehouseName ?? '—'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenEditableGrid<WarehousePreStockRow>(
          tableKey:
              'features.warehouse.pages.warehouse_quality_pre_stock_in_page.WarehouseQualityPreStockInPageState._buildBody.1',
          key: const Key('warehouse-quality-pre-stock-grid'),
          controller: _grid,
          stickyHeaderPinned: _gridPinned,
          columns: _columns(context),
          showAddRow: false,
          showRowDelete: false,
          showSelectAllToggle: false,
          showRemoveRowsAction: false,
          selectable: true,
          selectionEnabled:
              _canPreStockIn && !_saving && _pendingCommand == null,
          selectedOf: (row) => row.selected,
          onRowSelect: (row, selected) =>
              setState(() => row.selected = selected),
          emptyMessage: '本单没有可先入库上架的待检明细',
        ),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenInlineNotice(
            key: const Key('warehouse-quality-pre-stock-error'),
            level: UtenInlineNoticeLevel.error,
            message: _error!,
          ),
        ],
      ],
    );
  }

  List<EditableGridColumn<WarehousePreStockRow>> _columns(
    BuildContext context,
  ) {
    final editable = _canPreStockIn && _pendingCommand == null;
    return [
      EditableGridColumn(
        key: 'goods',
        label: '货品名称',
        width: 200,
        filterValueOf: (row) => row.line.goodsName,
        cellBuilder: (context, row) =>
            UtenGoodsIdentityCell(name: row.line.goodsName),
      ),
      EditableGridColumn(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        filterValueOf: (row) => row.line.goodsCode,
        cellBuilder: (context, row) =>
            UtenGoodsAttributeCell(row.line.goodsCode),
      ),
      EditableGridColumn(
        key: 'colorName',
        label: '颜色',
        width: 96,
        filterValueOf: (row) => row.line.colorName,
        cellBuilder: (context, row) =>
            UtenGoodsAttributeCell(row.line.colorName),
      ),
      EditableGridColumn(
        key: 'received',
        exactValueOf: (row) => row.line.receivedBaseQty.toString(),
        label: '待检量',
        width: 120,
        numeric: true,
        cellBuilder: (context, row) => Text(
          '${warehouseQualityQuantity(row.line.receivedBaseQty)} ${row.line.unitName ?? ''}'
              .trim(),
        ),
      ),
      EditableGridColumn(
        key: 'warehouse',
        label: '上架仓库',
        width: 170,
        required: editable,
        headerInfo: '实物实际放进的记账叶仓；默认为收货参考仓，可逐行更换。',
        filterValueOf: (row) => row.warehouseName,
        textOf: (row) => row.warehouseName ?? '未选择',
        cellBuilder: (context, row) => _warehouseCell(context, row, editable),
      ),
      EditableGridColumn(
        key: 'place',
        label: '上架库位',
        width: 140,
        required: editable,
        textOf: (row) => row.place.text,
        listenableOf: (row) => row.place,
        cellBuilder: (context, row) => _placeCell(context, row, editable),
      ),
    ];
  }

  Widget _warehouseCell(
    BuildContext context,
    WarehousePreStockRow row,
    bool editable,
  ) {
    if (!editable) return Text(row.warehouseName ?? '未选择');
    final theme = Theme.of(context);
    final enabled = row.selected && !_saving;
    return Semantics(
      button: true,
      label: '${row.goodsLabel} 上架仓库：${row.warehouseName ?? '未选择'}',
      child: InkWell(
        key: ValueKey('pre-stock-warehouse-${row.line.inspectionItemId}'),
        onTap: enabled ? () => _pickWarehouse(row) : null,
        borderRadius: UtenRadius.controlAll,
        child: InputDecorator(
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              enabled: enabled,
              error: utenFieldError(row.selected ? row.warehouseError : null),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  row.warehouseName ?? utenFieldPlaceholder(label: '上架仓库')!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeCell(
    BuildContext context,
    WarehousePreStockRow row,
    bool editable,
  ) {
    if (!editable) {
      final text = row.place.text.trim();
      return Text(text.isEmpty ? '—' : text);
    }
    return RequiredCellFrame(
      listenable: row.place,
      isEmpty: () => row.selected && row.placeError != null,
      child: TextFormField(
        key: ValueKey('pre-stock-place-${row.line.inspectionItemId}'),
        controller: row.place,
        enabled: row.selected && !_saving && _pendingCommand == null,
        maxLength: 100,
        inputFormatters: [LengthLimitingTextInputFormatter(100)],
        errorBuilder: utenTextFieldErrorBuilder,
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            counterText: '',
            hintText: '上架库位',
            error: utenFieldError(row.selected ? row.placeError : null),
          ),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildBottomBar() {
    final selectedCount = _selected.length;
    return UtenFloatingActionGroup(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('warehouse-quality-pre-stock-selected-count'),
          count: selectedCount,
          onClear: selectedCount == 0 || _saving
              ? null
              : () => setState(() {
                  for (final row in _grid.rows) {
                    row.selected = false;
                  }
                }),
        ),
        UtenButton(
          key: const Key('warehouse-quality-pre-stock-confirm'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.shelves,
          isLoading: _saving,
          onPressed:
              _saving ||
                  _loading ||
                  (_pendingCommand == null && selectedCount == 0)
              ? null
              : _pendingCommand != null
              ? _verifyPreStockIn
              : _submit,
          onDisabledTap: selectedCount == 0
              ? () => context.appWarning('请至少勾选一行要上架的待检明细')
              : null,
          child: Text(
            _pendingCommand != null ? '核对原上架提交' : '确认先入库上架($selectedCount 行)',
          ),
        ),
      ],
    );
  }
}

/// 一行待检明细的上架草稿：默认上架仓 = 收货参考仓，库位预填建议库位。
class WarehousePreStockRow extends EditableGridRow {
  WarehousePreStockRow(this.line)
    : place = TextEditingController(text: line.placeHint ?? ''),
      _warehouseId = line.warehouseId,
      _warehouseName = line.warehouseName;

  final WarehouseQualityInspectionLine line;
  final TextEditingController place;
  bool selected = true;
  String? _warehouseId;
  String? _warehouseName;

  String? get warehouseId => _warehouseId;
  String? get warehouseName => _warehouseName;

  void restoreInput(Map<Object?, Object?> input) {
    selected = input['selected'] == true;
    _warehouseId = input['warehouseId'] as String?;
    _warehouseName = input['warehouseName'] as String?;
    place.text = input['place'] as String? ?? '';
  }

  String get goodsLabel =>
      line.goodsLabel.isEmpty ? line.inspectionItemId : line.goodsLabel;

  /// 库位属于实际叶仓：换仓必须重新填库位；同仓只更新显示名。
  void selectWarehouse({required String id, required String name}) {
    final changed = id != _warehouseId;
    _warehouseId = id;
    _warehouseName = name;
    if (changed) place.clear();
  }

  String? get warehouseError =>
      warehouseId?.trim().isNotEmpty == true ? null : '请选择实物上架的记账叶仓';

  String? get placeError {
    final text = place.text.trim();
    if (text.isEmpty) return '请填写实物上架的库位';
    if (text.length > 100) return '库位不得超过 100 个字符';
    return null;
  }

  String? validate() {
    if (!selected) return null;
    final error = warehouseError ?? placeError;
    return error == null ? null : '「$goodsLabel」$error';
  }

  WarehouseIqcPreStockInItem toItem() => WarehouseIqcPreStockInItem(
    inspectionItemId: line.inspectionItemId,
    warehouseId: warehouseId!,
    place: place.text.trim(),
  );

  @override
  void dispose() {
    place.dispose();
    super.dispose();
  }
}
