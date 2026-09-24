import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../providers/production_execution_refresh.dart';
import '../widgets/production_review_reason_dialog.dart';
import '../repositories/production_actual_output_supplement_repository.dart';
import '../repositories/production_material_increment_repository.dart';
import '../repositories/production_repository.dart';

class ProductionActualOutputSupplementPage extends ConsumerStatefulWidget {
  const ProductionActualOutputSupplementPage({
    super.key,
    required this.id,
    this.returnToReport = false,
  });
  final String id;
  final bool returnToReport;
  @override
  ConsumerState<ProductionActualOutputSupplementPage> createState() =>
      _SupplementState();
}

class _SupplementState
    extends ConsumerState<ProductionActualOutputSupplementPage> {
  ProductionOutputSupplementView? _detail;
  String? _error;
  bool _busy = false;
  String _cancelReason = '';
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(productionOutputSupplementRepositoryProvider)
          .detail(widget.id);
      if (mounted) {
        setState(() {
          _detail = data;
          _error = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '追加计划读取失败，请刷新重试');
    }
  }

  Future<void> _approve() async {
    if (_busy) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      message: '请核对同一批实际总量、原工单份额和追加数量。审批后独立记录本次追加，车间确认原批次实物与原始用料后续报。',
    );
    if (confirmed != true || !mounted) return;
    await _action(() async {
      await ref
          .read(productionOutputSupplementRepositoryProvider)
          .approve(widget.id);
    });
  }

  Future<void> _cancel() async {
    if (_busy) return;
    final reason = await showProductionReviewReasonDialog(
      context,
      title: '取消追加生产计划',
      initialValue: _cancelReason,
      onDraftChanged: (value) => _cancelReason = value,
    );
    if (reason == null || !mounted) return;
    await _action(() async {
      await ref
          .read(productionOutputSupplementRepositoryProvider)
          .cancel(widget.id, reason);
    });
  }

  Future<void> _start() async {
    final d = _detail;
    if (_busy ||
        d == null ||
        !d.canStart ||
        d.planId == null ||
        d.supplementSegmentId == null ||
        d.supplementSegmentVersion == null) {
      return;
    }
    await _action(() async {
      await ref
          .read(productionPlanRepositoryProvider)
          .startExecutionSegment(
            d.planId!,
            d.supplementSegmentId!,
            expectedVersion: d.supplementSegmentVersion!,
            idempotencyKey: businessIdempotencyKey(
              'supplement-start',
              '${d.id}|${d.supplementSegmentVersion}',
            ),
          );
    });
    if (mounted &&
        _detail?.supplementSegmentStatus == 'IN_PROGRESS' &&
        (ref.read(isSuperAdminProvider) ||
            ref
                .read(currentPermissionsProvider)
                .contains(Perm.productionDailyReportCreate))) {
      _continueReport();
    }
  }

  void _continueReport() {
    final detail = _detail;
    if (detail == null ||
        detail.proofId == null ||
        detail.sourceLine == null ||
        detail.supplementSegmentStatus != 'IN_PROGRESS') {
      return;
    }
    if (widget.returnToReport) {
      context.pop(detail);
    } else {
      context.push('/production/daily-reports/new', extra: detail);
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      refreshAfterProductionPlanGenerated(ref);
      await _load();
    } on ApiException catch (error) {
      await _load();
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      await _load();
      if (mounted) setState(() => _error = '请核对当前计划状态后再重试；原报工数量和用料仍保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    if (_busy) return;
    if (widget.returnToReport && context.canPop()) {
      context.pop(_detail);
    } else {
      final planner =
          ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.productionPlanApprove);
      popOrBackTo(
        context,
        defaultPath: planner
            ? RouteName.productionPlanList
            : RouteName.productionWorkshopTasks,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final permissions = ref.watch(currentPermissionsProvider);
    final admin = ref.watch(isSuperAdminProvider);
    final ready =
        d?.status == 'APPROVED' &&
        d?.proofId != null &&
        d?.sourceLine != null &&
        d?.supplementSegmentStatus == 'IN_PROGRESS';
    return Scaffold(
      appBar: UtenAppBar(
        title: '追加生产计划',
        leading: UtenBackButton(onPressed: _back),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: d == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: _load,
                          child: Text('$_error · 重试'),
                        ),
                )
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_busy) const LinearProgressIndicator(),
                        Text(
                          d.planNo ?? '追加计划',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${d.sourceLine?.goodsName ?? '来源自制件'} · 原计划 ${d.sourceLine?.planNo ?? '—'} · 原工单 ${d.sourceLine?.executionSegmentCode ?? '—'}',
                        ),
                        const SizedBox(height: 16),
                        Text('本次实际产量：${d.actualQty}'),
                        Text('本次归原工单：${d.originalReportQty}'),
                        Text('独立追加计划：${d.supplementQty}'),
                        Text(
                          '原工单 ${d.originalReportQty} + 本次追加 ${d.supplementQty}，同一批实际产出 ${d.actualQty}。',
                        ),
                        const Text('本页登记已经完成的同一批实物，请核对原始用料后续报。'),
                        const SizedBox(height: 16),
                        Text(switch (d.status) {
                          'DRAFT' => '待计划部审批；原报工表的实际数量和用料保留，审批前不计作已完成。',
                          'APPROVED' =>
                            d.supplementSegmentStatus == 'COMPLETED'
                                ? '本次追加批次已完成登记，请从原日报查看报工与实收记录。'
                                : ready
                                ? '原批次已确认，可以继续提交本次实际报工。'
                                : '追加计划已通过；请车间核对真实物料来源，确认原批次后续报。',
                          'CANCELLED' => '追加申请已取消；请回原报工表核对，不会自动改量。',
                          _ => '当前状态：${d.status}',
                        }),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            OutlinedButton(
                              onPressed: _busy ? null : _back,
                              child: Text(
                                widget.returnToReport ? '返回原报工表' : '返回车间任务',
                              ),
                            ),
                            if ((d.status == 'DRAFT' ||
                                    d.status == 'APPROVED') &&
                                (admin ||
                                    permissions.contains(
                                      Perm.productionPlanApprove,
                                    )))
                              OutlinedButton(
                                onPressed: _busy ? null : _cancel,
                                child: const Text('取消追加计划'),
                              ),
                            if (d.status == 'DRAFT' &&
                                (admin ||
                                    permissions.contains(
                                      Perm.productionPlanApprove,
                                    )))
                              FilledButton(
                                onPressed: _busy ? null : _approve,
                                child: const Text('审批追加计划'),
                              ),
                            if (d.canStart &&
                                (admin ||
                                    permissions.contains(
                                      Perm.productionExecutionStart,
                                    )))
                              FilledButton(
                                onPressed: _busy ? null : _start,
                                child: const Text('确认原批次并续报'),
                              ),
                            if (d.status == 'APPROVED' &&
                                d.supplementSegmentId != null &&
                                d.supplementSegmentStatus != 'COMPLETED' &&
                                (admin ||
                                    permissions.contains(
                                      productionMaterialIncrementPermission,
                                    )))
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        await context.push(
                                          RoutePath.productionMaterialIncrementForSegment(
                                            d.supplementSegmentId!,
                                          ),
                                        );
                                        if (mounted) await _load();
                                      },
                                icon: const Icon(Icons.playlist_add_outlined),
                                label: const Text('申请追加用料'),
                              ),
                            if (ready &&
                                (admin ||
                                    permissions.contains(
                                      Perm.productionDailyReportCreate,
                                    )))
                              FilledButton(
                                onPressed: _busy ? null : _continueReport,
                                child: const Text('继续报工'),
                              ),
                          ],
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
