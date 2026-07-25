// 出入库流水查询页（库存管理，stock:view）：仓库筛选 + 流水列表（类型/方向/货品/仓库名解析）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../models/stock_query.dart';
import '../repositories/stock_query_repository.dart';

class StockMovementPage extends ConsumerStatefulWidget {
  const StockMovementPage({super.key});

  @override
  ConsumerState<StockMovementPage> createState() => _StockMovementPageState();
}

class _StockMovementPageState extends ConsumerState<StockMovementPage> {
  PagedResult<MovementRow>? _page;
  bool _loading = false;
  String? _warehouseId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load(1));
    });
  }

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final r = await ref.read(stockQueryRepositoryProvider).movements(
            page: page,
            warehouseId: _warehouseId,
          );
      final goodsIds = r.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() => _page = r);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('加载失败')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final items = _page?.items ?? const [];
    return Scaffold(
      appBar: UtenAppBar(
        title: '出入库流水',
        leading: UtenBackButton(onPressed: () => context.go(RouteName.purchase)),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(children: [
                  const Text('仓库：'),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _warehouseId,
                      isDense: true,
                      items: [
                        const DropdownMenuItem<String?>(child: Text('全部仓库')),
                        for (final e in names.warehouseEntries.entries)
                          DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) {
                        setState(() => _warehouseId = v);
                        _load(1);
                      },
                    ),
                  ),
                ]),
              ),
              Expanded(
                child: _loading && _page == null
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final m = items[i];
                          final isIn = m.direction == 1;
                          return ListTile(
                            title: Text(names.goods(m.goodsId)),
                            subtitle: Text(
                              [
                                movementTypeLabel(m.movementType),
                                names.warehouse(m.warehouseId),
                                (m.transactionDate ?? '').substring(0, 10),
                              ].join('  ·  '),
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Text(
                              '${isIn ? '+' : '-'}${(m.qty ?? 0).toStringAsFixed(2)}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: isIn ? Colors.green : Colors.red,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if ((_page?.totalPages ?? 1) > 1) _pager(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pager() {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: (_page?.page ?? 1) > 1 ? () => _load(_page!.page - 1) : null,
            child: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text('${_page?.page ?? 1} / ${_page?.totalPages ?? 1}'),
          ),
          TextButton(
            onPressed: (_page?.page ?? 1) < (_page?.totalPages ?? 1)
                ? () => _load(_page!.page + 1)
                : null,
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }
}
