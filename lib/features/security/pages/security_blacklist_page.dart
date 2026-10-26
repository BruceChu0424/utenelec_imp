// 访客黑名单管理页（visitor:blacklist）：blocked 账号分页列表 + 行菜单解除拉黑。
//
// 2026-09-18 黑名单 UI 首发：拉黑入口在保安核验结果页（红结果定位到访客时），
// 本页负责运营侧的查看与误操作恢复（解除即时生效，账号回 active，
// 历史申请状态不变；行级留痕由后端 fn_audit + 审计事件承载）。
//
// 响应式：compact 自套 UtenContentContainer 收敛；窄屏表格横向滚动即可。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../shared/models/retained_async_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

final _blacklistReadProvider =
    Provider.autoDispose<ScopedPagedReadProviderLease<VisitorBlacklistItem>>(
      (ref) {
        ref.watch(visitorStaffRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: const ('blacklist',));
      },
      dependencies: [
        exportContextEpochProvider,
        visitorStaffRepositoryProvider,
      ],
    );

final visitorBlacklistProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorBlacklistItem>, int>(
      (ref, page) {
        final repository = ref.watch(visitorStaffRepositoryProvider);
        return ref
            .watch(_blacklistReadProvider)
            .read(
              page,
              fetchPage: (page) => repository.blacklistPage(page: page),
            );
      },
      retry: pagedReadProviderRetry,
      dependencies: [_blacklistReadProvider, visitorStaffRepositoryProvider],
    );

class SecurityBlacklistPage extends ConsumerStatefulWidget {
  const SecurityBlacklistPage({super.key});

  @override
  ConsumerState<SecurityBlacklistPage> createState() =>
      _SecurityBlacklistPageState();
}

class _SecurityBlacklistPageState extends ConsumerState<SecurityBlacklistPage> {
  int _page = 1;
  final _tableRows = MasterDataTableRowsController<VisitorBlacklistItem>();
  final _retainedPage = RetainedAsyncPage<PagedResult<VisitorBlacklistItem>>();
  bool _busy = false;

  Future<void> _unblacklist(VisitorBlacklistItem item) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(l10n.securityBlacklistRemove),
        content: Text(l10n.securityBlacklistRemoveConfirm),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.securityBlacklistRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(visitorStaffRepositoryProvider).unblacklist(item.id);
      if (!mounted) return;
      setState(() => _page = 1);
      ref.invalidate(visitorBlacklistProvider);
      context.appSuccess(l10n.securityBlacklistRemoveDone);
    } on ApiException catch (e) {
      if (mounted) {
        context.appApiError(e, fallback: l10n.commonError);
      }
    } catch (_) {
      if (mounted) context.appError(l10n.commonError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final paginationScope = retainedReaderEpoch(ref);
    final readLease = ref.watch(_blacklistReadProvider)
      ..bindView(context, currentQuery: () => const ('blacklist',));
    final list = _retainedPage.resolveFor(
      ref,
      paginationScope,
      visitorBlacklistProvider(_page),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.securityBlacklistTitle,
        showBackButton: true,
      ),
      body: Builder(
        builder: (context) {
          final page =
              list.value ??
              const PagedResult<VisitorBlacklistItem>(
                items: [],
                page: 1,
                size: 20,
                total: 0,
                totalPages: 0,
              );
          final isCompact = context.breakpoint.isCompact;
          Widget body = RefreshIndicator(
            onRefresh: () async {
              setState(() => _page = _tableRows.visiblePage ?? _page);
              readLease.invalidate();
              ref.invalidate(visitorBlacklistProvider(_page));
            },
            child: MasterDataTableView<VisitorBlacklistItem>(
              rowsController: _tableRows,
              expensiveRowMounts: false,
              tableKey:
                  'features.security.pages.security_blacklist_page.SecurityBlacklistPageState.build.1',
              key: const Key('security-blacklist-table'),
              paginationScope: paginationScope,
              isLoading: list.isLoading && !list.hasValue,
              loadingMore: list.isLoading && list.hasValue,
              error: list.hasError ? '${list.error}' : null,
              onRetry: () {
                readLease.invalidate();
                ref.invalidate(visitorBlacklistProvider(_page));
              },
              columns: _columns(l10n),
              items: page.items,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              // 解除拉黑是恢复性操作，不做 destructive 强调。
              rowMenuBuilder: (item) => [
                UtenMenuItem(
                  label: l10n.securityBlacklistRemove,
                  icon: Icons.restore_rounded,
                  enabled: !_busy,
                  onTap: () => _unblacklist(item),
                ),
              ],
              emptyMessage: l10n.securityBlacklistEmpty,
              // 黑名单是运营小集合（常态个位数），仍接后端分页防极端堆积。
              currentPage: page.page,
              totalPages: page.totalPages,
              onPageChange: (p) => readLease.paginate(p, () async {
                setState(() => _page = p);
                ref.invalidate(visitorBlacklistProvider(_page));
                await _retainedPage.waitFor(
                  ref,
                  visitorBlacklistProvider(_page),
                  () => ref.read(visitorBlacklistProvider(_page).future),
                );
              }),
            ),
          );
          if (isCompact) {
            body = UtenContentContainer(child: body);
          }
          return body;
        },
      ),
    );
  }

  List<MasterColumnDef<VisitorBlacklistItem>> _columns(AppLocalizations l10n) =>
      [
        MasterColumnDef(
          key: 'visitorNo',
          label: l10n.securityBlacklistColNo,
          width: 120,
          value: (item) => item.visitorNo,
        ),
        MasterColumnDef(
          key: 'name',
          label: l10n.securityBlacklistColName,
          width: 110,
          value: (item) => item.name,
        ),
        MasterColumnDef(
          key: 'phone',
          label: l10n.securityBlacklistColPhone,
          width: 140,
          value: (item) => item.phone ?? '—',
        ),
        MasterColumnDef(
          key: 'blockedReason',
          label: l10n.securityBlacklistColReason,
          width: 220,
          value: (item) => item.blockedReason ?? '—',
        ),
        MasterColumnDef(
          key: 'blockedAt',
          label: l10n.securityBlacklistColAt,
          width: 170,
          type: 'date',
          value: (item) =>
              item.blockedAt == null ? '—' : fmtDateTime(item.blockedAt!),
        ),
        MasterColumnDef(
          key: 'blockedByName',
          label: l10n.securityBlacklistColBy,
          width: 110,
          value: (item) => item.blockedByName ?? '—',
        ),
      ];
}
