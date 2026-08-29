import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_finished_inbound_task.dart';
import '../models/stock_doc.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

class ProductionFinishedInboundTasksPage extends ConsumerStatefulWidget {
  const ProductionFinishedInboundTasksPage({super.key});

  @override
  ConsumerState<ProductionFinishedInboundTasksPage> createState() =>
      _ProductionFinishedInboundTasksPageState();
}

class _ProductionFinishedInboundTasksPageState
    extends ConsumerState<ProductionFinishedInboundTasksPage> {
  PagedResult<ProductionFinishedInboundTask>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _search(String value) async {
    setState(() => _keyword = value);
    await _load(1);
  }

  Future<void> _load(int page) async {
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .tasks(page: page, keyword: _keyword);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待点收任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(
      RouteName.warehouseProductionFinishedInboundTasks,
      () => _load(_result?.page ?? 1),
    );
    final result = _result;
    final permissions = ref.watch(currentPermissionsProvider);
    final canCount =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.stockDocApprove);
    return Scaffold(
      appBar: UtenAppBar(
        title: '产成品待点收',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(result, canCount: canCount),
      ),
    );
  }

  Widget _buildList(
    PagedResult<ProductionFinishedInboundTask>? value, {
    required bool canCount,
  }) {
    final result =
        value ??
        const PagedResult<ProductionFinishedInboundTask>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
        );
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(result.page),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            UtenSearchBar(
              hint: '搜索入库单 / 生产单 / 报工单 / 货品',
              initialValue: _keyword,
              onChanged: _search,
            ),
            const SizedBox(height: UtenSpacing.s16),
            _TaskSummary(total: result.total),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              const SizedBox(
                height: 360,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: '目前没有待点收的产成品',
                  description: '生产报工或品质放行形成的入库任务会自动出现在这里；通知已读或丢失不会影响本队列。',
                ),
              )
            else
              for (var index = 0; index < result.items.length; index++) ...[
                _FinishedInboundTaskCard(
                  key: ValueKey(
                    'finished-inbound-task-'
                    '${result.items[index].documentId}',
                  ),
                  task: result.items[index],
                  canCount: canCount,
                  onOpen: () => goFrom(
                    context,
                    RoutePath.stockDocDetail(
                      StockDocType.finishedIn.code,
                      result.items[index].documentId,
                    ),
                  ),
                ),
                if (index != result.items.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s8,
                children: [
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_left_rounded,
                    onPressed: !_loading && result.page > 1
                        ? () => _load(result.page - 1)
                        : null,
                    child: const Text('上一页'),
                  ),
                  Text('第 ${result.page} / ${result.totalPages} 页'),
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_right_rounded,
                    onPressed: !_loading && result.page < result.totalPages
                        ? () => _load(result.page + 1)
                        : null,
                    child: const Text('下一页'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.42),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(
              Icons.inventory_2_outlined,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '待点收 $total 单',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                const Text('请按实物逐行确认。只有仓库确认的合格数量才增加库存和生产入库完成率。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FinishedInboundTaskCard extends StatelessWidget {
  const _FinishedInboundTaskCard({
    super.key,
    required this.task,
    required this.canCount,
    required this.onOpen,
  });

  final ProductionFinishedInboundTask task;
  final bool canCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: canCount
          ? '打开产成品入库单 ${task.documentNo} 进行实收点收'
          : '查看产成品待点收入库单 ${task.documentNo}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenStatusBadge(
                      label: task.residualTask ? '短收余量待点收' : '待点收',
                      type: UtenStatusBadgeType.warning,
                    ),
                    Text(
                      task.documentNo,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                _line('生产计划', task.planNo ?? '—'),
                _line('报工单', task.reportNos ?? '—'),
                _line('仓库', task.warehouseName ?? '—'),
                _line('货品', task.goodsSummary ?? '—'),
                _line(
                  '待点收',
                  '${_quantity(task.pendingQty)}，共 ${task.lineCount} 行',
                ),
                _line('单据日期', ChinaDateTime.formatDate(task.documentDate)),
                const SizedBox(height: UtenSpacing.s8),
                SizedBox(
                  width: double.infinity,
                  child: UtenButton(
                    size: UtenButtonSize.large,
                    icon: canCount
                        ? Icons.inventory_rounded
                        : Icons.visibility_outlined,
                    onPressed: onOpen,
                    child: Text(canCount ? '进入逐行点收' : '查看待点收详情'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 88, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
