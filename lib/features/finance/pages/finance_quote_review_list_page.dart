// 销售报价财务核价队列(/finance/quote-review，ADR-134)。
//
// 报价不再由销售自审：销售「提交财务核价」后进本页「待核价」；财务认领后逐行定价格和
// 折扣(没有标价的货品由财务直接定价)，确认后销售才能转订货单，退回则带原因回到销售。
//
// 三个分段：
//   · 待核价 —— 等财务动手 → 红徽章(徽章入口 financeQuoteReview，与 hub 卡同源)；
//   · 已核价 —— 已结束 → 不挂数；
//   · 已退回 —— 球在销售手上、还会回来 → 黄色进行中(ADR-100，页内分段不进入口)。
// 服务端搜索/分页；桌面用统一表格(单击选中、双击核价)，紧凑端用卡片列表 + 显式按钮。
// 本页不在前端拼权限：进入由路由守卫(sales_quote_finance:view)把关，能不能改价、退回、
// 确认由详情里服务端下发的 financeActions 决定。待核价行说明里带「谁正在核价」(服务端认领)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_quote_finance_review.dart';
import '../repositories/sales_quote_finance_review_repository.dart';

/// 核价详情办结(确认/退回)后 bump 的列表刷新键。
const kQuoteFinanceListRefreshKey = 'finance:quote-review';

class FinanceQuoteReviewListPage extends ConsumerStatefulWidget {
  const FinanceQuoteReviewListPage({super.key, this.initialState});

  /// 深链预选分段(?state=pending|confirmed|returned)；缺省 = 待核价。
  final String? initialState;

  @override
  ConsumerState<FinanceQuoteReviewListPage> createState() =>
      _FinanceQuoteReviewListPageState();
}

