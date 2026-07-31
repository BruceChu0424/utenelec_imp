// 货品资料页"特殊货品集合区":禁用货品 / 不明货品(迁移 stub)两个可展开行。
// 插在货品标题行与 MasterDataTableView 之间。N=0 的集合不渲染;均默认折叠。
//
// 关键约束:stub 的 category_id 全 NULL,不在任何分类子树(含"未分类"节点)下。
// 故"不明货品"集合的查询强制 categoryId=null(否则 category_id IN (子树) 与 IS NULL
// 永远矛盾,返回 0 条);该集合仅在选中"未分类(历史孤儿)"节点时出现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../repositories/goods_repository.dart';

/// 货品资料页右表"特殊货品集合区"。
class SpecialGoodsCollections extends ConsumerStatefulWidget {
  const SpecialGoodsCollections({
    super.key,
    required this.categoryId,
    required this.isOrphanNode,
    required this.onItemTap,
  });

  /// 当前选中分类 id(普通分类传当前节点;stub 查询内部自传 null)。
  final String? categoryId;

  /// 是否"未分类(历史孤儿)"节点(code=='LEGACY_ORPHAN');true 才显示"不明货品"集合。
  final bool isOrphanNode;

  /// 点击条目 → 复用货品页 _showGoodsDetail(id)。
  final void Function(String goodsId) onItemTap;

  @override
  ConsumerState<SpecialGoodsCollections> createState() =>
      _SpecialGoodsCollectionsState();
}

class _SpecialGoodsCollectionsState
    extends ConsumerState<SpecialGoodsCollections> {
  PagedResult<GoodsListItem>? _disabledPage;
  PagedResult<GoodsListItem>? _stubPage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SpecialGoodsCollections old) {
    super.didUpdateWidget(old);
    if (old.categoryId != widget.categoryId ||
        old.isOrphanNode != widget.isOrphanNode) {
      _load();
    }
  }

  Future<void> _load() async {
    final repo = ref.read(goodsRepositoryProvider);
    // 禁用集合:当前分类子树内 status='禁用'。
    // 不明集合:仅未分类节点显示;stub 无分类 → 查询不带 categoryId(传 null)。
    final futures = <Future<PagedResult<GoodsListItem>?>>[
      repo.list(widget.categoryId, disabledOnly: true, size: 500),
      widget.isOrphanNode
          ? repo.list(null, stubOnly: true, size: 500)
          : Future<PagedResult<GoodsListItem>?>.value(),
    ];
    try {
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _disabledPage = results[0];
        _stubPage = results[1];
      });
    } catch (_) {
      // 集合区是辅助视图,失败静默(不影响主表)。
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _disabledPage;
    final stub = _stubPage;
    final canShowStub = widget.isOrphanNode;
    if ((disabled == null || disabled.total == 0) &&
        (!canShowStub || stub == null || stub.total == 0)) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        if (disabled != null && disabled.total > 0)
          _collectionTile(
            context,
            icon: Icons.block_rounded,
            color: Colors.red.shade700,
            title: '禁用货品（${disabled.total}）',
            subtitle: '当前分类子树内已停用的货品',
            page: disabled,
          ),
        if (canShowStub && stub != null && stub.total > 0)
          _collectionTile(
            context,
            icon: Icons.help_outline_rounded,
            color: Colors.amber.shade800,
            title: '不明货品（${stub.total}）',
            subtitle: '迁移兜底占位（auto_created），无分类归属',
            page: stub,
          ),
      ],
    );
  }

  Widget _collectionTile(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required PagedResult<GoodsListItem> page,
  }) {
    final theme = Theme.of(context);
    final count = page.items.length;
    // ExpansionTile 默认 initiallyExpanded=false,即默认折叠(用户要求)。
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        title,
        style:
            theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      children: [
        SizedBox(
          // 定高,避免 31 条 stub 撑爆挤压主表。
          height: count <= 5 ? count * 56.0 : 280.0,
          child: ListView.separated(
            itemCount: count,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final g = page.items[i];
              final sub = [g.spec, g.colorName, g.unitName]
                  .where((s) => s != null && s.isNotEmpty)
                  .join(' · ');
              return ListTile(
                dense: true,
                title: Text(
                  '${g.name ?? '—'}'
                  '${g.code != null && g.code!.isNotEmpty ? '（${g.code}）' : ''}',
                ),
                subtitle: sub.isEmpty
                    ? null
                    : Text(sub, style: const TextStyle(fontSize: 12)),
                trailing: page.totalPages > 1
                    ? Text(
                        '${page.page}/${page.totalPages}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      )
                    : null,
                onTap: () => widget.onItemTap(g.id),
              );
            },
          ),
        ),
      ],
    );
  }
}
