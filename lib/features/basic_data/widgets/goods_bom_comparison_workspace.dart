import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_inline_notice.dart';
import 'goods_bom_comparison_table.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_error.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/web_update/web_update_safety.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_navigation.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/windows/business_windows.dart';
import '../models/goods_bom_comparison.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_detail_sequence.dart';
import '../models/goods_node.dart';
import '../providers/goods_bom_changes.dart';
import '../repositories/goods_bom_edit_repository.dart';
import '../repositories/goods_bom_repository.dart';
import '../repositories/goods_repository.dart';
import 'periodic_bom_confirmation.dart';
import 'uten_goods_picker.dart';

/// One aligned diff canvas above the retained real detail windows. Navigation
/// changes those same windows, and every result belongs to one identity/epoch.
class GoodsBomComparisonWorkspace extends ConsumerStatefulWidget {
  const GoodsBomComparisonWorkspace({
    super.key,
    required this.leftWindow,
    required this.rightWindow,
    required this.onClose,
    this.initialRatio = .5,
  });
  final BusinessWindow leftWindow, rightWindow;
  final VoidCallback onClose;
  final double initialRatio;

  @override
  ConsumerState<GoodsBomComparisonWorkspace> createState() =>
      _GoodsBomComparisonWorkspaceState();
}

