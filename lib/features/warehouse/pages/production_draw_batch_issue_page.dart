import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_draw_task_repository.dart';
import '../repositories/stock_doc_repository.dart';
import '../widgets/production_draw_detail_table.dart';

/// 多单共用单张领料详情的逐行表格，进入页面只读取，确认后才整批出库。
class ProductionDrawBatchIssuePage extends ConsumerStatefulWidget {
  const ProductionDrawBatchIssuePage({super.key, required this.documentIds});
  final List<String> documentIds;

  @override
  ConsumerState<ProductionDrawBatchIssuePage> createState() =>
      _ProductionDrawBatchIssuePageState();
}

class _ProductionDrawBatchIssuePageState
    extends ConsumerState<ProductionDrawBatchIssuePage> {
  final _remark = TextEditingController();
  List<StockDocDetail>? _documents;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  String? _requestFingerprint;
  String? _requestKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids =
          widget.documentIds.where((id) => id.isNotEmpty).toSet().toList()
            ..sort();
      if (ids.isEmpty ||
          ids.length > ProductionDrawTaskRepository.batchIssueLimit) {
        throw const FormatException('请返回任务中心选择 1 至 50 张领料单');
      }
      final names = ref.read(masterNameServiceProvider);
      await names.ensureLoaded();
      final repository = ref.read(
        stockDocRepositoryProvider(StockDocType.draw),
      );
      final documents = <StockDocDetail>[];
      // 限制并发，避免一次选择 50 张时把详情接口打满。
      for (var offset = 0; offset < ids.length; offset += 5) {
        documents.addAll(
          await Future.wait(ids.skip(offset).take(5).map(repository.detail)),
        );
      }
      if (documents.any(
        (document) => document.docType != StockDocType.draw.code,
      )) {
        throw const FormatException('所选单据包含非生产领料单，请返回重新选择');
      }
      await names.loadGoodsDetails({
        for (final document in documents)
          for (final item in document.items)
            if (item.goodsId != null) item.goodsId!,
      });
      if (mounted) setState(() => _documents = documents);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '领料详情加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _blocked(Set<String> permissions) {
    if (_documents == null || _documents!.isEmpty) return '请先加载领料明细';
    if (!permissions.contains(Perm.stockDocIssue)) return '当前账号没有出库权限';
    if (_documents!.any((document) => document.status == -1)) {
      return '所选单据已红冲，请返回刷新后重新选择';
    }
    if (_documents!.any((document) => document.status == 0) &&
        !permissions.contains(Perm.stockDocApprove)) {
      return '草稿单出库即审核，当前账号还需要审核权限';
    }
    if (!_documents!.any(
      (document) => document.items.any((item) => item.remainingQty > 0),
    )) {
      return '所选领料单均已出完，请返回任务中心刷新';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_saving || _blocked(ref.read(currentPermissionsProvider)) != null) {
      return;
    }
    final ids = _documents!.map((document) => document.id).toList()..sort();
    final reason = _remark.text.trim();
    final fingerprint = '${ids.join('|')}|$reason';
    // 回执不确定时原样重试保留批量键，避免新建第二个业务意图。
    if (_requestFingerprint != fingerprint) {
      _requestFingerprint = fingerprint;
      _requestKey = const Uuid().v4();
    }
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(productionDrawTaskRepositoryProvider)
          .issueFullBatch(
            idempotencyKey: _requestKey!,
            docIds: ids,
            reason: reason.isEmpty ? null : reason,
          );
      if (!mounted) return;
      if (result.replayed) {
        context.appInfo('本批此前已完成(${result.replayedCount} 张领料单)，未重复出库');
      } else {
        context.appSuccess(
          result.skippedCount > 0
              ? '已出库 ${result.issuedCount} 张领料单(${result.skippedCount} 张已出完自动跳过)'
              : '已出库 ${result.issuedCount} 张领料单',
        );
      }
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.draw.refreshKey);
      if (context.canPop()) {
        context.pop(true);
      } else {
        popOrBackTo(context, defaultPath: RouteName.warehouseDrawTasks);
      }
    } on ApiException catch (error) {
      if (mounted) {
        context.appError(
          error.fieldErrors?.firstOrNull?.message ?? error.message,
        );
      }
    } catch (_) {
      if (mounted) context.appError('批量出库失败，当前明细和备注已保留，可重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final blocked = _blocked(permissions);
    final documents = _documents;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '批量出库详情',
          leading: UtenBackButton(
            onPressed: _saving
                ? null
                : () => popOrBackTo(
                    context,
                    defaultPath: RouteName.warehouseDrawTasks,
                  ),
          ),
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null || documents == null
                ? UtenEmpty.error(
                    message: _error ?? '没有可出库明细',
                    actionLabel: '重新加载',
                    onAction: _load,
                  )
                : Stack(
                    children: [
                      AbsorbPointer(
                        absorbing: _saving,
                        child: UtenCollapsingHeaderScrollView(
                          collapsingHeader: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '共 ${documents.length} 张领料单 · ${documents.fold<int>(0, (sum, document) => sum + document.items.length)} 行明细',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                                Text(
                                  '请核对每行仓库、车间和待出库数量。确认后按各单当前剩余量全部出库；需要部分出库时，请返回逐单办理。',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                TextField(
                                  key: const Key('warehouse-draw-batch-remark'),
                                  controller: _remark,
                                  maxLength: 200,
                                  decoration: const UtenInputDecoration(
                                    InputDecoration(
                                      labelText: '统一备注(选填)',
                                      counterText: '',
                                    ),
                                    info: '备注会追加到本批每张领料单，可填写交接情况，最多 200 字。',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          body: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: ProductionDrawDetailTable(
                              documents: documents,
                              names: ref.watch(masterNameServiceProvider),
                              permissions: permissions,
                              superAdmin: superAdmin,
                              primary: true,
                            ),
                          ),
                        ),
                      ),
                      // 批量出库事务期间的全屏加载遮罩。
                      if (_saving)
                        const UtenBusyOverlay(
                          title: '正在批量出库',
                          description: '正在按剩余量逐张出库并扣减库存，请勿重复提交或离开本页。',
                        ),
                    ],
                  ),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading || documents == null
            ? null
            : UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    onPressed: _saving
                        ? null
                        : () => popOrBackTo(
                            context,
                            defaultPath: RouteName.warehouseDrawTasks,
                          ),
                    child: const Text('取消'),
                  ),
                  if (permissions.contains(Perm.stockDocIssue))
                    UtenButton(
                      key: const Key('warehouse-draw-batch-confirm'),
                      type: UtenButtonType.danger,
                      size: UtenButtonSize.large,
                      icon: Icons.outbound_outlined,
                      isLoading: _saving,
                      onPressed: blocked != null || _saving ? null : _submit,
                      onDisabledTap: () =>
                          context.appWarning(blocked ?? '正在出库，请稍候'),
                      child: Text('确认批量出库(${documents.length})'),
                    ),
                ],
              ),
      ),
    );
  }
}
