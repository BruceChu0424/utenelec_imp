// 货品选择对话框（编辑明细行选货品用）：关键词搜索 → 列表 → 选中返回 GoodsOption。
//
// 用 MasterNameService.searchGoods（/master/goods?keyword=）。防抖 300ms。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/master_name_provider.dart';

Future<GoodsOption?> showGoodsPickerDialog(BuildContext context, WidgetRef ref) {
  return showDialog<GoodsOption>(
    context: context,
    builder: (_) => const _GoodsPickerDialog(),
  );
}

class _GoodsPickerDialog extends ConsumerStatefulWidget {
  const _GoodsPickerDialog();

  @override
  ConsumerState<_GoodsPickerDialog> createState() => _GoodsPickerDialogState();
}

class _GoodsPickerDialogState extends ConsumerState<_GoodsPickerDialog> {
  final _ctrl = TextEditingController();
  final _results = <GoodsOption>[];
  bool _loading = false;
  Timer? _debounce;

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String v) async {
    setState(() => _loading = true);
    try {
      final r = await ref.read(masterNameServiceProvider).searchGoods(v);
      if (!mounted) return;
      setState(() {
        _results
          ..clear()
          ..addAll(r);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Text('选择货品',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '输入货品编号/名称搜索',
                  isDense: true,
                ),
                onChanged: _onChanged,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _ctrl.text.isEmpty ? '输入关键词搜索' : '无匹配货品',
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final g = _results[i];
                            return ListTile(
                              title: Text(g.name ?? '—'),
                              subtitle: Text(g.code ?? '',
                                  style: const TextStyle(fontSize: 12)),
                              onTap: () => Navigator.pop(ctx, g),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
