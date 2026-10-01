import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_paged_picker_list.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../shared/models/paged_result.dart';
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
  PagedResult<WmMaterialOption>? _page;
  String _keyword = '';
  String? _error;
  int _generation = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  Future<void> _load(int page) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(workshopMaterialRepositoryProvider)
          .requestMaterials(widget.workshopId, keyword: _keyword, page: page);
      if (mounted && generation == _generation) {
        setState(() {
          _page = result;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is ApiException ? error.message : '物料未读到，请重试';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const Text('选择申请物料'),
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
              ++_generation;
              setState(() {
                _keyword = value.trim();
                _page = null;
                _loading = true;
              });
            },
            onChanged: (_) => _load(1),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: UtenPagedPickerList<WmMaterialOption>(
              items: _page?.items ?? const [],
              idOf: (material) => material.key,
              currentPage: _page?.page ?? 1,
              totalPages: _page?.totalPages ?? 1,
              paginationScope: '${widget.workshopId}|$_keyword',
              loading: _loading,
              error: _error,
              onRetry: () => _load(_page?.page ?? 1),
              onPageChange: _load,
              emptyMessage: '没有找到可申请的物料，请换个关键词',
              itemBuilder: (context, material) => ListTile(
                key: ValueKey('wm-request-material-${material.key}'),
                title: Text(material.displayName),
                subtitle: Text(
                  [
                    if (material.goodsCode?.isNotEmpty == true)
                      material.goodsCode!,
                    '单位：${material.unitName ?? '未设置'}',
                    '仓库可发 ${wmQty(material.warehouseAvailableQty, maxDecimals: 4)} ${material.unitName ?? ''}',
                  ].join(' · '),
                ),
                onTap: _loading
                    ? null
                    : () => Navigator.of(context).pop(material),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
