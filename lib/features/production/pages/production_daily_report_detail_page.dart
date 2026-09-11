// 生产日报详情页（全页路由 · production_daily_report:view）：主表头卡 + 只读明细子表 +
// 状态门控操作（审核/红冲/编辑/删除）。结构与生产计划单详情页同构。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 production_daily_report:edit。
// 本期空结构（0 行），UI 完整保未来启用零成本。
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（提示条/表头卡/附件），
// 「明细 (N)」标题顶到页面顶部后再滚明细表内部。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_status_badge.dart';

class ProductionDailyReportDetailPage extends ConsumerStatefulWidget {
  const ProductionDailyReportDetailPage({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ProductionDailyReportDetailPage> createState() =>
      _ProductionDailyReportDetailPageState();
}

class _ProductionDailyReportDetailPageState
    extends ConsumerState<ProductionDailyReportDetailPage> {
  ProductionDailyReportDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool _allows(DocumentPermissionAction action) => DocumentPermissionCatalog
      .productionDailyReport
      .allows(ref.read(currentPermissionsProvider), action);

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.productionPlan)),
    _detail?.makerId,
  );

  bool get _canEdit =>
      _ordinaryWritable && _allows(DocumentPermissionAction.edit);
  bool get _canDelete =>
      _ordinaryWritable && _allows(DocumentPermissionAction.delete);
  bool get _canApprove => _allows(DocumentPermissionAction.approve);
  bool get _canReverse => _allows(DocumentPermissionAction.reverse);

  Future<void> _load() async {
    ref.invalidate(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      await ref.read(masterNameServiceProvider).loadEmployeeNames(d.workerIds);
      if (!mounted) return;
      setState(() {
        _detail = d;
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
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() => _doAction(
    '审核后只累计完工申报量 fqty，并生成仓库到货登记任务；'
        '此时不会增加库存或 iqty。仓库登记成品仓与库位并送品质部检查，'
        '品质放行后再进入最终点收。确认继续？',
    (repo) => repo.approve(widget.id),
    '已审核',
    reviewerResponsibility: true,
  );
  Future<void> _reverse() =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(ProductionDailyReportRepository) fn,
    String ok, {
    bool reviewerResponsibility = false,
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(context, message: confirm)
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认'),
              content: Text(confirm),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确认'),
                ),
              ],
            ),
          );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(productionDailyReportRepositoryProvider));
      if (!mounted) return;
      context.appSuccess(ok);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除日报'),
        content: const Text('确定删除该草稿日报吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(productionDailyReportRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      // 返回键契约（路由设计 §十一）：pop 回来源（列表/车间任务），栈空回 hub。
      popOrBackTo(context, defaultPath: RouteName.production);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: const UtenAppBar(title: '生产日报详情', showBackButton: true),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? Center(child: Text(_error!))
              : _detail == null
              ? const SizedBox.shrink()
              // 2026-09-11 折叠头+表内滚：头部（提示条/表头卡/附件）随上滚收起，
              // 明细标题吸顶后表格内部继续滚。
              : UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DocumentScopeWriteNotice(
                          capability: scopeCapability,
                          ownerEmployeeId: _detail!.makerId,
                          onRetry: () => ref.invalidate(
                            documentScopeCapabilityProvider(
                              DocumentDataScope.productionPlan,
                            ),
                          ),
                        ),
                        _headerCard(theme, names),
                        // 日报附件（报工照片/检验记录）：草稿可管理，审核后只读。
                        // 属「备注类小卡」，并入折叠头尾部随头部一起收起。
                        const SizedBox(height: UtenSpacing.s12),
                        BusinessAttachmentSection(
                          ownerType: 'PRODUCTION_DAILY_REPORT',
                          ownerId: _detail!.id,
                          canView: ref
                              .watch(currentPermissionsProvider)
                              .contains(Perm.productionDailyReportView),
                          // 详情=审核页：文件只读（增删回编辑页）。
                          canManage: false,
                          readOnlyNote: BusinessAttachmentSection
                              .kReviewReadOnlyAttachmentNote,
                          title: '附件（报工照片/检验记录）',
                          categories: const ['报工照片', '检验记录', '签认单', '其他'],
                        ),
                      ],
                    ),
                  ),
                  // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                  body: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: _itemsCard(theme, names),
                  ),
                ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (d.departmentId != null || (d.workshopName ?? '').isNotEmpty)
        _KV(
          '车间',
          d.departmentId != null
              ? names.department(d.departmentId)
              : d.workshopName,
        ),
      if (d.workerIds.isNotEmpty)
        _KV('生产参与人员', d.workerIds.map(names.employee).join('、')),
      if ((d.sourceDocNo ?? '').isNotEmpty) _KV('来源单号', d.sourceDocNo),
      if ((d.remark ?? '').isNotEmpty) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: ProductionStatusBadge(status: d.status, closed: d.closed),
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final r in rows) _kvRow(theme, r)],
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              r.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: r.badge ?? Text(r.value ?? '—')),
        ],
      ),
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；口径保留（颜色/单位并入货品列）。
  /// 2026-09-11 起是折叠容器的 body：标题行钉住、表格 primary:true 参与联动内滚。
  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '明细 (${items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: MasterDataTableView<ProductionDailyReportItem>(
            primary: true,
            columns: [
              MasterColumnDef(
                key: 'goods',
                label: '货品',
                width: 240,
                value: (it) {
                  final sub = [
                    names.color(it.colorId),
                    names.unit(it.unitId),
                  ].where((s) => s != '—').join(' · ');
                  return '${names.goods(it.goodsId)}'
                      '${sub.isEmpty ? '' : '($sub)'}';
                },
              ),
              MasterColumnDef(
                key: 'qty',
                label: '完工申报量',
                width: 112,
                type: 'number',
                value: (it) => it.qty?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'weight',
                label: '实际重量',
                width: 100,
                type: 'number',
                value: (it) => it.weight?.toStringAsFixed(4),
              ),
              MasterColumnDef(
                key: 'planNo',
                label: '计划号',
                width: 140,
                value: (it) => it.planNo,
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '暂无明细',
          ),
        ),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final detail = _detail!;
    final children = <Widget>[];
    // 「返回列表」只对能进 /production/daily-reports 的人渲染（车间任务等入口
    // push 进来的人可能只有报工权限；2026-09-10 审计）；走返回键契约 pop 回来源。
    final canOpenList = locationAllowedFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(isSuperAdminProvider),
      RouteName.productionDailyReportList,
    );

    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    void addBack() {
      if (!canOpenList) return;
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.productionDailyReportList,
          ),
          child: const Text('返回列表'),
        ),
      );
    }

    if (detail.status == kProductionStatusDraft) {
      if (_canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (_canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () =>
                context.push('/production/daily-reports/${widget.id}/edit'),
            child: const Text('编辑'),
          ),
        );
      }
      if (_canApprove) {
        addAction(
          UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: _approve,
            child: const Text('审核'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else if (detail.status == kProductionStatusApproved) {
      if (_canReverse) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
