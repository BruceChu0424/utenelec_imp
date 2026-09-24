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
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../models/production_daily_report.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_status_badge.dart';
import '../../../shared/auth/session_snapshot_provider.dart';

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

  /// 审核/红冲/删除网络段的加载遮罩标题（null=无遮罩）。
  String? _busyTitle;
  String? _error;

  /// 「返回即刷新」登记用的本页路径（build 首次捕获，不随后续导航现取）。
  String? _myLocation;

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
  // 审核按钮只看服务端下发的 allowedActions(含车间直送审核权与对象范围，permissions-15)，
  // 避免没有直送审核权的人点了才被拒。
  bool get _canApprove => _detail?.canApprove ?? false;
  bool get _canReverse => _allows(DocumentPermissionAction.reverse);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
      if (!mounted) return;
      _applyDetail(d);
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

  /// 落一份详情到页面。
  ///
  /// 本页显示的每个名字都由服务端随单解析下发(货品名称/编号/颜色/单位/车间/参与人员),
  /// 所以这里没有任何名称预热，状态翻转不再被字典往返挡住——审核/红冲接口本身就返回
  /// 最新详情，走这里直接用，也不再多发一次详情请求(2026-09-20 用户反馈审核后等太久)。
  void _applyDetail(ProductionDailyReportDetail d) {
    setState(() {
      _detail = d;
      _loading = false;
      _error = null;
    });
  }

  /// 审核/红冲/删除改变了车间任务的已报数量与分类归属(2026-09-24 用户口径「报工成功
  /// 回到生产中，分类或整个页面应该刷新」)：发生产执行刷新信号——徽章汇总立刻重拉，
  /// 车间任务页与调度台返回时整页重拉。
  void _signalExecutionChanged() =>
      bumpListRefresh(ref, productionExecutionRefreshKey);

  Future<void> _approve() => _doAction(
    '请核对本次实际产量、需求份与公共备货份以及产出去向。'
        '需求内直送部分交下工序；送仓部分生成仓库到货登记任务，'
        '仓库登记成品仓与库位并送品质部检查。'
        '只有品质合格且仓库实际接收的数量才增加可用库存。确认审核？',
    (repo) => repo.approve(
      widget.id,
      // 同一次点击重发必须是同一把键，换一次点击必须换键。
      // 用「单号 + 当前版本号」确定性派生而不是页面里存一个随机数：
      // 页面重建或来回跳转后仍算得出同一把键，而服务端一旦真的提交、版本号变了，
      // 键自然就变了，不会把下一次操作当成上一次的重放。
      idempotencyKey: businessIdempotencyKey(
        'daily-report-approve',
        '${widget.id}:${_detail?.rowVersion ?? 0}',
      ),
    ),
    '已审核',
    reviewerResponsibility: true,
  );
  Future<void> _reverse() =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<ProductionDailyReportDetail> Function(
      ProductionDailyReportRepository,
    )
    fn,
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
    setState(() {
      _busy = true;
      _busyTitle = '正在${reviewerResponsibility ? '审核' : '红冲'}生产日报';
    });
    try {
      final updated = await fn(
        ref.read(productionDailyReportRepositoryProvider),
      );
      if (!mounted) return;
      context.appSuccess(ok);
      // 服务端已返回审核/红冲后的完整详情：直接落页面，省掉一次详情往返。
      _applyDetail(updated);
      _signalExecutionChanged();
    } on ApiException catch (e) {
      await _settleFailedAction(e.message, ok);
    } catch (_) {
      await _settleFailedAction('操作失败，请稍后重试', ok);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTitle = null;
        });
      }
    }
  }

  /// 写请求没拿到结果时的收尾：先按服务端权威状态刷新本页，再决定说什么。
  ///
  /// 超时或断连不代表服务端没做——审核事务可能已经提交(2026-09-21 实测：服务端 15.094 秒
  /// 返回 200，浏览器 15 秒就掐了连接)。这时继续拿旧详情画「审核」按钮，用户必然再点一次，
  /// 第二次必然撞上「仅草稿单据可审核」。服务端明确拒绝时同理：本地状态多半已经陈旧。
  /// 所以两条失败路径都先重读一次，状态真变了就据实告诉用户它其实成功了。
  Future<void> _settleFailedAction(
    String failureMessage,
    String successMessage,
  ) async {
    final before = _detail?.status;
    ProductionDailyReportDetail? fresh;
    try {
      fresh = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
    } catch (_) {
      fresh = null; // 连重读都失败：只能报原始错误，页面保持原样。
    }
    if (!mounted) return;
    if (fresh != null) {
      _applyDetail(fresh);
      if (fresh.status != before) {
        _signalExecutionChanged();
        context.appSuccess('$successMessage(本次提交服务端已完成，页面已刷新)');
        return;
      }
    }
    context.appError(failureMessage);
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
    setState(() {
      _busy = true;
      _busyTitle = '正在删除日报';
    });
    try {
      await ref.read(productionDailyReportRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      _signalExecutionChanged();
      context.appSuccess('已删除');
      // 返回键契约（路由设计 §十一）：pop 回来源（列表/车间任务），栈空回 hub。
      popOrBackTo(context, defaultPath: RouteName.production);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTitle = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 返回即刷新（对齐计划详情页同款修复）：本页 push 编辑页，编辑保存后
    // context.replace 成「新详情页」——旧的本页实例被压在栈下，replace 丢掉了
    // push 的 Future，返回到它时停在保存前的旧状态。注册后：期间写过数据
    // （保存/审核都在子页办完）就重拉本页详情。
    _myLocation ??= currentLocationOr(context, RouteName.production);
    ref.onPageResume(_myLocation!, () {
      if (!_busy) _load();
    });
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const UtenAppBar(title: '生产日报详情', showBackButton: true),
      body: Stack(
        children: [
          SafeArea(
            child: UtenContentContainer(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
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
                              onRetry: () => ref
                                  .read(sessionSnapshotProvider.notifier)
                                  .refresh(),
                            ),
                            _headerCard(theme),
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
                        // 底部让位右下悬浮操作组：末行可滚出按钮区。
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme),
                      ),
                    ),
            ),
          ),
          // 审核/红冲/删除网络段的全屏加载遮罩；确认弹窗期间不挂（_busy 在弹窗后才置位）。
          if (_busy)
            UtenBusyOverlay(
              title: _busyTitle ?? '正在处理',
              description: '正在写入日报状态与派生任务，请勿重复提交或离开本页。',
            ),
        ],
      ),
      // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组，大小/高度/禁用态全站统一。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      // 车间与参与人员都用服务端随单解析的名字：客户端字典缓存会随连接恢复或权限快照
      // 变化整体清空，那时这两行会变「—」且不自愈; 员工档案接口还要 employee:view。
      if ((d.departmentName ?? d.workshopName ?? '').isNotEmpty)
        _KV('车间', d.departmentName ?? d.workshopName),
      if (d.workerNames.isNotEmpty)
        _KV('生产参与人员', d.workerNames.where((n) => n.isNotEmpty).join('、')),
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
  Widget _itemsCard(ThemeData theme) {
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
              // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
              // 同名不同编号的货品（自制/委外两条同名成品）在日报里必须分得开，
              // 否则审核时会认错货。2026-09-15 起单位也不再并入名称格副行，
              // 颜色后面独立一列（用户口径）。
              MasterColumnDef(
                key: 'goods',
                label: '货品名称',
                width: 200,
                value: (it) => _dictText(it.goodsName) ?? '—',
                cellBuilderHandlesSemantics: true,
                cellBuilder: (_, it) =>
                    UtenGoodsIdentityCell(name: _dictText(it.goodsName)),
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (it) => UtenGoodsAttributeCell.text(it.goodsCode),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.goodsCode),
              ),
              MasterColumnDef(
                key: 'colorName',
                label: '颜色',
                width: 96,
                value: (it) =>
                    UtenGoodsAttributeCell.text(_dictText(it.colorName)),
                cellBuilder: (_, it) =>
                    UtenGoodsAttributeCell(_dictText(it.colorName)),
              ),
              MasterColumnDef(
                key: 'unitName',
                label: '单位',
                width: 72,
                value: (it) =>
                    UtenGoodsAttributeCell.text(_dictText(it.unitName)),
                cellBuilder: (_, it) =>
                    UtenGoodsAttributeCell(_dictText(it.unitName)),
              ),
              MasterColumnDef(
                key: 'qty',
                label: '完工申报量',
                width: 112,
                type: 'number',
                value: (it) => it.qty?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'outputKind',
                label: '产出归属',
                width: 180,
                value: (it) => it.outputKindLabel,
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
              // V584/V595：产出去向与直送接收方——同车间直送的行在这里看得到投给了谁。
              MasterColumnDef(
                key: 'destination',
                label: '产出去向',
                width: 120,
                value: (it) => it.isDirectTransfer ? '转下一道工序' : '送入仓库',
              ),
              MasterColumnDef(
                key: 'directTransfer',
                label: '转给工单',
                width: 240,
                value: (it) => it.isDirectTransfer
                    ? (it.directTransferTargetLabel ?? '—')
                    : '—',
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            // 右下悬浮操作组让位：末行可滚出按钮区。
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
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
          size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
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
    // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组；SizedBox 占位过滤
    //（组自带 8px 间距），按钮统一 large。
    return UtenFloatingActionGroup(
      children: children.where((child) => child is! SizedBox).toList(),
    );
  }
}

/// 身份格入参归一：服务端可能给空串或历史占位「—」，
/// 身份格约定「没有就不显示」，占位符要还原成 null。
String? _dictText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == '—' ? null : trimmed;
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
