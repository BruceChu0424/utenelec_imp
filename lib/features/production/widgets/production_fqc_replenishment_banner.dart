import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_fqc_replenishment_task.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_fqc_replenishment_repository.dart';

class ProductionFqcReplenishmentBanner extends ConsumerStatefulWidget {
  const ProductionFqcReplenishmentBanner({super.key});

  @override
  ConsumerState<ProductionFqcReplenishmentBanner> createState() =>
      _ProductionFqcReplenishmentBannerState();
}

class _ProductionFqcReplenishmentBannerState
    extends ConsumerState<ProductionFqcReplenishmentBanner> {
  static const _pageSize = 40;

  PagedResult<ProductionFqcReplenishmentMaterialTask>? _result;
  String? _error;
  bool _loading = false;
  int _page = 1;
  int _pendingCount = 0;
  final Set<String> _busyAuthorizations = {};
  final Map<String, String> _confirmationKeys = {};

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  bool get _canView =>
      _permissions.contains(Perm.productionFqcReplenishmentView);
  bool get _canConfirm =>
      _permissions.contains(Perm.productionFqcReplenishmentConfirm);
  bool get _canCreateAnalysis =>
      _canConfirm &&
      _permissions.contains(Perm.productionMaterialAnalysisCreate);
  bool get _canViewAnalysis =>
      _permissions.contains(Perm.productionMaterialAnalysisView);
  bool get _canOpenDraw => _permissions.contains(Perm.stockDocView);
  bool get _canViewPlan => _permissions.contains(Perm.productionPlanView);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({int? page}) async {
    if (!_canView) {
      if (mounted) {
        setState(() {
          _result = const PagedResult(
            items: [],
            page: 1,
            size: _pageSize,
            total: 0,
            totalPages: 0,
          );
          _pendingCount = 0;
        });
      }
      return;
    }
    final targetPage = page ?? _page;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(productionFqcReplenishmentRepositoryProvider);
      final result = await repository.materialTasks(page: targetPage);
      var pendingCount = result.items.where((item) => !item.isTerminal).length;
      try {
        pendingCount = await repository.materialTaskCount();
      } catch (_) {
        // Count is a badge enhancement. Keep the operable paged queue when it
        // is temporarily unavailable instead of replacing it with an error.
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _page = result.page;
        _pendingCount = pendingCount;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'FQC 补产物料任务加载失败，请刷新重试';
        _loading = false;
      });
    }
  }

  void _replaceTask(ProductionFqcReplenishmentMaterialTask updated) {
    final result = _result;
    if (result == null) return;
    setState(() {
      _result = PagedResult(
        items: [
          for (final item in result.items)
            if (item.authorizationId == updated.authorizationId)
              updated
            else
              item,
        ],
        page: result.page,
        size: result.size,
        total: result.total,
        totalPages: result.totalPages,
      );
    });
  }

  String _confirmationKey(String authorizationId) =>
      _confirmationKeys.putIfAbsent(
        authorizationId,
        () =>
            'fqc-material:$authorizationId:'
            '${DateTime.now().microsecondsSinceEpoch}',
      );

  Future<void> _openAnalysis(
    String analysisId, {
    BuildContext? sheetContext,
  }) async {
    if (sheetContext?.mounted == true) Navigator.of(sheetContext!).pop();
    await context.push(
      RouteName.productionMaterialAnalysis,
      extra: ProductionMaterialAnalysisSeed(analysisId: analysisId),
    );
    if (mounted) await _load();
  }

  Future<void> _createAndOpenAnalysis(
    ProductionFqcReplenishmentMaterialTask task,
    BuildContext sheetContext,
    VoidCallback refreshSheet,
  ) async {
    if (!_canCreateAnalysis ||
        _busyAuthorizations.contains(task.authorizationId)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认建立 FQC 补产物料分析'),
        content: Text(
          '${task.dispositionLabel} ${_qty(task.quantity)}：'
          '先冻结本次补产 BOM。返回补产待办确认用料后，系统才会建立真实需求和生产领料单。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认建立'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyAuthorizations.add(task.authorizationId));
    refreshSheet();
    try {
      final analysis = await ref
          .read(productionFqcReplenishmentRepositoryProvider)
          .createMaterialAnalysis(task.authorizationId);
      if (!mounted) return;
      context.appSuccess('补产 BOM 分析已建立；请核对后返回待办确认用料');
      if (sheetContext.mounted &&
          analysis.materialAnalysisId?.isNotEmpty == true) {
        await _openAnalysis(
          analysis.materialAnalysisId!,
          sheetContext: sheetContext,
        );
      } else {
        await _load();
      }
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } catch (_) {
      if (mounted) context.appError('建立 FQC 补产物料分析失败，请重试', force: true);
    } finally {
      if (mounted) {
        setState(() => _busyAuthorizations.remove(task.authorizationId));
        if (sheetContext.mounted) refreshSheet();
      }
    }
  }

  Future<void> _confirmMaterial(
    ProductionFqcReplenishmentMaterialTask task,
    BuildContext sheetContext,
    VoidCallback refreshSheet,
  ) async {
    if (!_canConfirm || _busyAuthorizations.contains(task.authorizationId)) {
      return;
    }
    final isRetry = task.status == 'BLOCKED';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isRetry ? '重试补产物料确认' : '确认补产用料'),
        content: Text(
          isRetry
              ? '系统只会重试尚未锁定的缺口；已建立的需求和领料不会重复。库存仍不足时会保留新的缺料原因。'
              : '系统将按冻结 BOM 建立独立需求并锁定库存；齐套后生成生产领料单，仓库实际发料完成后才能补产报工。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isRetry ? '确认重试' : '确认用料'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyAuthorizations.add(task.authorizationId));
    refreshSheet();
    try {
      final updated = await ref
          .read(productionFqcReplenishmentRepositoryProvider)
          .confirmMaterial(
            authorizationId: task.authorizationId,
            idempotencyKey: _confirmationKey(task.authorizationId),
          );
      if (!mounted) return;
      _replaceTask(updated);
      _confirmationKeys.remove(task.authorizationId);
      switch (updated.status) {
        case 'BLOCKED':
          context.appWarning(updated.blockedReason ?? '补产物料仍有缺口，已保留待办');
        case 'AWAITING_WAREHOUSE':
          context.appSuccess('补产领料单已生成，等待仓库实际发料');
        case 'READY':
          context.appSuccess('补产物料已发齐，可以进入生产计划报工');
        default:
          context.appSuccess('补产物料状态已更新');
      }
      await _load(page: _page);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
      // Keep the same key: the response may have been lost after commit.
    } catch (_) {
      if (mounted) context.appError('补产物料确认失败，请使用同一待办重试', force: true);
      // Keep the same key: the response may have been lost after commit.
    } finally {
      if (mounted) {
        setState(() => _busyAuthorizations.remove(task.authorizationId));
        if (sheetContext.mounted) refreshSheet();
      }
    }
  }

  Future<void> _openDraw(
    ProductionFqcReplenishmentMaterialTask task,
    BuildContext sheetContext,
  ) async {
    final drawId = task.drawId;
    if (drawId == null || drawId.isEmpty) return;
    Navigator.of(sheetContext).pop();
    await context.push(RoutePath.stockDocDetail('DRAW', drawId));
    if (mounted) await _load();
  }

  Future<void> _openPlan(
    ProductionFqcReplenishmentMaterialTask task,
    BuildContext sheetContext,
  ) async {
    if (task.planId.isEmpty) return;
    Navigator.of(sheetContext).pop();
    await context.push(RoutePath.productionPlanDetail(task.planId));
    if (mounted) await _load();
  }

  Future<void> _showTasks() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refreshSheet) {
          final result = _result;
          final items = result?.items ?? const [];
          return FractionallySizedBox(
            heightFactor: 0.9,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s16,
                    UtenSpacing.s4,
                    UtenSpacing.s8,
                    UtenSpacing.s8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'FQC 报废/拒收补产物料任务',
                          style: Theme.of(sheetContext).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (_error != null)
                  MaterialBanner(
                    content: Text('刷新失败：$_error'),
                    actions: [
                      TextButton(
                        onPressed: _loading
                            ? null
                            : () async {
                                await _load(page: _page);
                                if (sheetContext.mounted) refreshSheet(() {});
                              },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('当前没有 FQC 补产物料任务'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: UtenSpacing.s12),
                          itemBuilder: (_, index) {
                            final task = items[index];
                            return _MaterialTaskCard(
                              task: task,
                              canCreateAnalysis: _canCreateAnalysis,
                              canViewAnalysis: _canViewAnalysis,
                              canConfirm: _canConfirm,
                              canOpenDraw: _canOpenDraw,
                              canViewPlan: _canViewPlan,
                              busy: _busyAuthorizations.contains(
                                task.authorizationId,
                              ),
                              onCreateAnalysis: () async {
                                final operation = _createAndOpenAnalysis(
                                  task,
                                  sheetContext,
                                  () => refreshSheet(() {}),
                                );
                                refreshSheet(() {});
                                await operation;
                              },
                              onOpenAnalysis:
                                  task.materialAnalysisId?.isNotEmpty == true
                                  ? () => _openAnalysis(
                                      task.materialAnalysisId!,
                                      sheetContext: sheetContext,
                                    )
                                  : null,
                              onConfirm: () async {
                                final operation = _confirmMaterial(
                                  task,
                                  sheetContext,
                                  () => refreshSheet(() {}),
                                );
                                refreshSheet(() {});
                                await operation;
                              },
                              onOpenDraw: () => _openDraw(task, sheetContext),
                              onOpenPlan: () => _openPlan(task, sheetContext),
                            );
                          },
                        ),
                ),
                if (result != null && result.totalPages > 1)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s16,
                        UtenSpacing.s8,
                        UtenSpacing.s16,
                        UtenSpacing.s12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: UtenButton(
                              size: UtenButtonSize.large,
                              type: UtenButtonType.tonal,
                              icon: Icons.chevron_left_rounded,
                              onPressed: _loading || result.page <= 1
                                  ? null
                                  : () async {
                                      await _load(page: result.page - 1);
                                      if (sheetContext.mounted) {
                                        refreshSheet(() {});
                                      }
                                    },
                              child: const Text('上一页'),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UtenSpacing.s12,
                            ),
                            child: Text(
                              '${result.page} / ${result.totalPages}',
                            ),
                          ),
                          Expanded(
                            child: UtenButton(
                              size: UtenButtonSize.large,
                              type: UtenButtonType.tonal,
                              icon: Icons.chevron_right_rounded,
                              onPressed:
                                  _loading || result.page >= result.totalPages
                                  ? null
                                  : () async {
                                      await _load(page: result.page + 1);
                                      if (sheetContext.mounted) {
                                        refreshSheet(() {});
                                      }
                                    },
                              child: const Text('下一页'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.productionSchedule, _load);
    final result = _result;
    if (!_canView) return const SizedBox.shrink();
    if (result == null && _loading) return const SizedBox.shrink();
    if (_error != null && result == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline_rounded),
            title: Text(_error!),
            trailing: TextButton(onPressed: _load, child: const Text('重试')),
          ),
        ),
      );
    }
    if (result == null || result.items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Card(
        color: Theme.of(context).colorScheme.tertiaryContainer
            .withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final details = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiary
                          .withValues(alpha: 0.12),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(
                      Icons.replay_circle_filled_outlined,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FQC 补产物料任务 ${result.total} 项',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          _pendingCount > 0
                              ? '$_pendingCount 项仍需计划确认、补料或仓库发料；每一步按真实库存事实推进。'
                              : '当前任务均已发料就绪，可进入生产计划完成补产报工。',
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            '最近刷新失败：$_error',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
              final button = UtenButton(
                size: UtenButtonSize.large,
                type: UtenButtonType.tonal,
                icon: Icons.open_in_new_rounded,
                onPressed: _showTasks,
                child: const Text('处理待办'),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: UtenSpacing.s12),
                    button,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: details),
                  const SizedBox(width: UtenSpacing.s12),
                  button,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MaterialTaskCard extends StatelessWidget {
  const _MaterialTaskCard({
    required this.task,
    required this.canCreateAnalysis,
    required this.canViewAnalysis,
    required this.canConfirm,
    required this.canOpenDraw,
    required this.canViewPlan,
    required this.busy,
    required this.onCreateAnalysis,
    required this.onOpenAnalysis,
    required this.onConfirm,
    required this.onOpenDraw,
    required this.onOpenPlan,
  });

  final ProductionFqcReplenishmentMaterialTask task;
  final bool canCreateAnalysis;
  final bool canViewAnalysis;
  final bool canConfirm;
  final bool canOpenDraw;
  final bool canViewPlan;
  final bool busy;
  final VoidCallback onCreateAnalysis;
  final VoidCallback? onOpenAnalysis;
  final VoidCallback onConfirm;
  final VoidCallback onOpenDraw;
  final VoidCallback onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blockedReason = task.blockedReason?.trim();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(
                  label: _statusLabel(task.status),
                  type: _statusType(task.status),
                ),
                UtenStatusBadge(
                  label: task.dispositionLabel,
                  type: UtenStatusBadgeType.danger,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '${task.planNo ?? '生产计划'} · 补产 ${_qty(task.quantity)}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '来源报工 ${task.sourceReportNo ?? '—'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _statusIcon(task.status),
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    task.status == 'BLOCKED' &&
                            blockedReason != null &&
                            blockedReason.isNotEmpty
                        ? '缺料：$blockedReason'
                        : _statusDescription(task),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            ..._actions(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    switch (task.status) {
      case 'AWAITING_ANALYSIS':
        if (canCreateAnalysis) {
          return [
            UtenButton(
              size: UtenButtonSize.large,
              icon: Icons.add_task_rounded,
              isLoading: busy,
              onPressed: busy ? null : onCreateAnalysis,
              child: const Text('建立补产 BOM 分析'),
            ),
          ];
        }
        return [_readOnly('当前只读，请由计划员建立补产 BOM 分析')];
      case 'AWAITING_CONFIRMATION':
        return [
          if (canViewAnalysis && onOpenAnalysis != null) ...[
            UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.fact_check_outlined,
              onPressed: busy ? null : onOpenAnalysis,
              child: const Text('核对补产 BOM'),
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (canConfirm)
            UtenButton(
              size: UtenButtonSize.large,
              icon: Icons.playlist_add_check_circle_outlined,
              isLoading: busy,
              onPressed: busy ? null : onConfirm,
              child: const Text('确认用料并生成领料'),
            )
          else
            _readOnly('当前只读，请由有补产确认权限的计划员处理'),
        ];
      case 'BLOCKED':
        if (canConfirm) {
          return [
            UtenButton(
              size: UtenButtonSize.large,
              icon: Icons.refresh_rounded,
              isLoading: busy,
              onPressed: busy ? null : onConfirm,
              child: const Text('库存补齐后重试确认'),
            ),
          ];
        }
        return [_readOnly('缺料待补齐；当前只读，不能重试确认')];
      case 'AWAITING_WAREHOUSE':
        if (canOpenDraw && task.drawId?.isNotEmpty == true) {
          return [
            UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.inventory_2_outlined,
              onPressed: onOpenDraw,
              child: Text('查看领料单 ${task.drawNo ?? ''}'.trim()),
            ),
          ];
        }
        return [_readOnly('领料单已交仓库；当前只读，请等待仓库实际发料')];
      case 'READY':
        if (canViewPlan) {
          return [
            UtenButton(
              size: UtenButtonSize.large,
              icon: Icons.precision_manufacturing_outlined,
              onPressed: onOpenPlan,
              child: const Text('进入生产计划补产报工'),
            ),
          ];
        }
        return [_readOnly('补产物料已发齐，请由生产人员进入计划报工')];
      case 'AWAITING_STOCK':
        return [_readOnly('物料锁定处理中，请刷新查看结果')];
      default:
        return [_readOnly('该补产任务已结束，无需重复操作')];
    }
  }

  Widget _readOnly(String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.info_outline_rounded, size: 18),
      const SizedBox(width: UtenSpacing.s4),
      Expanded(child: Text(text)),
    ],
  );
}

String _statusLabel(String status) => switch (status) {
  'AWAITING_ANALYSIS' => '待建立分析',
  'AWAITING_CONFIRMATION' => '待确认用料',
  'BLOCKED' => '缺料待补齐',
  'AWAITING_STOCK' => '用料处理中',
  'AWAITING_WAREHOUSE' => '待仓库发料',
  'READY' => '物料已发齐',
  'CANCELLED' => '已取消',
  _ => '状态待刷新',
};

UtenStatusBadgeType _statusType(String status) => switch (status) {
  'READY' => UtenStatusBadgeType.success,
  'BLOCKED' => UtenStatusBadgeType.danger,
  'AWAITING_WAREHOUSE' => UtenStatusBadgeType.info,
  'CANCELLED' => UtenStatusBadgeType.neutral,
  _ => UtenStatusBadgeType.warning,
};

IconData _statusIcon(String status) => switch (status) {
  'READY' => Icons.check_circle_outline_rounded,
  'BLOCKED' => Icons.error_outline_rounded,
  'AWAITING_WAREHOUSE' => Icons.local_shipping_outlined,
  'CANCELLED' => Icons.cancel_outlined,
  _ => Icons.schedule_outlined,
};

String _statusDescription(ProductionFqcReplenishmentMaterialTask task) =>
    switch (task.status) {
      'AWAITING_ANALYSIS' => '先建立并核对补产 BOM，不能直接报工。',
      'AWAITING_CONFIRMATION' => 'BOM 已冻结，待计划员确认真实用料和库存。',
      'BLOCKED' => '库存不足，缺口保留在待办中；补齐后可安全重试。',
      'AWAITING_STOCK' => '系统正在建立或分配补产物料需求。',
      'AWAITING_WAREHOUSE' => '领料单 ${task.drawNo ?? '已生成'}，须等仓库实际发料完成。',
      'READY' => '仓库已完成发料，可以进入原生产计划进行补产完工申报。',
      'CANCELLED' => '补产授权已取消，不可继续领料或报工。',
      _ => '状态尚未识别，请刷新后再操作。',
    };

String _qty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
