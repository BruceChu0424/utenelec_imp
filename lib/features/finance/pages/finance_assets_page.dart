// 固定资产 + 长期待摊 管理页（C5）：双 Tab 列表 + 新建/编辑/删除 + 期间计提。
// 后端：/api/finance/fixed-assets|deferred-expenses（CRUD）、/api/finance/fa/depreciate|amortize（计提）。
// 计提幂等：同一期间可重复点，后端先回滚该期间凭证再重建。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../repositories/finance_asset_repository.dart';

class FinanceAssetsPage extends ConsumerStatefulWidget {
  const FinanceAssetsPage({super.key});

  @override
  ConsumerState<FinanceAssetsPage> createState() => _FinanceAssetsPageState();
}

class _FinanceAssetsPageState extends ConsumerState<FinanceAssetsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  PagedResult<Map<String, dynamic>>? _assets;
  PagedResult<Map<String, dynamic>>? _deferred;
  int _assetPage = 1;
  int _deferredPage = 1;
  bool _loading = false;
  bool _busy = false;

  bool get _isAssetTab => _tab.index == 0;
  FinanceAssetLedger get _ledger => _isAssetTab
      ? FinanceAssetLedger.fixedAsset
      : FinanceAssetLedger.deferredExpense;
  int get _currentPage => _isAssetTab ? _assetPage : _deferredPage;
  PagedResult<Map<String, dynamic>>? get _currentResult =>
      _isAssetTab ? _assets : _deferred;

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (!_tab.indexIsChanging) setState(() {});
    });
    _load(both: true);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load({bool both = false}) async {
    setState(() => _loading = true);
    final repository = ref.read(financeAssetRepositoryProvider);
    try {
      PagedResult<Map<String, dynamic>>? assets;
      PagedResult<Map<String, dynamic>>? deferred;
      if (both) {
        final results = await Future.wait([
          repository.list(FinanceAssetLedger.fixedAsset, page: _assetPage),
          repository.list(
            FinanceAssetLedger.deferredExpense,
            page: _deferredPage,
          ),
        ]);
        assets = results[0];
        deferred = results[1];
      } else if (_isAssetTab) {
        assets = await repository.list(_ledger, page: _assetPage);
        if (assets.items.isEmpty &&
            _assetPage > 1 &&
            assets.totalPages < _assetPage) {
          _assetPage = assets.totalPages.clamp(1, _assetPage);
          assets = await repository.list(_ledger, page: _assetPage);
        }
      } else {
        deferred = await repository.list(_ledger, page: _deferredPage);
        if (deferred.items.isEmpty &&
            _deferredPage > 1 &&
            deferred.totalPages < _deferredPage) {
          _deferredPage = deferred.totalPages.clamp(1, _deferredPage);
          deferred = await repository.list(_ledger, page: _deferredPage);
        }
      }
      if (!mounted) return;
      setState(() {
        if (assets != null) _assets = assets;
        if (deferred != null) _deferred = deferred;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      context.appError('加载失败：$e');
      setState(() => _loading = false);
    }
  }

  Future<void> _goToPage(int page) async {
    if (_loading || page == _currentPage) return;
    setState(() {
      if (_isAssetTab) {
        _assetPage = page;
      } else {
        _deferredPage = page;
      }
    });
    await _load();
  }

  /// 计提（幂等）：输入期间 YYYY-MM → 后端先回滚再重建该期间凭证。
  Future<void> _post() async {
    final ctrl = TextEditingController(
      text:
          '${ChinaDateTime.today().year}-${ChinaDateTime.today().month.toString().padLeft(2, '0')}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isAssetTab ? '计提折旧' : '计提摊销'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '计提期间（YYYY-MM）',
            hintText: '2026-07',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('计提'),
          ),
        ],
      ),
    );
    final period = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true) return;
    if (!mounted) return;
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(period)) {
      context.appError('期间格式应为 YYYY-MM');
      return;
    }
    setState(() => _busy = true);
    try {
      final count = await ref
          .read(financeAssetRepositoryProvider)
          .postPeriod(_ledger, period);
      if (!mounted) return;
      context.appSuccess(
        '${_isAssetTab ? '折旧' : '摊销'}计提完成：$period，'
        '$count 笔（凭证已入总账）',
      );
    } catch (e) {
      if (mounted) context.appError('计提失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final isNew = row == null;
    final code = TextEditingController(text: row?['code']?.toString() ?? '');
    final name = TextEditingController(text: row?['name']?.toString() ?? '');
    final amount = TextEditingController(
      text:
          (row?[_isAssetTab ? 'original_value' : 'total_amount'])?.toString() ??
          '',
    );
    final salvage = TextEditingController(
      text: row?['salvage_rate']?.toString() ?? '0.05',
    );
    final months = TextEditingController(
      text: row?['useful_months']?.toString() ?? '',
    );
    final start = TextEditingController(
      text: row?['start_period']?.toString() ?? '',
    );
    String status = row?['status']?.toString() ?? (_isAssetTab ? '在用' : '摊销中');
    final statuses = _isAssetTab
        ? const ['在用', '停用', '清理']
        : const ['摊销中', '已摊完', '停用'];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(
            isNew ? '新建${_isAssetTab ? '固定资产' : '长期待摊'}' : '编辑 ${row['code']}',
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: code,
                  enabled: isNew,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '编号 *',
                  ),
                ),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '名称 *',
                  ),
                ),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _isAssetTab ? '原值 *' : '待摊总额 *',
                  ),
                ),
                if (_isAssetTab)
                  TextField(
                    controller: salvage,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '残值率（如 0.05）',
                    ),
                  ),
                TextField(
                  controller: months,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _isAssetTab ? '使用年限（月）*' : '摊销月数 *',
                  ),
                ),
                TextField(
                  controller: start,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '开始期间（YYYY-MM）*',
                    hintText: '2026-07',
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '状态',
                  ),
                  items: [
                    for (final s in statuses)
                      DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => setD(() => status = v ?? status),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isNew ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final body = <String, dynamic>{
      'code': code.text.trim(),
      'name': name.text.trim(),
      if (_isAssetTab) 'originalValue': double.tryParse(amount.text),
      if (!_isAssetTab) 'totalAmount': double.tryParse(amount.text),
      if (_isAssetTab) 'salvageRate': double.tryParse(salvage.text),
      'usefulMonths': int.tryParse(months.text),
      'startPeriod': start.text.trim(),
      'status': status,
    };
    for (final c in [code, name, amount, salvage, months, start]) {
      c.dispose();
    }
    if ((body['code'] as String).isEmpty || (body['name'] as String).isEmpty) {
      context.appError('编号/名称必填');
      return;
    }
    setState(() => _busy = true);
    try {
      final repository = ref.read(financeAssetRepositoryProvider);
      if (isNew) {
        await repository.create(_ledger, body);
        if (_isAssetTab) {
          _assetPage = 1;
        } else {
          _deferredPage = 1;
        }
      } else {
        await repository.update(_ledger, row['id'].toString(), body);
      }
      if (!mounted) return;
      context.appSuccess(isNew ? '已创建' : '已保存');
      await _load();
    } catch (e) {
      if (mounted) context.appError('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('删除 ${row['code']} ${row['name']}？（历史计提凭证保留）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(financeAssetRepositoryProvider)
          .delete(_ledger, row['id'].toString());
      if (!mounted) return;
      context.appSuccess('已删除');
      await _load();
    } catch (e) {
      if (mounted) context.appError('删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '资产与待摊',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '固定资产'),
            Tab(text: '长期待摊'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                child: Row(
                  children: [
                    Text(
                      _isAssetTab ? '直线法：月折旧=原值×(1−残值率)/月数' : '直线法：月摊销=总额/月数',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      icon: Icons.play_circle_outline,
                      onPressed: _busy ? null : _post,
                      child: Text(
                        _busy ? '处理中…' : (_isAssetTab ? '计提折旧' : '计提摊销'),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      icon: Icons.add,
                      onPressed: _busy ? null : () => _edit(),
                      child: Text(_isAssetTab ? '新建资产' : '新建待摊'),
                    ),
                  ],
                ),
              ),
              Expanded(child: _table(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _table(ThemeData theme) {
    final result = _currentResult;
    if (_loading || result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = result.items;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          '暂无数据，点右上角「${_isAssetTab ? '新建资产' : '新建待摊'}」开始',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    String money(Object? v) => v == null ? '—' : (v as num).toStringAsFixed(2);
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: rows.length + 1,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      _th('编号', 1),
                      _th('名称', 2),
                      _th(_isAssetTab ? '原值' : '总额', 1),
                      _th(_isAssetTab ? '月折旧' : '月摊销', 1),
                      _th('开始期间', 1),
                      _th('状态', 1),
                      _th('操作', 1),
                    ],
                  ),
                );
              }
              final r = rows[i - 1];
              final amount =
                  r[_isAssetTab ? 'original_value' : 'total_amount'] as num?;
              final months = r['useful_months'] as num?;
              final salvage = _isAssetTab
                  ? (r['salvage_rate'] as num? ?? 0.05)
                  : 0;
              final monthly = (amount != null && months != null && months > 0)
                  ? (_isAssetTab
                        ? amount * (1 - salvage) / months
                        : amount / months)
                  : null;
              return Padding(
                key: ValueKey(r['id']),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    _td(r['code']?.toString(), 1),
                    _td(r['name']?.toString(), 2),
                    _td(money(amount), 1),
                    _td(monthly == null ? '—' : monthly.toStringAsFixed(2), 1),
                    _td(r['start_period']?.toString(), 1),
                    _td(r['status']?.toString(), 1),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            tooltip: '编辑',
                            onPressed: () => _edit(r),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除',
                            onPressed: () => _delete(r),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (result.totalPages > 1)
          UtenGridPager(
            currentPage: result.page,
            totalPages: result.totalPages,
            totalItems: result.total,
            onPrev: result.page > 1 ? () => _goToPage(result.page - 1) : null,
            onNext: result.page < result.totalPages
                ? () => _goToPage(result.page + 1)
                : null,
          ),
      ],
    );
  }

  Widget _th(String t, int flex) => Expanded(
    flex: flex,
    child: Text(
      t,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget _td(String? t, int flex) => Expanded(
    flex: flex,
    child: Text(
      t ?? '—',
      style: const TextStyle(fontSize: 12),
      overflow: TextOverflow.ellipsis,
    ),
  );
}