class _GoodsBomComparisonWorkspaceState
    extends ConsumerState<GoodsBomComparisonWorkspace> {
  GoodsBomComparison? _comparison;
  GoodsDetail? _left, _right;
  String? _error, _message;
  int _epoch = 0;
  bool _loading = true, _busy = false, _onlyDifferences = false;
  Set<String> _selected = {};
  late final double _ratio = widget.initialRatio;
  BomComparisonReplacement? _replacement;
  BomEditPreview? _preview;
  bool _toLeft = true;
  GoRouter? _hostRouter;
  ProviderSubscription<SensitiveReadBoundary>? _boundarySubscription;

  String? _goodsId(BusinessWindow window) {
    final path = window.activeRouter?.state.uri.path;
    final match = path == null
        ? null
        : RegExp(r'^/basicinfo/goods/([^/]+)$').firstMatch(path);
    final id = match?.group(1);
    return id == 'new' ? null : id;
  }

  @override
  void initState() {
    super.initState();
    widget.leftWindow.activeRouter?.routerDelegate.addListener(_routeChanged);
    widget.rightWindow.activeRouter?.routerDelegate.addListener(_routeChanged);
    _boundarySubscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      _,
      _,
    ) {
      ++_epoch;
      _replacement?.draft.close();
      _replacement = null;
      _preview = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    webUpdateSafety.register(
      this,
      () => const WebUpdateSafetyState(blocked: true),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (router != null && !identical(router, _hostRouter)) {
      FormDraftNavigation.unregister(this);
      _hostRouter = router;
      FormDraftNavigation.register(
        this,
        router.state.uri.path,
        _canLeave,
        router: router,
      );
    }
  }

  Future<bool> _canLeave() async {
    if (!_busy && _replacement?.draft.isCommitRecoveryPending != true) {
      return true;
    }
    if (mounted) setState(() => _error = '请先核对当前保存结果，再离开 BOM 对比');
    return false;
  }

  void _routeChanged() {
    if (!mounted) return;
    if (_goodsId(widget.leftWindow) == _comparison?.leftId &&
        _goodsId(widget.rightWindow) == _comparison?.rightId) {
      return;
    }
    ++_epoch; // invalidate before the next frame or any late response
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    ++_epoch;
    widget.leftWindow.activeRouter?.routerDelegate.removeListener(
      _routeChanged,
    );
    widget.rightWindow.activeRouter?.routerDelegate.removeListener(
      _routeChanged,
    );
    _boundarySubscription?.close();
    _replacement?.draft.close();
    FormDraftNavigation.unregister(this);
    webUpdateSafety.unregister(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _replacement?.draft.isCommitRecoveryPending == true) return;
    final epoch = ++_epoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    final leftId = _goodsId(widget.leftWindow),
        rightId = _goodsId(widget.rightWindow);
    _replacement?.draft.close();
    setState(() {
      _replacement = null;
      _preview = null;
      _comparison = null;
      _left = null;
      _right = null;
      _selected = {};
      _loading = true;
      _busy = false;
      _error = null;
      _message = null;
    });
    try {
      if (!boundary.superAdmin &&
          !boundary.permissions.contains(Perm.goodsView)) {
        throw ApiException('FORBIDDEN', '当前没有货品查看权限');
      }
      if (leftId == null || rightId == null) {
        throw ApiException(
          'BOM_COMPARE_WINDOW',
          '请先在左右两个窗口分别打开已保存的货品资料，再对比 BOM',
        );
      }
      final api = ref.read(apiClientProvider);
      final scope = await api.captureRequestScope(isCurrent: current);
      final goods = ref.read(goodsRepositoryProvider),
          bom = ref.read(goodsBomRepositoryProvider);
      final results = await scope.run(
        () => Future.wait<Object>([
          goods.detail(leftId),
          goods.detail(rightId),
          bom.list(leftId),
          bom.list(rightId),
        ]),
      );
      if (!current()) return;
      final comparison = await GoodsBomComparison.build(
        leftId: leftId,
        rightId: rightId,
        left: results[2] as List<GoodsBomItem>,
        right: results[3] as List<GoodsBomItem>,
        isCurrent: current,
      );
      if (!current()) return;
      final supplierIds = {
        for (final item in [...comparison.left, ...comparison.right])
          if (item.defaultSupplierId != null) item.defaultSupplierId!,
      };
      if (supplierIds.isNotEmpty) {
        try {
          await scope.run(
            () => ref
                .read(masterNameServiceProvider)
                .loadSupplierNames(supplierIds),
          );
        } catch (_) {
          // Names are optional presentation; keep the canonical reference visible.
        }
      }
      if (!current()) return;
      setState(() {
        _left = results[0] as GoodsDetail;
        _right = results[1] as GoodsDetail;
        _comparison = comparison;
        _loading = false;
      });
    } catch (error) {
      if (current()) {
        setState(() {
          _loading = false;
          _error = _errorText(error);
        });
      }
    }
  }

  String _errorText(Object error) => error is ApiException
      ? [
          error.message,
          for (final detail in error.fieldErrors ?? const <ApiFieldError>[])
            '${detail.field}：${detail.message}',
        ].join('\n')
      : '处理失败，请重试；尚未确认的保存请先核对结果';

  bool _canReplace(bool toLeft, bool all) {
    final comparison = _comparison;
    if (comparison == null ||
        _busy ||
        _replacement != null ||
        comparison.leftId == comparison.rightId ||
        (toLeft ? _left : _right)?.writable != true) {
      return false;
    }
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool has(String permission) =>
        boundary.superAdmin || boundary.permissions.contains(permission);
    if (!has(Perm.goodsBomEdit)) return false;
    final chosen = comparison.rows
        .where((row) => all || _selected.contains(row.key))
        .where((row) => row.difference != BomDifference.same)
        .toList();
    if (chosen.isEmpty) return false;
    return chosen.every((row) {
      final source = toLeft ? row.right : row.left,
          target = toLeft ? row.left : row.right;
      return source == null
          ? has(Perm.goodsBomDelete)
          : target == null
          ? has(Perm.goodsBomCreate)
          : true;
    });
  }

  Future<void> _prepare(bool toLeft, bool all) async {
    if (!_canReplace(toLeft, all)) return;
    final comparison = _comparison!;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    BomComparisonReplacement? replacement;
    try {
      replacement = await comparison.prepare(
        toLeft: toLeft,
        selected: all ? null : Set.of(_selected),
        repository: ref.read(goodsBomRepositoryProvider),
        api: ref.read(apiClientProvider),
        isCurrent: current,
      );
      if (!current()) return;
      if (!replacement.draft.hasChanges) {
        setState(() => _message = '两侧组件一致，无需替换');
        return;
      }
      BomEditPreview preview;
      while (true) {
        try {
          preview = await replacement.draft.preview();
          break;
        } on ApiException catch (error) {
          final confirmations = periodicConfirmationsOf(error);
          if (confirmations == null || !current() || !mounted) rethrow;
          final fields = await askPeriodicConfirmations(
            context,
            confirmations,
            isCurrent: current,
          );
          if (fields == null || !current()) return;
          replacement.draft.confirmPeriodicFields(fields);
        }
      }
      if (!current()) return;
      setState(() {
        _replacement = replacement;
        _preview = preview;
        _toLeft = toLeft;
      });
    } catch (error) {
      if (current()) setState(() => _error = _errorText(error));
    } finally {
      if (!identical(replacement, _replacement)) replacement?.draft.close();
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final replacement = _replacement, preview = _preview;
    if (_busy || replacement == null || preview == null) return;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await replacement.draft.commit(
        preview.previewToken,
        confirmSharedChanges: true,
      );
      if (!mounted || epoch != _epoch) return;
      ref.read(goodsBomChangesProvider.notifier).saved();
      _replacement = null;
      _preview = null;
      await _load();
      if (mounted) setState(() => _message = '组件已替换，已重新分析左右 BOM');
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(
          () => _error = replacement.draft.isCommitRecoveryPending
              ? '保存结果尚未确认。请点击“核对上次保存结果”，使用原保存请求获取结果。\n${_errorText(error)}'
              : _errorText(error),
        );
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  bool get _locked => _busy || _replacement != null;

  Future<void> _choose(bool left) async {
    if (_locked) return;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    final item = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.all,
      title: left ? '选择左侧对比货品' : '选择右侧对比货品',
      readBoundary: boundary,
    );
    if (item == null ||
        !mounted ||
        epoch != _epoch ||
        boundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    await _navigate(left, item.id);
  }

  Future<void> _navigate(bool left, String id) async {
    if (_locked) return;
    final window = left ? widget.leftWindow : widget.rightWindow;
    final router = window.activeRouter;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    if (router == null ||
        !await FormDraftNavigation.confirmRouterExit(router) ||
        !mounted ||
        boundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    router.replace<void>(
      '/basicinfo/goods/${Uri.encodeComponent(id)}?tab=bom',
      extra: window.extra,
    );
  }

  Widget _product(bool left) {
    final detail = left ? _left : _right;
    final window = left ? widget.leftWindow : widget.rightWindow;
    final sequence = window.extra is GoodsDetailSequence
        ? window.extra as GoodsDetailSequence
        : null;
    final index = sequence?.ids.indexOf(detail?.id ?? '') ?? -1;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${left ? '左侧' : '右侧'} · ${detail?.code ?? '选择货品'}',
                  style: Theme.of(context).textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  detail?.name ?? '打开货品后即可分析组件',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '上一个 BOM',
            onPressed: !_locked && index > 0
                ? () => _navigate(left, sequence!.ids[index - 1])
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            tooltip: '下一个 BOM',
            onPressed:
                !_locked && index >= 0 && index < sequence!.ids.length - 1
                ? () => _navigate(left, sequence.ids[index + 1])
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
          OutlinedButton(
            onPressed: _locked ? null : () => _choose(left),
            child: const Text('更换货品'),
          ),
        ],
      ),
    );
  }

  Color _statusColor(BomDifference kind) => kind == BomDifference.same
      ? Theme.of(context).brightness == Brightness.dark
            ? UtenColors.successOnDark
            : UtenColors.successText
      : Theme.of(context).colorScheme.error;

  String _statusLabel(BomDifference kind) => switch (kind) {
    BomDifference.same => '相同',
    BomDifference.changed => '有差异',
    BomDifference.leftOnly => '仅左侧',
    BomDifference.rightOnly => '仅右侧',
  };

  Widget _toolbar() {
    final comparison = _comparison;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('BOM 对比', style: Theme.of(context).textTheme.titleMedium),
          if (comparison != null)
            for (final kind in BomDifference.values)
              Chip(
                avatar: Icon(
                  kind == BomDifference.same
                      ? Icons.check_circle_outline_rounded
                      : Icons.difference_outlined,
                  color: _statusColor(kind),
                  size: 18,
                ),
                label: Text('${_statusLabel(kind)} ${comparison.count(kind)}'),
              ),
          FilterChip(
            label: const Text('只看差异'),
            selected: _onlyDifferences,
            onSelected: (value) => setState(() => _onlyDifferences = value),
          ),
          TextButton.icon(
            onPressed: _locked ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新分析'),
          ),
          TextButton.icon(
            onPressed:
                _busy || _replacement?.draft.isCommitRecoveryPending == true
                ? null
                : widget.onClose,
            icon: const Icon(Icons.close_rounded),
            label: const Text('返回资料窗口'),
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    final replacement = _replacement, preview = _preview;
    if (replacement != null && preview != null) {
      final target = _toLeft ? _left : _right,
          source = _toLeft ? _right : _left;
      return Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '用${_toLeft ? '右侧' : '左侧'}「${source?.code}」替换${_toLeft ? '左侧' : '右侧'}「${target?.code}」',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              '新增 ${replacement.added} 项，修改 ${replacement.updated} 项，删除 ${replacement.removed} 项，调整顺序 ${replacement.moved} 项。',
            ),
            if ((_toLeft ? _comparison?.right : _comparison?.left)?.isEmpty ==
                true)
              Text(
                '来源没有组件，确认后将清空目标的全部组件。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_left?.unitName != _right?.unitName)
              Text(
                '左右货品基本单位不同：${_left?.unitName ?? '未设置'} / ${_right?.unitName ?? '未设置'}。本次按原设计数量复制，不自动换算。',
              ),
            if (preview.otherUsageCount > 0)
              Text(
                '目标 BOM 还被 ${preview.otherUsageCount} 处引用，将同步受影响。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (preview.warnings.isNotEmpty) Text(preview.warnings.join('\n')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy || replacement.draft.isCommitRecoveryPending
                      ? null
                      : () {
                          replacement.draft.close();
                          setState(() {
                            _replacement = null;
                            _preview = null;
                            _error = null;
                          });
                        },
                  child: const Text('取消替换'),
                ),
                FilledButton(
                  key: const Key('bom-compare-confirm'),
                  onPressed: _busy ? null : _commit,
                  child: Text(
                    replacement.draft.isCommitRecoveryPending
                        ? '核对上次保存结果'
                        : '确认替换${_toLeft ? '左侧' : '右侧'}组件',
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 ${_selected.length} 项差异'),
          TextButton(
            onPressed: _locked || _comparison == null
                ? null
                : () => setState(() {
                    final keys = _comparison!.rows
                        .where((r) => r.difference != BomDifference.same)
                        .map((r) => r.key)
                        .toSet();
                    if (_selected.length == keys.length) {
                      _selected = {};
                    } else {
                      _selected = keys;
                    }
                  }),
            child: Text(_selected.isEmpty ? '全选差异' : '全选 / 清空'),
          ),
          FilledButton.tonal(
            key: const Key('bom-compare-selected-left'),
            onPressed: _canReplace(true, false)
                ? () => _prepare(true, false)
                : null,
            child: const Text('← 用右侧替换所选'),
          ),
          FilledButton.tonal(
            key: const Key('bom-compare-selected-right'),
            onPressed: _canReplace(false, false)
                ? () => _prepare(false, false)
                : null,
            child: const Text('用左侧替换所选 →'),
          ),
          OutlinedButton(
            key: const Key('bom-compare-all-left'),
            onPressed: _canReplace(true, true)
                ? () => _prepare(true, true)
                : null,
            child: const Text('← 用右侧全部组件替换左侧'),
          ),
          OutlinedButton(
            key: const Key('bom-compare-all-right'),
            onPressed: _canReplace(false, true)
                ? () => _prepare(false, true)
                : null,
            child: const Text('用左侧全部组件替换右侧 →'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(width: double.infinity, child: _toolbar()),
            if (_busy || _loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .2,
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12,
                    ),
                    child: UtenInlineNotice(
                      level: UtenInlineNoticeLevel.error,
                      message: _error!,
                    ),
                  ),
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: UtenInlineNotice(message: _message!),
              ),
            if (_comparison?.leftId == _comparison?.rightId &&
                _comparison != null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: UtenInlineNotice(
                  message: '两侧是同一货品。更换任一侧货品后即可比较；同一货品无需替换。',
                ),
              ),
            Expanded(
              child: GoodsBomComparisonTables(
                comparison: _comparison,
                leftHeader: _product(true),
                rightHeader: _product(false),
                selected: _selected,
                onSelected: (next) => setState(() {
                  _selected = Set.of(next);
                }),
                enabled: !_locked,
                onlyDifferences: _onlyDifferences,
                loading: _loading,
                initialRatio: _ratio,
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .3,
              ),
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(child: _actions()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
