import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_paged_picker_list.dart';
import '../../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../shared/models/paged_result.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';

Future<CountStockRow?> showStockCountCandidatePicker(
  BuildContext context, {
  required StockCountWarehouse warehouse,
}) => showUtenAdaptivePanel<CountStockRow>(
  context: context,
  drawerWidth: 760,
  builder: (_) => _CandidatePicker(warehouse: warehouse),
);

class _CandidatePicker extends ConsumerStatefulWidget {
  const _CandidatePicker({required this.warehouse});
  final StockCountWarehouse warehouse;
  @override
  ConsumerState<_CandidatePicker> createState() => _CandidatePickerState();
}

class _CandidatePickerState extends ConsumerState<_CandidatePicker> {
  PagedResult<CountStockRow>? _page;
  CountStockRow? _selected;
  String _keyword = '';
  String? _error;
  bool _loading = true;
  int _generation = 0;
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
          .read(stockCountRequestRepositoryProvider)
          .candidates(
            warehouseId: widget.warehouse.id,
            keyword: _keyword,
            page: page,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error is ApiException ? error.message : '物料清单未读到，请重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: Text('添加盘点物料 · ${widget.warehouse.name}'),
      actions: [
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        children: [
          const Text('选择已有货品和颜色；没有库存记录的物料也可以登记实盘数量。'),
          const SizedBox(height: UtenSpacing.s8),
          UtenSearchBar(
            key: const Key('stock-count-candidate-search'),
            hint: '搜索名称、编号或颜色',
            onInputChanged: (value) {
              ++_generation;
              setState(() {
                _keyword = value.trim();
                _page = null;
                _selected = null;
                _loading = true;
              });
            },
            onChanged: (_) => _load(1),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: UtenPagedPickerList<CountStockRow>(
              items: _page?.items ?? const [],
              idOf: (row) => row.key,
              currentPage: _page?.page ?? 1,
              totalPages: _page?.totalPages ?? 1,
              paginationScope: '${widget.warehouse.id}|$_keyword',
              loading: _loading,
              error: _error,
              onRetry: () => _load(_page?.page ?? 1),
              onPageChange: _load,
              itemBuilder: (context, row) => ListTile(
                key: ValueKey('stock-count-candidate-${row.key}'),
                selected: _selected?.key == row.key,
                enabled: !_loading && row.canEdit,
                title: Text(
                  [row.goodsName, row.colorName].whereType<String>().join(' '),
                ),
                subtitle: Text(
                  '${row.goodsCode} · 当前 ${row.qty} ${row.unitName} · 重量 ${row.weightKg == null ? '未称' : '${row.weightKg} kg'}',
                ),
                trailing: _selected?.key == row.key
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => setState(() => _selected = row),
              ),
            ),
          ),
          UtenPickerConfirmBar(
            selectedCount: _selected == null ? 0 : 1,
            onConfirm: _loading
                ? null
                : () => Navigator.pop(context, _selected),
          ),
        ],
      ),
    ),
  );
}
