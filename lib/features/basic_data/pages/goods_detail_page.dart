// 货品详情整页（基础资料-货品资料）：列表双击行 / 「添加货品」/ 研发任务 /
// 物料反查统一入口，路由 /basicinfo/goods/new、/basicinfo/goods/:id（?tab= 指定页签）。
//
// 取代原来的居中弹窗（920 宽，用户反馈太小看不清）：三页签（基本信息 /
// 组装信息 / 成本预算）铺满整页，组装信息表格吃满全宽，表单/只读网格限宽
// 960 居中。增删改、BOM、成本、预览逻辑全部在 GoodsDetailBody 里，本页只负责：
// - 按 goodsId 拉详情（含加载/失败重试），或 categoryId 进入新增态；
// - canEdit 按 goods:edit 权限（或超管）自算，不再由调用方传入；
// - 删除：确认 → 删 → 返回来源页（popOrBackTo，深链兜底回货品资料）；
// - 「出入库流水」：有 stock:view 权限才显示，push 流水页压栈，返回回本详情页。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/goods_node.dart';
import '../repositories/goods_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/goods_detail_body.dart';

class GoodsDetailPage extends ConsumerStatefulWidget {
  const GoodsDetailPage({
    super.key,
    this.goodsId,
    this.categoryId,
    this.initialTab = 0,
  });

  /// 既有货品 id：查看/编辑态。为空则进入新增态（[categoryId] 应有值，
  /// 缺失时页面显示参数错误而非崩溃——手敲 URL 直达的兜底）。
  final String? goodsId;

  /// 新增态所属分类 id（基本信息表单提交时随 body 上送）。
  final String? categoryId;

  /// 初始页签：0=基本信息，1=组装信息，2=成本预算（研发任务/反查直达 BOM）。
  final int initialTab;

  @override
  ConsumerState<GoodsDetailPage> createState() => _GoodsDetailPageState();
}

class _GoodsDetailPageState extends ConsumerState<GoodsDetailPage> {
  GoodsDetail? _detail;
  bool _loading = false;
  String? _error;

  bool get _isCreate => widget.goodsId == null;

  @override
  void initState() {
    super.initState();
    if (!_isCreate) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ref.read(goodsRepositoryProvider).detail(widget.goodsId!);
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
        _error = '加载货品详情失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  Future<void> _toggleStatus() async {
    final d = _detail;
    if (d == null) return;
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(
            resourcePath: ApiEndpoints.good(d.id),
            status: next,
            version: d.version,
          ),
      success: next == '禁用' ? '货品已停用' : '货品已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _load();
  }

  /// 删除：确认 → 删 → 回本页上一级（列表 push 进来则 pop 回列表）。
  Future<void> _delete() async {
    final d = _detail;
    if (d == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除货品'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该货品')}」吗？', // TODO(l10n): 补 arb
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final deleted = await context.guardRun(
      () async {
        await ref.read(goodsRepositoryProvider).delete(d.id);
      },
      success: '货品已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    popOrBackTo(context, defaultPath: RouteName.basicinfoGoods);
  }

  @override
  Widget build(BuildContext context) {
    // 权限来自会话快照，必须 watch 而不是 read：登录恢复或管理员刷新授权后，本页
    // 立即重建按钮，避免已持有 goods:bom:create 却看不到「添加组件」。
    final isAdmin = ref.watch(isSuperAdminProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    bool can(String permission) => isAdmin || permissions.contains(permission);
    final canCreate = can(Perm.goodsCreate);
    final writable = _isCreate || _detail?.writable == true;
    final canEdit = can(Perm.goodsEdit) && writable;
    final canDelete = can(Perm.goodsDelete) && writable;
    final canStatus = can(Perm.goodsStatus) && writable;
    final canBomCreate = can(Perm.goodsBomCreate);
    final canBomEdit = can(Perm.goodsBomEdit);
    final canBomDelete = can(Perm.goodsBomDelete);
    final canViewStock = can(Perm.stockView);

    if (_isCreate && widget.categoryId == null) {
      return Scaffold(
        body: Center(child: UtenEmpty.error(message: '缺少分类参数，无法新增货品')),
      );
    }
    if (!_isCreate) {
      if (_loading && _detail == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (_error != null && _detail == null) {
        return Scaffold(
          body: Center(
            child: UtenEmpty.error(
              message: _error,
              actionLabel: '重试', // TODO(l10n): 补 arb
              onAction: _load,
            ),
          ),
        );
      }
    }
    return Scaffold(
      // 局部 SelectionArea：货品详情文字可框选复制（准则 §3.4）。
      body: SelectionArea(
        child: GoodsDetailBody(
          // 详情拉到后再挂主体；新增态直接进 create。
          key: ValueKey(
            'goods-detail-${_detail?.id ?? 'new-${widget.categoryId}'}',
          ),
          initialDetail: _detail,
          initialCategoryId: widget.categoryId,
          initialTab: widget.initialTab,
          canCreate: canCreate,
          canEdit: canEdit,
          canStatus: canStatus,
          canBomCreate: canBomCreate,
          canBomEdit: canBomEdit,
          canBomDelete: canBomDelete,
          onToggleStatus: canStatus && !_isCreate ? _toggleStatus : null,
          onDelete: canDelete && !_isCreate ? _delete : null,
          onViewMovements: canViewStock && !_isCreate
              ? () {
                  final id = _detail?.id;
                  if (id != null && id.isNotEmpty) {
                    context.push('${RouteName.stockMovement}?goodsId=$id');
                  }
                }
              : null,
          // 整页语义下来源页刷新由「返回时重载」统一承担（各入口 push 后
          // await 恢复即刷新），此处无需回调。
          onDataChanged: null,
        ),
      ),
    );
  }
}
