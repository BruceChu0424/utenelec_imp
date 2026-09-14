import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/models/stock_doc.dart';
import '../../warehouse/providers/warehouse_count_refresh.dart';
import '../models/production_draw_request.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_draw_request_repository.dart';

/// Review the selected workshop tasks before explicitly requesting materials.
/// Only the final action makes these tasks visible in the warehouse draw queue.
class ProductionDrawRequestPage extends ConsumerStatefulWidget {
  const ProductionDrawRequestPage({
    super.key,
    required this.segmentIds,
    this.expectedVersions = const {},
  });

  final List<String> segmentIds;
  final Map<String, int> expectedVersions;

  @override
  ConsumerState<ProductionDrawRequestPage> createState() =>
      _ProductionDrawRequestPageState();
}

class _ProductionDrawRequestPageState
    extends ConsumerState<ProductionDrawRequestPage> {
  ProductionDrawRequestPreview? _preview;
  bool _loading = true;
  bool _saving = false;
  bool _uncertain = false;
  bool _rejected = false;
  String? _loadError;
  String? _submitError;
  final _selected = <String>{};
  final _quantities = <String, TextEditingController>{};
  final _quantityErrors = <String, String>{};

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _hasPermission {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionExecutionStart);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool currentVersions = false}) async {
    if (_saving || _uncertain || !mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _submitError = null;
      _rejected = false;
      _preview = null;
    });
    try {
      if (!_hasPermission) {
        throw const FormatException('当前账号没有查看并提交车间领料的权限');
      }
      final ids =
          widget.segmentIds
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      if (ids.isEmpty ||
          ids.length > ProductionDrawRequestRepository.batchLimit) {
        throw const FormatException('请返回我的车间任务，选择 1 至 50 个齐套任务');
      }
      final preview = await ref
          .read(productionDrawRequestRepositoryProvider)
          .preview([
            for (final id in ids)
              ProductionDrawRequestItem(
                segmentId: id,
                expectedVersion: currentVersions
                    ? null
                    : widget.expectedVersions[id],
              ),
          ]);
      if (mounted) {
        for (final controller in _quantities.values) {
          controller.dispose();
        }
        setState(() {
          _preview = preview;
          _selected
            ..clear()
            ..addAll(preview.summaries.map((row) => row.identity));
          _quantities
            ..clear()
            ..addEntries(
              preview.summaries.map(
                (row) => MapEntry(
                  row.identity,
                  TextEditingController(text: _quantity(row.qty)),
                ),
              ),
            );
          _quantityErrors.clear();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = _errorMessage(error));
    } on FormatException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (_) {
      if (mounted) setState(() => _loadError = '领料汇总加载失败，请重新加载');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? get _blocked {
    if (!_hasPermission) return '当前账号没有查看并提交车间领料的权限';
    if (_loading) return '正在加载领料汇总';
    if (_saving) return '正在提交领料，请稍候';
    if (_rejected) return '任务或物料已变化，请重新加载并核对汇总';
    final preview = _preview;
    if (preview == null ||
        preview.tasks.isEmpty ||
        preview.summaries.isEmpty ||
        preview.fingerprint.isEmpty) {
      return '没有可提交的领料明细，请返回我的车间任务重新选择';
    }
    if (_selected.isEmpty) return '请先勾选本次要领取的物料';
    for (final row in preview.summaries.where(
      (row) => _selected.contains(row.identity),
    )) {
      final error = _quantityError(row);
      if (error != null) return error;
    }
    try {
      _requestLines(preview);
    } on FormatException catch (error) {
      return error.message;
    }
    return null;
  }

  String? _quantityError(ProductionDrawRequestSummary row) {
    final input = _quantities[row.identity]?.text.trim() ?? '';
    final value = double.tryParse(input);
    if (value == null || !value.isFinite || value <= 0) {
      return '请输入大于 0 的本次领料数量';
    }
    if (value > row.qty + 0.000001) return '本次领料不能超过待申请量 ${_quantity(row.qty)}';
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(input)) return '数量最多支持 4 位小数';
    return null;
  }

  List<ProductionDrawRequestSelection> _requestLines(
    ProductionDrawRequestPreview preview,
  ) => [
    for (final row in preview.summaries)
      if (_selected.contains(row.identity) && _quantityError(row) == null)
        ...preview.selectionsFor(
          row,
          double.parse(_quantities[row.identity]!.text.trim()),
        ),
  ]..sort((a, b) => a.drawItemId.compareTo(b.drawItemId));

  Future<void> _submit() async {
    if (_blocked != null) return;
    final preview = _preview!;
    final items = preview.requestItems
      ..sort((a, b) => a.segmentId.compareTo(b.segmentId));
    final lines = _requestLines(preview);
    // A lost response retries the exact reviewed intent, including after a
    // navigation back to an unchanged preview. Never mint a second request key.
    final key = businessIdempotencyKey(
      'workshop-draw',
      '${preview.fingerprint}|${items.map((item) => '${item.segmentId}:${item.expectedVersion}').join('|')}|${lines.map((line) => '${line.drawItemId}:${line.quantity}').join('|')}',
    );
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final result = await ref
          .read(productionDrawRequestRepositoryProvider)
          .submit(
            items: items,
            idempotencyKey: key,
            previewFingerprint: preview.fingerprint,
            lines: lines,
          );
      if (!mounted) return;
      refreshAfterProductionPlanGenerated(ref);
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.draw.refreshKey);
      if (result.replayed) {
        context.appInfo('本批 ${result.taskCount} 个任务已提交领料，请等待仓库出库');
      } else {
        context.appSuccess(
          '已提交 ${result.taskCount} 个任务领料，仓库新增 ${result.documentCount} 张待出库单',
        );
      }
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.productionWorkshopTasks);
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'NETWORK' ||
          error.code == 'NETWORK_TIMEOUT' ||
          error.code == 'INTERNAL' ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      setState(() {
        _uncertain = uncertain;
        _rejected = !uncertain;
        _submitError = uncertain
            ? '暂未确认领料结果，请点击“重试领料”查询并继续本批提交。当前汇总已保留。'
            : '${_errorMessage(error)}。请重新加载并核对领料汇总。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uncertain = true;
        _submitError = '暂未确认领料结果，请点击“重试领料”查询并继续本批提交。当前汇总已保留。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _back() =>
      popOrBackTo(context, defaultPath: RouteName.productionWorkshopTasks);

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final preview = _preview;
    final blocked = _blocked;
    return PopScope(
      canPop: !_saving && !_uncertain,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '领料汇总',
          leading: UtenBackButton(
            onPressed: _saving || _uncertain ? null : _back,
          ),
          actions: [
            IconButton(
              key: const Key('production-draw-request-refresh'),
              tooltip: _uncertain ? '请先重试领料，确认本批结果' : '刷新领料汇总',
              onPressed: _loading || _saving || _uncertain || !_hasPermission
                  ? null
                  : () => _load(currentVersions: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: !_hasPermission
                ? const UtenEmpty(
                    icon: Icons.lock_outline,
                    message: '当前账号没有查看并提交车间领料的权限',
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? UtenEmpty.error(
                    message: _loadError,
                    actionLabel: '重新加载',
                    onAction: () => _load(currentVersions: true),
                  )
                : preview == null ||
                      preview.summaries.isEmpty ||
                      preview.tasks.isEmpty
                ? UtenEmpty(
                    message: '暂无可领物料',
                    description: '请返回我的车间任务，刷新后重新选择齐套任务。',
                    actionLabel: '返回我的车间任务',
                    onAction: _back,
                  )
                : AbsorbPointer(
                    absorbing: _saving,
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: _header(preview),
                      body: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: _summaryTable(preview),
                      ),
                    ),
                  ),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButton:
            !_hasPermission ||
                _loading ||
                preview == null ||
                preview.tasks.isEmpty ||
                preview.summaries.isEmpty
            ? null
            : UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    onPressed: _saving || _uncertain ? null : _back,
                    child: const Text('返回'),
                  ),
                  UtenButton(
                    key: const Key('production-draw-request-submit'),
                    type: UtenButtonType.danger,
                    size: UtenButtonSize.large,
                    icon: Icons.inventory_2_outlined,
                    isLoading: _saving,
                    onPressed: blocked == null ? _submit : null,
                    onDisabledTap: () =>
                        context.appWarning(blocked ?? '正在提交领料'),
                    child: Text(_uncertain ? '重试领料' : '领料'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _header(ProductionDrawRequestPreview preview) => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${preview.taskCount} 个车间任务 · ${preview.summaries.length} 项领料汇总 · ${preview.documentCount} 张领料单',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '领料车间：${_label(preview.tasks.first.workshopName)}。勾选本次物料并填写应领数量，可分次提交；点击来源可核对本次分配到各任务的数量。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '只提交勾选的本次数量，其余保留待领。按部分成品数量先生产，请从任务详情进入“分批领料”，配齐本批后再开工。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_submitError != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Semantics(
            liveRegion: true,
            child: Text(
              _submitError!,
              key: const Key('production-draw-request-submit-error'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          if (_rejected)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving ? null : () => _load(currentVersions: true),
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载并核对'),
              ),
            ),
        ],
      ],
    ),
  );

  Widget _summaryTable(ProductionDrawRequestPreview preview) =>
      MasterDataTableView<ProductionDrawRequestSummary>(
        key: const Key('production-draw-request-summary-table'),
        primary: true,
        selectable: true,
        idOf: (row) => row.identity,
        rowKeyOf: (row) => row.identity,
        selectedIds: _selected,
        onSelectedIdsChanged: (next) {
          if (_saving || _uncertain || _rejected) return;
          setState(() {
            _selected
              ..clear()
              ..addAll(next);
          });
        },
        bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        columns: [
          MasterColumnDef(
            key: 'warehouse',
            label: '领料仓库',
            width: 170,
            value: (row) => _label(row.warehouseName),
          ),
          // 2026-09-14 全站列序统一：名称 → 编号 → 颜色。
          MasterColumnDef(
            key: 'goodsName',
            label: '物料名称',
            width: 200,
            value: (row) => _label(row.goodsName),
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            value: (row) => _label(row.goodsCode),
          ),
          MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 100,
            value: (row) => _label(row.colorName),
          ),
          MasterColumnDef(
            key: 'unit',
            label: '单位',
            width: 75,
            value: (row) => _label(row.unitName),
          ),
          MasterColumnDef(
            key: 'qty',
            label: '待申请量',
            width: 110,
            type: 'number',
            value: (row) => _quantity(row.qty),
          ),
          MasterColumnDef(
            key: 'requestQty',
            label: '应领数量',
            info: '本次提交仓库的数量，可分批填写。其余数量保留待申请，不修改原任务和需求。',
            width: 170,
            type: 'number',
            value: (row) => _quantities[row.identity]?.text,
            cellBuilderHandlesSemantics: true,
            cellBuilder: (context, row) => TextField(
              key: ValueKey('production-draw-quantity-${row.identity}'),
              controller: _quantities[row.identity],
              enabled:
                  !_saving &&
                  !_uncertain &&
                  !_rejected &&
                  _selected.contains(row.identity),
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '本次领料',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  error: _quantityErrors[row.identity] == null
                      ? null
                      : UtenFieldMessage.error(_quantityErrors[row.identity]!),
                ),
                info: '最多 ${_quantity(row.qty)} ${_label(row.unitName)}',
              ),
              onChanged: (_) => setState(() {
                final error = _quantityError(row);
                if (error == null) {
                  _quantityErrors.remove(row.identity);
                } else {
                  _quantityErrors[row.identity] = error;
                }
              }),
            ),
          ),
          MasterColumnDef(
            key: 'sources',
            label: '任务来源',
            width: 180,
            value: (row) => _sourcesLabel(preview, row),
            cellBuilder: (context, row) => TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              onPressed: () => _showSources(preview, row),
              child: Text(_sourcesLabel(preview, row)),
            ),
          ),
        ],
        items: preview.summaries,
        emptyMessage: '暂无领料汇总',
      );

  String _sourcesLabel(
    ProductionDrawRequestPreview preview,
    ProductionDrawRequestSummary summary,
  ) =>
      '${preview.sourcesFor(summary).map((line) => line.segmentId).toSet().length} 个任务 · 查看明细';

  Future<void> _showSources(
    ProductionDrawRequestPreview preview,
    ProductionDrawRequestSummary summary,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${_label(summary.goodsName)} · 任务来源'),
      content: SizedBox(
        width: 920,
        height: MediaQuery.sizeOf(context).height * .55,
        child: MasterDataTableView<ProductionDrawRequestLine>(
          key: const Key('production-draw-request-sources-table'),
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          showFullscreenToggle: false,
          columns: [
            MasterColumnDef(
              key: 'planNo',
              label: '生产计划',
              width: 170,
              value: (line) => _label(preview.taskFor(line.segmentId)?.planNo),
            ),
            MasterColumnDef(
              key: 'segment',
              label: '车间任务',
              width: 170,
              value: (line) =>
                  _label(preview.taskFor(line.segmentId)?.segmentCode),
            ),
            MasterColumnDef(
              key: 'product',
              label: '生产产品',
              width: 180,
              value: (line) =>
                  _label(preview.taskFor(line.segmentId)?.productName),
            ),
            MasterColumnDef(
              key: 'drawNo',
              label: '领料单号',
              width: 170,
              value: (line) => _label(line.drawNo),
            ),
            MasterColumnDef(
              key: 'qty',
              label: '待申请量',
              width: 110,
              type: 'number',
              value: (line) => _quantity(line.qty),
            ),
            MasterColumnDef(
              key: 'requestQty',
              label: '本次领料',
              width: 120,
              type: 'number',
              value: (line) => _quantity(
                _requestLines(preview)
                        .where(
                          (selected) => selected.drawItemId == line.drawItemId,
                        )
                        .firstOrNull
                        ?.quantity ??
                    0,
              ),
            ),
            MasterColumnDef(
              key: 'unit',
              label: '单位',
              width: 75,
              value: (line) => _label(line.unitName),
            ),
          ],
          items: preview.sourcesFor(summary),
          emptyMessage: '暂无任务来源',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  static String _errorMessage(ApiException error) =>
      error.fieldErrors?.firstOrNull?.message ?? error.message;

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value! : '—';

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
