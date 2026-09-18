// 访客黑名单管理页（visitor:blacklist）：blocked 账号分页列表 + 行菜单解除拉黑。
//
// 2026-09-18 黑名单 UI 首发：拉黑入口在保安核验结果页（红结果定位到访客时），
// 本页负责运营侧的查看与误操作恢复（解除即时生效，账号回 active，
// 历史申请状态不变；行级留痕由后端 fn_audit + 审计事件承载）。
//
// 响应式：compact 自套 UtenContentContainer 收敛；窄屏表格横向滚动即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
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

final visitorBlacklistProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorBlacklistItem>, int>((ref, page) {
      return ref
          .watch(visitorStaffRepositoryProvider)
          .blacklistPage(page: page);
    });

class SecurityBlacklistPage extends ConsumerStatefulWidget {
  const SecurityBlacklistPage({super.key});

  @override
  ConsumerState<SecurityBlacklistPage> createState() =>
      _SecurityBlacklistPageState();
}

class _SecurityBlacklistPageState extends ConsumerState<SecurityBlacklistPage> {
  int _page = 1;
  bool _busy = false;

  Future<void> _unblacklist(VisitorBlacklistItem item) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
    final list = ref.watch(visitorBlacklistProvider(_page));
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.securityBlacklistTitle,
        showBackButton: true,
      ),
      body: list.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '$e',
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(visitorBlacklistProvider(_page)),
        ),
        data: (page) {
          final isCompact = context.breakpoint.isCompact;
          Widget body = RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(visitorBlacklistProvider(_page)),
            child: MasterDataTableView<VisitorBlacklistItem>(
              key: const Key('security-blacklist-table'),
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
              onPageChange: (p) => setState(() => _page = p),
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