class _FinanceQuoteReviewListPageState
    extends ConsumerState<FinanceQuoteReviewListPage> {
  late SalesQuoteFinanceState _state;
  PagedResult<SalesQuoteFinanceListItem>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;
  SalesQuoteFinanceListItem? _activeItem;

  /// 「已退回」段全量张数(黄色进行中)；null = 尚未取到，不渲染。
  int? _returnedCount;
  String? _hostLocation;

  @override
  void initState() {
    super.initState();
    _state = SalesQuoteFinanceState.values.firstWhere(
      (state) => state.query == widget.initialState,
      orElse: () => SalesQuoteFinanceState.pending,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void dispose() {
    ++_requestVersion;
    super.dispose();
  }

  SalesQuoteFinanceReviewRepository get _repo =>
      ref.read(salesQuoteFinanceReviewRepositoryProvider);

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_state != SalesQuoteFinanceState.returned || _keyword.isNotEmpty) {
      unawaited(_loadReturnedCount());
    }
    try {
      final result = await _repo.list(
        state: _state,
        page: page,
        keyword: _keyword.isEmpty ? null : _keyword,
      );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        if (_activeItem != null &&
            !result.items.any((item) => item.quoteId == _activeItem!.quoteId)) {
          _activeItem = null;
        }
        if (_state == SalesQuoteFinanceState.returned && _keyword.isEmpty) {
          _returnedCount = result.total;
        }
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = AppLocalizations.of(context).quoteFinanceLoadFailed;
        _loading = false;
      });
    }
  }

  /// 「已退回」段全量张数(size=1 只取 total；失败保持旧值，不把未知说成 0)。
  Future<void> _loadReturnedCount() async {
    try {
      final page = await _repo.list(
        state: SalesQuoteFinanceState.returned,
        size: 1,
      );
      if (mounted) setState(() => _returnedCount = page.total);
    } catch (_) {
      // 计数失败静默：分段不显示数字，不影响列表。
    }
  }

  void _switchState(SalesQuoteFinanceState next) {
    if (next == _state) return;
    ++_requestVersion;
    setState(() {
      _state = next;
      _result = null;
      _error = null;
      _activeItem = null;
    });
    _load(1);
  }

  void _applyKeyword(String value) {
    final next = value.trim();
    if (next == _keyword) return;
    setState(() {
      _keyword = next;
      _result = null;
      _activeItem = null;
    });
    _load(1);
  }

  Future<void> _refresh() async {
    refreshBadges(ref);
    await _load(_result?.page ?? 1);
  }

  /// 打开核价详情；确认/退回后返回 true → 重拉当前页与徽章。
  Future<void> _open(SalesQuoteFinanceListItem item) async {
    final changed = await context.push<bool>(
      RoutePath.financeQuoteReview(item.quoteId),
    );
    if (changed == true && mounted) {
      setState(() => _activeItem = null);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _hostLocation ??= currentLocationOr(context, RouteName.financeQuoteReview);
    // 详情页办结 bump：本页在栈顶时立即重拉，被盖着时返回再拉(ADR-108)。
    ref.onListRefresh(_hostLocation!, kQuoteFinanceListRefreshKey, () {
      if (mounted) _refresh();
    });
    final body = SafeArea(
      child: _loading && _result == null
          ? const UtenSkeletonList()
          : _error != null && _result == null
          ? UtenEmpty.error(
              message: _error,
              actionLabel: l10n.quoteFinanceRetry,
              onAction: () => _load(1),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final result =
                    _result ??
                    const PagedResult<SalesQuoteFinanceListItem>(
                      items: [],
                      page: 1,
                      size: 20,
                      total: 0,
                      totalPages: 1,
                    );
                return UtenContentContainer.wide(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s16,
                    ),
                    child: breakpointForWidth(constraints.maxWidth).isExpanded
                        ? _desktop(context, l10n, result)
                        : _compact(context, l10n, result),
                  ),
                );
              },
            ),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.quoteFinanceListTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          UtenAppBarActionButton(
            key: const Key('quote-finance-refresh'),
            label: l10n.quoteFinanceRefresh,
            icon: Icons.refresh_rounded,
            isLoading: _loading,
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _filters(AppLocalizations l10n) {
    final pendingCount = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.financeQuoteReview),
    );
    return UtenFilterToolbar<SalesQuoteFinanceState>(
      segmentsKey: const Key('quote-finance-tabs'),
      searchKey: const Key('quote-finance-search'),
      compactBreakpoint: UtenBreakpoints.mediumStart,
      segments: [
        UtenFilterSegment(
          value: SalesQuoteFinanceState.pending,
          label: l10n.quoteFinanceTabPending,
          count: pendingCount,
          countForm: UtenSegmentCountForm.actionable,
        ),
        UtenFilterSegment(
          value: SalesQuoteFinanceState.confirmed,
          label: l10n.quoteFinanceTabConfirmed,
        ),
        UtenFilterSegment(
          value: SalesQuoteFinanceState.returned,
          label: l10n.quoteFinanceTabReturned,
          count: _returnedCount,
          countForm: UtenSegmentCountForm.inProgress,
        ),
      ],
      selected: {_state},
      onSelectionChanged: _switchState,
      searchHint: l10n.quoteFinanceSearchHint,
      initialSearchValue: _keyword,
      onSearchInputChanged: (_) => ++_requestVersion,
      onSearchChanged: _applyKeyword,
      trailing: Text(
        l10n.quoteFinanceRowHint,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _desktop(
    BuildContext context,
    AppLocalizations l10n,
    PagedResult<SalesQuoteFinanceListItem> result,
  ) {
    final theme = Theme.of(context);
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _filters(l10n),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _InlineError(
              message: _error!,
              retryLabel: l10n.quoteFinanceRetry,
              onRetry: () => _load(result.page),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
      body: MasterDataTableView<SalesQuoteFinanceListItem>(
        key: const Key('quote-finance-desktop-table'),
        primary: true,
        columns: _columns(l10n),
        items: result.items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: _open,
        onSelectionChanged: (item) => setState(() => _activeItem = item),
        onSelectionCleared: () => setState(() => _activeItem = null),
        rowMenuBuilder: (item) => [
          UtenMenuItem(
            label: l10n.quoteFinanceOpen,
            icon: Icons.price_check_rounded,
            onTap: () => _open(item),
          ),
        ],
        rowColor: (item) => _rowColor(theme, item),
        isLoading: _loading,
        emptyMessage: _emptyMessage(l10n),
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _load,
        toolbarActions: [
          UtenButton(
            key: const Key('quote-finance-open-selected'),
            size: UtenButtonSize.large,
            icon: Icons.price_check_rounded,
            onPressed: _activeItem == null ? null : () => _open(_activeItem!),
            child: Text(l10n.quoteFinanceOpen),
          ),
        ],
      ),
    );
  }

  Widget _compact(
    BuildContext context,
    AppLocalizations l10n,
    PagedResult<SalesQuoteFinanceListItem> result,
  ) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const Key('quote-finance-mobile-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
        children: [
          _filters(l10n),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _InlineError(
              message: _error!,
              retryLabel: l10n.quoteFinanceRetry,
              onRetry: () => _load(result.page),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (result.items.isEmpty)
            SizedBox(
              height: 320,
              child: UtenEmpty(
                icon: _state == SalesQuoteFinanceState.returned
                    ? Icons.undo_rounded
                    : Icons.price_check_rounded,
                message: _emptyMessage(l10n),
                description: _emptyDescription(l10n),
              ),
            )
          else
            for (final item in result.items) ...[
              _CompactQuoteRow(
                key: Key('quote-finance-row-${item.quoteId}'),
                item: item,
                statusText: _statusText(l10n, item),
                accent: _accentColor(Theme.of(context), item),
                openLabel: l10n.quoteFinanceOpen,
                amountText: _amountText(item),
                submittedLabel: l10n.quoteFinanceColSubmittedAt,
                onOpen: () => _open(item),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          if (result.totalPages > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: l10n.quoteFinancePrevPage,
                  onPressed: _loading || result.page <= 1
                      ? null
                      : () => _load(result.page - 1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Text('${result.page} / ${result.totalPages}'),
                IconButton(
                  tooltip: l10n.quoteFinanceNextPage,
                  onPressed: _loading || result.page >= result.totalPages
                      ? null
                      : () => _load(result.page + 1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<MasterColumnDef<SalesQuoteFinanceListItem>> _columns(
    AppLocalizations l10n,
  ) => [
    MasterColumnDef(
      key: 'billNo',
      label: l10n.quoteFinanceColBillNo,
      width: 160,
      value: (item) => item.billNo,
    ),
    MasterColumnDef(
      key: 'clientName',
      label: l10n.quoteFinanceColClient,
      width: 200,
      value: (item) => item.clientName ?? l10n.quoteFinanceUnnamed,
    ),
    MasterColumnDef(
      key: 'sellerName',
      label: l10n.quoteFinanceColSeller,
      width: 112,
      value: (item) => item.sellerName ?? '—',
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: l10n.quoteFinanceColSubmittedAt,
      width: 150,
      type: 'date',
      value: (item) =>
          item.submittedAt == null ? '—' : utenFmtIsoTime(item.submittedAt),
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: l10n.quoteFinanceColLines,
      width: 84,
      type: 'number',
      value: (item) => '${item.lineCount}',
    ),
    MasterColumnDef(
      key: 'totalOriginal',
      label: l10n.quoteFinanceColAmount,
      width: 150,
      type: 'money',
      value: _amountText,
    ),
    MasterColumnDef(
      key: 'status',
      label: l10n.quoteFinanceColStatus,
      width: 280,
      value: (item) => _statusText(l10n, item),
      cellBuilder: (context, item) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: UtenStatusBadge(
          label: _statusText(l10n, item),
          type: _statusType(item),
          size: UtenStatusBadgeSize.small,
        ),
      ),
    ),
  ];

  /// 报价金额按本币(报价只允许本币)；服务端十进制原文，不经过 double。
  String _amountText(SalesQuoteFinanceListItem item) {
    final raw = item.totalOriginal;
    return raw == null ? '—' : financeExactMoneyDisplay(raw);
  }

  String _statusText(AppLocalizations l10n, SalesQuoteFinanceListItem item) {
    switch (_state) {
      case SalesQuoteFinanceState.returned:
        return l10n.quoteFinanceStatusReturned(
          item.financeReturnReason ?? l10n.quoteFinanceTabReturned,
        );
      case SalesQuoteFinanceState.confirmed:
        if (item.convertedOrderNo != null) {
          return l10n.quoteFinanceStatusConverted(item.convertedOrderNo!);
        }
        return l10n.quoteFinanceStatusConfirmed(
          item.financeConfirmedByName ?? '—',
        );
      case SalesQuoteFinanceState.pending:
        return [
          if (item.resubmitted)
            l10n.quoteFinanceStatusResubmitted
          else
            l10n.quoteFinanceStatusPending,
          if (item.pricePendingCount > 0)
            l10n.quoteFinanceStatusNeedPrice(item.pricePendingCount),
          if (item.claimedByMe)
            l10n.quoteFinanceStatusClaimedByMe
          else if (item.claimedByName != null)
            l10n.quoteFinanceStatusClaimedBy(item.claimedByName!),
        ].join(' · ');
    }
  }

  UtenStatusBadgeType _statusType(SalesQuoteFinanceListItem item) =>
      switch (_state) {
        SalesQuoteFinanceState.returned => UtenStatusBadgeType.danger,
        SalesQuoteFinanceState.confirmed => UtenStatusBadgeType.success,
        SalesQuoteFinanceState.pending =>
          item.pricePendingCount > 0 || item.resubmitted
              ? UtenStatusBadgeType.warning
              : UtenStatusBadgeType.info,
      };

  Color? _rowColor(ThemeData theme, SalesQuoteFinanceListItem item) {
    if (_state != SalesQuoteFinanceState.pending) return null;
    if (item.pricePendingCount > 0 || item.resubmitted) {
      return theme.brightness == Brightness.dark
          ? UtenColors.warning.withValues(alpha: 0.14)
          : UtenColors.warningBg;
    }
    return null;
  }

  Color _accentColor(ThemeData theme, SalesQuoteFinanceListItem item) =>
      switch (_state) {
        SalesQuoteFinanceState.returned => theme.colorScheme.error,
        SalesQuoteFinanceState.confirmed => theme.colorScheme.primary,
        SalesQuoteFinanceState.pending =>
          item.pricePendingCount > 0 || item.resubmitted
              ? UtenColors.warning
              : theme.colorScheme.outlineVariant,
      };

  String _emptyMessage(AppLocalizations l10n) {
    if (_keyword.isNotEmpty) return l10n.quoteFinanceEmptySearch(_keyword);
    return switch (_state) {
      SalesQuoteFinanceState.pending => l10n.quoteFinanceEmptyPending,
      SalesQuoteFinanceState.confirmed => l10n.quoteFinanceEmptyConfirmed,
      SalesQuoteFinanceState.returned => l10n.quoteFinanceEmptyReturned,
    };
  }

  String? _emptyDescription(AppLocalizations l10n) => switch (_state) {
    SalesQuoteFinanceState.pending => l10n.quoteFinanceEmptyPendingHint,
    SalesQuoteFinanceState.returned => l10n.quoteFinanceEmptyReturnedHint,
    SalesQuoteFinanceState.confirmed => null,
  };
}

class _CompactQuoteRow extends StatelessWidget {
  const _CompactQuoteRow({
    super.key,
    required this.item,
    required this.statusText,
    required this.accent,
    required this.openLabel,
    required this.amountText,
    required this.submittedLabel,
    required this.onOpen,
  });

  final SalesQuoteFinanceListItem item;
  final String statusText;
  final Color accent;
  final String openLabel;
  final String amountText;
  final String submittedLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${item.billNo} ${item.clientName ?? ''} $statusText',
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColoredBox(color: accent, child: const SizedBox(width: 3)),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.billNo,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                    Text(
                                      amountText,
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: UtenSpacing.s4),
                                Text(
                                  [
                                    ?item.clientName,
                                    ?item.sellerName,
                                  ].join(' · '),
                                  style: theme.textTheme.bodyMedium,
                                ),
                                if (item.submittedAt != null) ...[
                                  const SizedBox(height: UtenSpacing.s4),
                                  Text(
                                    '$submittedLabel '
                                    '${utenFmtIsoTime(item.submittedAt)}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: UtenSpacing.s4),
                                Text(
                                  statusText,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          UtenButton(
                            key: Key('quote-finance-open-${item.quoteId}'),
                            size: UtenButtonSize.small,
                            type: UtenButtonType.secondary,
                            icon: Icons.price_check_rounded,
                            onPressed: onOpen,
                            child: Text(openLabel),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.lgAll,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
