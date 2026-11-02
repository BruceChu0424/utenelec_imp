import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/buttons/uten_close_button.dart';
import 'goods_bom_comparison_table.dart';
import 'goods_bom_comparison_editor.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_error.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/web_update/web_update_safety.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_navigation.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/windows/business_windows.dart';
import '../models/goods_bom_comparison.dart';
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
  String? _error;
  int _epoch = 0;
  bool _loading = true, _busy = false, _onlyDifferences = false;
  Set<String> _selected = {};
  late final double _ratio = widget.initialRatio;
  BomComparisonReplacement? _replacement;
  BomEditPreview? _preview;
  GoodsBomComparisonEditor? _editor;
  bool _toLeft = true;
  GoRouter? _hostRouter;
  ModalRoute<dynamic>? _leaveRoute;
  ModalRoute<dynamic>? _reviewRoute;
  bool _reviewDialogOpen = false;
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
      _dismissLeaveDialog();
      _editor?.dispose();
      _editor = null;
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
    if (_reviewDialogOpen) return false;
    if (!_busy && _replacement?.draft.isCommitRecoveryPending != true) {
      final editor = _editor;
      if (editor?.hasChanges != true) return true;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) {
          _leaveRoute = ModalRoute.of(ctx);
          return UtenAlertDialog(
            showCloseButton: true,
            closeTooltip: '关闭提示并继续编辑',
            onClose: () {
              if (ModalRoute.of(ctx)?.isCurrent == true) {
                Navigator.pop(ctx, 'continue');
              }
            },
            title: const Text('还有未保存的 BOM 修改'),
            content: const Text('请先核对并保存，或明确放弃未保存修改。离开对比不会自动保存输入。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'continue'),
                child: const Text('继续编辑'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'discard'),
                child: const Text('放弃并继续'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'save'),
                child: const Text('先核对并保存'),
              ),
            ],
          );
        },
      );
      _leaveRoute = null;
      if (!mounted || !identical(editor, _editor)) return false;
      if (choice == 'discard') {
        try {
          for (final root in editor!.details.keys) {
            if (editor.changed(root)) await editor.reset(root);
          }
          return mounted && identical(editor, _editor);
        } catch (error) {
          if (mounted) setState(() => _error = _errorText(error));
          return false;
        }
      }
      if (choice == 'save') {
        for (final root in editor!.details.keys) {
          if (editor.changed(root) && !await _reviewEdits(root)) return false;
          if (!mounted || !identical(editor, _editor)) return false;
        }
        return !editor.hasChanges;
      }
      return false;
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
    _dismissLeaveDialog();
    widget.leftWindow.activeRouter?.routerDelegate.removeListener(
      _routeChanged,
    );
    widget.rightWindow.activeRouter?.routerDelegate.removeListener(
      _routeChanged,
    );
    _boundarySubscription?.close();
    _replacement?.draft.close();
    _editor?.dispose();
    _editor = null;
    FormDraftNavigation.unregister(this);
    webUpdateSafety.unregister(this);
    super.dispose();
  }

  void _dismissLeaveDialog() {
    final routes = [_leaveRoute, _reviewRoute];
    _leaveRoute = null;
    _reviewRoute = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        if (route?.isActive == true) route!.navigator?.removeRoute(route);
      }
    });
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
    _editor?.dispose();
    _editor = null;
    setState(() {
      _replacement = null;
      _reviewDialogOpen = false;
      _preview = null;
      _comparison = null;
      _left = null;
      _right = null;
      _selected = {};
      _loading = true;
      _busy = false;
      _error = null;
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
      final editor = GoodsBomComparisonEditor(
        ref: ref,
        details: {
          leftId: results[0] as GoodsDetail,
          rightId: results[1] as GoodsDetail,
        },
        isCurrent: current,
        onChanged: _refreshComparison,
      );
      try {
        await editor.open();
      } catch (_) {
        editor.dispose();
        rethrow;
      }
      if (!current()) {
        editor.dispose();
        return;
      }
      _editor = editor;
      final editable = await Future.wait([
        editor.read(leftId, leftId),
        editor.read(rightId, rightId),
      ]);
      final comparison = await GoodsBomComparison.build(
        leftId: leftId,
        rightId: rightId,
        left: editable[0],
        right: editable[1],
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
      editor.addListener(_editorStateChanged);
      if (leftId == rightId && current() && mounted) {
        context.appInfo('两侧是同一货品。更换任一侧货品后即可比较；同一货品无需替换。');
      }
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

  void _editorStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshComparison() async {
    final editor = _editor, comparison = _comparison;
    if (!mounted || editor == null || comparison == null) return;
    final epoch = _epoch;
    bool current() => mounted && epoch == _epoch && identical(editor, _editor);
    final items = await Future.wait([
      editor.read(comparison.leftId, comparison.leftId),
      editor.read(comparison.rightId, comparison.rightId),
    ]);
    final next = await GoodsBomComparison.build(
      leftId: comparison.leftId,
      rightId: comparison.rightId,
      left: items[0],
      right: items[1],
      isCurrent: current,
    );
    if (current()) {
      setState(() {
        final before = {
          for (final row in comparison.rows)
            row.key: '${row.left?.id}|${row.right?.id}',
        };
        final after = {
          for (final row in next.rows)
            row.key: '${row.left?.id}|${row.right?.id}',
        };
        if (before.length != after.length ||
            before.keys.any((key) => before[key] != after[key])) {
          _selected = {};
        }
        _comparison = next;
        _selected.removeWhere(
          (id) => !next.rows.any(
            (row) => row.key == id && row.difference != BomDifference.same,
          ),
        );
      });
    }
  }

  Future<bool> _reviewEdits(String root) async {
    final editor = _editor;
    if (_locked || editor == null || !editor.changed(root)) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await editor.flush(root: root);
      final draft = editor.draftFor(root);
      if (!mounted ||
          !identical(editor, _editor) ||
          draft == null ||
          !draft.hasChanges) {
        return false;
      }
      await draft.refreshCopySources();
      BomEditPreview preview;
      while (true) {
        try {
          preview = await draft.preview();
          break;
        } on ApiException catch (error) {
          final confirmations = periodicConfirmationsOf(error);
          if (confirmations == null || !mounted) rethrow;
          final fields = await askPeriodicConfirmations(
            context,
            confirmations,
            isCurrent: () => mounted && identical(editor, _editor),
          );
          if (fields == null || !mounted) return false;
          draft.confirmPeriodicFields(fields);
        }
      }
      if (mounted && identical(editor, _editor)) {
        setState(() {
          _replacement = BomComparisonReplacement(
            draft: draft,
            added: 0,
            removed: 0,
            updated: draft.operationCount,
            moved: 0,
          );
          _preview = preview;
          _toLeft = root == _comparison?.leftId;
        });
        final confirmed = await _confirmAction(
          title: '确认保存${_toLeft ? '左侧' : '右侧'}修改',
          content: _reviewBody(_replacement!, preview),
          confirm: '确认保存${_toLeft ? '左侧' : '右侧'}修改',
          confirmKey: const Key('bom-compare-confirm'),
          cancel: '返回继续编辑',
        );
        if (!mounted || !identical(editor, _editor)) return false;
        if (!confirmed) {
          setState(() {
            _replacement = null;
            _preview = null;
          });
          return false;
        }
        setState(() => _busy = false);
        return await _commit();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  Future<void> _discardEdits(String root) async {
    if (_locked || _editor == null) return;
    if (!await _confirmAction(
          title: '放弃${root == _comparison?.leftId ? '左侧' : '右侧'}修改？',
          content: const Text('该侧未保存的编辑和替换将全部放弃，恢复为已保存的组件。'),
          confirm: '确认放弃',
          confirmKey: const Key('bom-compare-discard-confirm'),
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _editor!.reset(root);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (await _canLeave() && mounted) await _load();
  }

  Future<void> _close() async {
    if (await _canLeave() && mounted) widget.onClose();
  }

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
    final editor = _editor!;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    BomComparisonReplacement? replacement;
    bool accepted = false;
    try {
      await editor.flush();
      await _refreshComparison();
      if (!current()) return;
      final comparison = _comparison!;
      final targetId = toLeft ? comparison.leftId : comparison.rightId;
      final sourceId = toLeft ? comparison.rightId : comparison.leftId;
      final selected = all ? null : Set.of(_selected);
      replacement = await comparison.prepare(
        toLeft: toLeft,
        selected: selected,
        repository: ref.read(goodsBomRepositoryProvider),
        api: ref.read(apiClientProvider),
        isCurrent: current,
        targetDraft: editor.draftFor(targetId),
        sourceDraft: editor.draftFor(sourceId),
      );
      if (!current()) return;
      if (replacement.added +
              replacement.removed +
              replacement.updated +
              replacement.moved ==
          0) {
        if (mounted) context.appInfo('两侧组件一致，无需替换');
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
      _toLeft = toLeft;
      final confirmed = await _confirmAction(
        title: '确认${all ? '全部' : '所选'}组件替换',
        content: _reviewBody(replacement, preview, replacing: true),
        confirm: '确认替换${toLeft ? '左侧' : '右侧'}草稿',
        confirmKey: const Key('bom-compare-stage-confirm'),
        cancel: '取消替换',
      );
      if (!confirmed || !current()) return;
      await editor.acceptReplacement(
        targetId,
        replacement.draft,
        sourceRoot: sourceId,
        components: selected ?? comparison.rows.map((row) => row.key).toSet(),
      );
      accepted = true;
      if (current() && mounted) context.appSuccess('组件替换已暂存，点击保存后生效');
    } catch (error) {
      if (current()) setState(() => _error = _errorText(error));
    } finally {
      if (!accepted &&
          !identical(
            editor.draftFor(replacement?.draft.rootGoodsId ?? ''),
            replacement?.draft,
          )) {
        replacement?.draft.close();
      }
      if (current()) setState(() => _busy = false);
    }
  }

  Future<bool> _commit() async {
    final replacement = _replacement, preview = _preview;
    if (_busy || replacement == null || preview == null) return false;
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
      if (!mounted || epoch != _epoch) return false;
      ref.read(goodsBomChangesProvider.notifier).saved();
      final root = _toLeft ? _comparison!.leftId : _comparison!.rightId;
      _replacement = null;
      _preview = null;
      await _editor!.reset(root, committed: true);
      if (mounted) context.appSuccess('修改已保存，已重新核对左右 BOM');
      return true;
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
    return false;
  }

  Future<void> _resumeReview() async {
    final root = _toLeft ? _comparison!.leftId : _comparison!.rightId;
    setState(() {
      _replacement = null;
      _preview = null;
    });
    await _reviewEdits(root);
  }

  bool get _locked => _busy || _reviewDialogOpen || _replacement != null;

  Future<void> _choose(bool left) async {
    if (_locked) return;
    if (!await _canLeave() || !mounted) return;
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
    if (!await _canLeave() || !mounted) return;
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
                if (detail != null)
                  Text(
                    _editor?.draftFor(detail.id) != null
                        ? '编辑模式 · 修改后实时核对'
                        : '只读对比',
                    style: Theme.of(context).textTheme.labelSmall,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
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
                      label: Text(
                        '${_statusLabel(kind)} ${comparison.count(kind)}',
                      ),
                    ),
                FilterChip(
                  label: const Text('只看差异'),
                  selected: _onlyDifferences,
                  onSelected: (value) =>
                      setState(() => _onlyDifferences = value),
                ),
                TextButton.icon(
                  onPressed: _locked ? null : _reload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新分析'),
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenCloseButton(
            key: const Key('bom-compare-close'),
            tooltip: '返回资料窗口',
            onPressed:
                _busy || _replacement?.draft.isCommitRecoveryPending == true
                ? null
                : _close,
          ),
        ],
      ),
    );
  }

  Widget? _sideActions(bool toLeft) {
    if (_replacement != null) return null;
    final root = toLeft ? _comparison?.leftId : _comparison?.rightId;
    final side = toLeft ? 'left' : 'right';
    final owned =
        root != null &&
        _editor?.changed(root) == true &&
        (toLeft || root != _comparison?.leftId);
    return Semantics(
      container: true,
      label: toLeft ? '左侧 BOM 操作' : '右侧 BOM 操作',
      child: DecoratedBox(
        key: ValueKey('bom-compare-actions-$side'),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (owned) ...[
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    FilledButton(
                      key: ValueKey('bom-compare-save-$root'),
                      onPressed: _locked ? null : () => _reviewEdits(root),
                      child: Text(toLeft ? '保存左侧修改' : '保存右侧修改'),
                    ),
                    TextButton(
                      onPressed: _locked ? null : () => _discardEdits(root),
                      child: Text(toLeft ? '放弃左侧修改' : '放弃右侧修改'),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
              ],
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  FilledButton.tonal(
                    key: Key('bom-compare-selected-$side'),
                    onPressed: _canReplace(toLeft, false)
                        ? () => _prepare(toLeft, false)
                        : null,
                    child: Text(toLeft ? '← 用右侧替换所选' : '用左侧替换所选 →'),
                  ),
                  OutlinedButton(
                    key: Key('bom-compare-all-$side'),
                    onPressed: _canReplace(toLeft, true)
                        ? () => _prepare(toLeft, true)
                        : null,
                    child: Text(toLeft ? '← 用右侧全部组件替换左侧' : '用左侧全部组件替换右侧 →'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmAction({
    required String title,
    required Widget content,
    required String confirm,
    required Key confirmKey,
    String cancel = '继续编辑',
  }) async {
    final wasBusy = _busy;
    final epoch = _epoch;
    setState(() {
      _reviewDialogOpen = true;
      _busy = false;
    });
    try {
      return await showDialog<bool>(
            context: context,
            builder: (ctx) {
              _reviewRoute = ModalRoute.of(ctx);
              void finish(bool value) {
                if (ModalRoute.of(ctx)?.isCurrent == true) {
                  Navigator.pop(ctx, value);
                }
              }

              return UtenAlertDialog(
                showCloseButton: true,
                closeTooltip: '关闭确认并继续编辑',
                onClose: () => finish(false),
                title: Text(title),
                content: content,
                actions: [
                  OutlinedButton(
                    onPressed: () => finish(false),
                    child: Text(cancel),
                  ),
                  FilledButton(
                    key: confirmKey,
                    onPressed: () => finish(true),
                    child: Text(confirm),
                  ),
                ],
              );
            },
          ) ==
          true;
    } finally {
      _reviewRoute = null;
      if (mounted && epoch == _epoch) {
        setState(() {
          _reviewDialogOpen = false;
          _busy = wasBusy;
        });
      }
    }
  }

  Widget _reviewBody(
    BomComparisonReplacement replacement,
    BomEditPreview preview, {
    bool replacing = false,
  }) {
    final target = _toLeft ? _left : _right, source = _toLeft ? _right : _left;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          replacing
              ? '用${_toLeft ? '右侧' : '左侧'}「${source?.code}」替换${_toLeft ? '左侧' : '右侧'}「${target?.code}」'
              : '保存${_toLeft ? '左侧' : '右侧'}「${target?.code}」的全部暂存修改',
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          replacing
              ? '新增 ${replacement.added} 项，修改 ${replacement.updated} 项，删除 ${replacement.removed} 项，调整顺序 ${replacement.moved} 项。'
              : '暂存 ${preview.operationCount} 项操作，涉及 ${preview.affectedParents.length} 个父件。',
        ),
        if (replacing) const Text('确认后仅更新草稿，最后点击保存并确认后才会生效。'),
        if (replacing &&
            (_toLeft ? _comparison?.right : _comparison?.left)?.isEmpty == true)
          Text(
            '来源没有组件，将清空目标组件。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (replacing && _left?.unitName != _right?.unitName)
          Text(
            '左右基本单位不同：${_left?.unitName ?? '未设置'} / ${_right?.unitName ?? '未设置'}。按原设计数量复制，不自动换算。',
          ),
        if (preview.otherUsageCount > 0)
          Text(
            '目标 BOM 还被 ${preview.otherUsageCount} 处引用，保存将同步影响这些引用。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (preview.warnings.isNotEmpty) Text(preview.warnings.join('\n')),
      ],
    );
  }

  Widget _actions() {
    if (_reviewDialogOpen) return const SizedBox.shrink();
    final replacement = _replacement, preview = _preview;
    if (replacement != null && preview != null) {
      return Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _reviewBody(replacement, preview),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy || replacement.draft.isCommitRecoveryPending
                      ? null
                      : () => setState(() {
                          _replacement = null;
                          _preview = null;
                          _error = null;
                        }),
                  child: const Text('返回继续编辑'),
                ),
                FilledButton(
                  key: const Key('bom-compare-confirm'),
                  onPressed: _busy
                      ? null
                      : () => replacement.draft.isCommitRecoveryPending
                            ? _commit()
                            : _resumeReview(),
                  child: Text(
                    replacement.draft.isCommitRecoveryPending
                        ? '核对上次保存结果'
                        : '重新核对并保存',
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
          if (_editor?.hasChanges == true) const Text('有未保存修改 · 编辑和替换均在保存后生效'),
          if (_editor?.hasMasterChanges == true)
            const Text('规格、型号等属于共用货品属性，保存会同步相同组件'),
          if (_editor?.hasStaleRoots == true)
            const Text('另一侧仍有基于旧版共用资料的草稿，请按保存提示核对版本'),
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
            Expanded(
              child: GoodsBomComparisonTables(
                editor: _editor,
                onEditError: (error) {
                  if (mounted) setState(() => _error = _errorText(error));
                },
                comparison: _comparison,
                leftHeader: _product(true),
                rightHeader: _product(false),
                leftActions: _sideActions(true),
                rightActions: _sideActions(false),
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
