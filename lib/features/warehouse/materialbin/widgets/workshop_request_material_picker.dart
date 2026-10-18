import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

Future<WmMaterialOption?> showWorkshopRequestMaterialPicker(
  BuildContext context, {
  required String workshopId,
}) => showUtenAdaptivePanel<WmMaterialOption>(
  context: context,
  drawerWidth: 720,
  builder: (_) => _RequestMaterialPicker(workshopId: workshopId),
);

/// 搜索在服务端分页，不把前 500 种物料当成全部可选物料。
class _RequestMaterialPicker extends ConsumerStatefulWidget {
  const _RequestMaterialPicker({required this.workshopId});
  final String workshopId;

  @override
  ConsumerState<_RequestMaterialPicker> createState() =>
      _RequestMaterialPickerState();
}

class _RequestMaterialPickerState
    extends ConsumerState<_RequestMaterialPicker> {
  final _rows = MasterDataTableRowsController<WmMaterialOption>();
  PagedResult<WmMaterialOption>? _page;
  WmMaterialOption? _selected;
  SensitiveReadBoundary? _loadedBoundary;
  String? _loadedKeyword;
  String _keyword = '';
  String? _error;
  int _generation = 0;
  bool _loading = true;
  bool _rowsReady = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      setState(() {
        _invalidate();
        _error = '账号、服务器或权限已变化，请重新搜索';
      });
    });
    _load(1);
  }

  void _invalidate() {
    ++_generation;
    _page = null;
    _selected = null;
    _loadedBoundary = null;
    _loadedKeyword = null;
    _rows.update(const []);
    _error = null;
    _loading = false;
    _rowsReady = false;
  }

  Future<void> _load(int page) async {
    if (!mounted) return;
    final generation = ++_generation;
    final keyword = _keyword;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _loading = true;
      _error = null;
      _rowsReady = false;
    });
    try {
      final result = await ref
          .read(workshopMaterialRepositoryProvider)
          .requestMaterials(widget.workshopId, keyword: keyword, page: page);
      if (mounted &&
          generation == _generation &&
          boundary == ref.read(sensitiveReadBoundaryProvider)) {
        setState(() {
          _page = result;
          _loadedBoundary = boundary;
          _loadedKeyword = keyword;
          _loading = false;
        });
        _reconcileSelection(generation);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is ApiException ? error.message : '物料未读到，请重试';
          _loading = false;
          _selected = null;
        });
      }
    }
  }

  // Page-window insertion/eviction can finish after an extra layout. Keep a
  // draft only when that settled window still contains its server candidate.
  void _reconcileSelection(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (_rows.isAppending) {
        _reconcileSelection(generation);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      setState(() {
        final selected = _selected;
        if (selected != null) {
          _selected = _rows.items
              .where((material) => material.key == selected.key)
              .firstOrNull;
        }
        _rowsReady = true;
      });
    });
  }

  bool _canSelect(WmMaterialOption material) =>
      mounted &&
      !_loading &&
      _rowsReady &&
      _error == null &&
      _loadedBoundary == ref.read(sensitiveReadBoundaryProvider) &&
      _loadedKeyword == _keyword &&
      material.goodsId.isNotEmpty &&
      _rows.items.contains(material);

  void _select(WmMaterialOption material) {
    if (_canSelect(material)) setState(() => _selected = material);
  }

  void _confirm() {
    final material = _selected;
    if (material != null && _canSelect(material)) {
      Navigator.of(context).pop(material);
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: UtenAppBar(
      showPagePermissionAction: false,
      title: '选择申请物料',
      actions: [
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        children: [
          UtenSearchBar(
            key: const Key('wm-request-material-search'),
            hint: '搜索物料名称、编号或颜色',
            onInputChanged: (value) {
              setState(() {
                _keyword = value.trim();
                _invalidate();
                _loading = true;
              });
            },
            onChanged: (_) => _load(1),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: MasterDataTableView<WmMaterialOption>(
              columns: [
                MasterColumnDef(
                  key: 'name',
                  label: '物料名称',
                  width: 200,
                  value: (material) => material.goodsName,
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'code',
                  label: '编号',
                  width: 130,
                  value: (material) => material.goodsCode,
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'color',
                  label: '颜色',
                  width: 110,
                  value: (material) => material.colorName ?? '未指定颜色',
                  columnSearchEnabled: false,
                ),
                MasterColumnDef(
                  key: 'available',
                  label: '仓库可发',
                  width: 180,
                  value: (material) =>
                      '${wmQty(material.warehouseAvailableQty, maxDecimals: 4)} ${material.unitName ?? '未设置单位'}',
                  columnSearchEnabled: false,
                ),
              ],
              items: _page?.items ?? const [],
              rowsController: _rows,
              idOf: (material) => material.key,
              rowWidgetKeyOf: (material) =>
                  ValueKey('wm-request-material-${material.key}'),
              singleTapRows: true,
              isSelected: (material) => material.key == _selected?.key,
              onRowTap: _select,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              currentPage: _page?.page ?? 1,
              totalPages: _page?.totalPages ?? 1,
              paginationScope: (widget.workshopId, _keyword, _loadedBoundary),
              isLoading: _loading && _page == null,
              loadingMore: _loading && _page != null,
              error: _error,
              onRetry: () => _load(_page?.page ?? 1),
              onPageChange: _load,
              emptyMessage: '没有找到可申请的物料，请换个关键词',
              showFullscreenToggle: false,
              showColumnChooser: false,
              enableTextSelection: false,
            ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: UtenPickerConfirmBar(
      selectedCount: _selected == null ? 0 : 1,
      selectedLabel: _selected?.displayName,
      confirmButtonKey: const Key('wm-request-material-confirm'),
      confirmEnabled: _selected != null && _canSelect(_selected!),
      onConfirm: _confirm,
    ),
  );
}
