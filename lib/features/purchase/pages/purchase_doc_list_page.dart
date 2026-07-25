// 采购单据列表页（按 docType 参数化）。
//
// 标题行(Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip) + 单据列表(分页，tap→详情)。
// 名称解析（供应商）用 MasterNameService。编辑按 edit 权限显隐"新建"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/purchase_status_badge.dart';

class PurchaseDocListPage extends ConsumerStatefulWidget {
  const PurchaseDocListPage({super.key, required this.docType});
  final PurchaseDocType docType;

  @override
  ConsumerState<PurchaseDocListPage> createState() => _PurchaseDocListPageState();
}

class _PurchaseDocListPageState extends ConsumerState<PurchaseDocListPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  PagedResult<PurchaseDocListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int? _statusFilter; // null=全部

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit => ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref.read(purchaseRepositoryProvider(widget.docType)).list(
            page: page,
            filter: PurchaseDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: _statusFilter,
            ),
          );
      if (!mounted) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载列表失败';
        _loading = false;
      });
    }
  }

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _load(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => context.go(RouteName.purchase),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(_cfg.icon, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('${_cfg.shortLabel} ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索单据号',
                          initialValue: _keyword,
                          onChanged: (v) {
                            setState(() => _keyword = v);
                            _load(1);
                          },
                        ),
                      ),
                      if (_canEdit) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: () => context.push(
                              RoutePath.purchaseDocNew(_cfg.type.pathSegment)),
                          child: const Text('新建'),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      _statusChip('全部', null),
                      _statusChip('草稿', kPurchaseStatusDraft),
                      _statusChip('已审', kPurchaseStatusApproved),
                      _statusChip('红冲', kPurchaseStatusReversed),
                    ],
                  ),
                ),
                Expanded(child: _buildBody(theme, names)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(String label, int? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _onStatus(value),
    );
  }

  Widget _buildBody(ThemeData theme, MasterNameService names) {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _page == null) {
      return Center(child: Text(_error!));
    }
    final items = _page?.items ?? const [];
    if (items.isEmpty) {
      return Center(
        child: Text('暂无${_cfg.shortLabel}单', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(1),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final it = items[i];
                return ListTile(
                  onTap: () => context.push(
                      RoutePath.purchaseDocDetail(_cfg.type.pathSegment, it.id)),
                  title: Row(
                    children: [
                      Text(it.billNo ?? '—',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      PurchaseStatusBadge(status: it.status, closed: it.closed),
                    ],
                  ),
                  subtitle: Text(
                    [
                      it.billDate ?? '',
                      if (_cfg.hasSupplier) names.supplier(it.supplierId),
                      if (it.totalLocal != null)
                        '¥${it.totalLocal!.toStringAsFixed(2)}',
                    ].join('  ·  '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: Colors.grey),
                );
              },
            ),
          ),
        ),
        if ((_page?.totalPages ?? 1) > 1) _pager(theme),
      ],
    );
  }

  Widget _pager(ThemeData theme) {
    final canPrev = (_page?.page ?? 1) > 1;
    final canNext = (_page?.page ?? 1) < (_page?.totalPages ?? 1);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: canPrev ? () => _load(_page!.page - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text('${_page?.page ?? 1} / ${_page?.totalPages ?? 1}',
                style: theme.textTheme.bodySmall),
          ),
          TextButton.icon(
            onPressed: canNext ? () => _load(_page!.page + 1) : null,
            icon: const Text('下一页'),
            label: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
