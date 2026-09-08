// 收付款类别管理页（基础资料 · 邻接树 + 物化路径）。
//
// 这是纯分类主档，不套用“分类摘要卡 + 下方业务表格”的通用详情页模板：
// 大屏采用可调宽目录树 + 页面级属性检查器，手机采用详情 + 分类抽屉。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/uten_location_field.dart';
import '../models/payment_style_node.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/uten_category_tree_view.dart';

const _protectedRootCodes = <String>{
  '031',
  '032',
  '033',
  '041',
  '042',
  '043',
  '101',
  '102',
  '113',
  '123',
  '139',
  '151',
  '152',
  '172',
  '173',
  '203',
  '204',
  '205',
  '221',
  '301',
  '321',
  'SYS-ACCOUNT-BALANCE-CLEARING',
};

bool _isProtectedSystemDetail(PaymentStyleDetail detail) =>
    (detail.level == 0 && _protectedRootCodes.contains(detail.code)) ||
    _hasProtectedSystemName(detail);

bool _hasProtectedSystemName(PaymentStyleDetail detail) =>
    detail.category == PaymentStyleCategory.expense.value &&
    const {'手续费', '汇兑损益'}.contains(detail.name);

bool _hasActiveDescendant(PaymentStyleNode node) => node.children.any(
  (child) => child.status == '使用' || _hasActiveDescendant(child),
);

class PaymentStylePage extends ConsumerStatefulWidget {
  const PaymentStylePage({super.key});

  @override
  ConsumerState<PaymentStylePage> createState() => _PaymentStylePageState();
}

class _PaymentStylePageState extends ConsumerState<PaymentStylePage> {
  final _treeRequest = LatestRequestGuard();

  PaymentStyleCategory _category = PaymentStyleCategory.expense;
  List<PaymentStyleNode> _tree = const [];
  String? _selectedId;
  bool _treeLoading = true;
  String? _treeError;
  int _detailRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleCreate);
  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleStatus);
  bool get _canMove =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleMove);
  bool get _canReorder =>
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleReorder);
  bool get _canManage => _canEdit || _canStatus || _canMove || _canReorder;

  Future<void> _load({String? preferredSelectionId}) async {
    if (!mounted) return;
    final request = _treeRequest.begin();
    final category = _category;
    setState(() {
      _treeLoading = true;
      _treeError = null;
    });

    try {
      final tree = await ref
          .read(paymentStyleRepositoryProvider)
          .tree(category: category.value);
      if (!mounted ||
          !_treeRequest.isCurrent(request) ||
          category != _category) {
        return;
      }
      setState(() {
        _tree = tree;
        final preferred = preferredSelectionId ?? _selectedId;
        _selectedId = preferred != null && _findById(tree, preferred) != null
            ? preferred
            : (tree.isEmpty ? null : tree.first.id);
        _treeLoading = false;
        _detailRevision++;
      });
    } on ApiException catch (e) {
      if (!mounted || !_treeRequest.isCurrent(request)) return;
      setState(() {
        _treeError = e.message;
        _treeLoading = false;
      });
    } catch (_) {
      if (!mounted || !_treeRequest.isCurrent(request)) return;
      setState(() {
        _treeError = '加载类别树失败，请稍后重试';
        _treeLoading = false;
      });
    }
  }

  PaymentStyleNode? _findById(List<PaymentStyleNode> nodes, String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
      final found = _findById(node.children, id);
      if (found != null) return found;
    }
    return null;
  }

  int _nodeCount(List<PaymentStyleNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      count += 1 + _nodeCount(node.children);
    }
    return count;
  }

  void _invalidatePaymentStyleCaches() {
    final revision = ref.read(paymentStyleRevisionProvider);
    ref.read(paymentStyleRevisionProvider.notifier).state = revision + 1;
  }

  void _switchCategory(PaymentStyleCategory category) {
    if (category == _category) return;
    setState(() {
      _category = category;
      _tree = const [];
      _selectedId = null;
      _treeError = null;
    });
    _load();
  }

  void _select(String id, {bool closeDrawer = false}) {
    setState(() => _selectedId = id);
    if (closeDrawer) Navigator.of(context).maybePop();
  }

  // ---- CRUD ---------------------------------------------------------------

  void _showCreate({PaymentStyleNode? parent}) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PaymentStyleEditDialog(
        tree: _tree,
        category: _category,
        initialParent: parent,
        canStatus: _canStatus,
        onSubmit: _doCreate,
      ),
    );
  }

  Future<bool> _doCreate(_EditResult result) async {
    PaymentStyleDetail? created;
    final ok = await context.guardRun(
      () async {
        created = await ref
            .read(paymentStyleRepositoryProvider)
            .create(
              PaymentStyleSaveInput(
                code: '',
                name: result.name,
                category: _category.value,
                parentId: result.parentId,
                sortOrder: result.sortOrder,
                receipt: result.receipt,
                payment: result.payment,
                departmental: result.departmental,
                status: result.status,
              ),
            );
      },
      success: '类别已创建',
      errorFallback: '创建失败，请稍后重试',
    );
    if (!ok) return false;
    _invalidatePaymentStyleCaches();
    await _load(preferredSelectionId: created?.id);
    return true;
  }

  void _showEdit(PaymentStyleDetail detail) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PaymentStyleEditDialog(
        tree: _tree,
        category: _category,
        editing: detail,
        canEditFields: _canEdit,
        canMove: _canMove,
        canReorder: _canReorder,
        canStatus: _canStatus,
        onSubmit: (result) => _doUpdate(detail.id, result),
      ),
    );
  }

  Future<bool> _doUpdate(String id, _EditResult result) async {
    if (!result.hasChanges) return true;
    final ok = await context.guardRun(
      () async {
        await ref
            .read(paymentStyleRepositoryProvider)
            .update(
              id,
              PaymentStyleUpdateInput(
                name: result.nameChanged ? result.name : null,
                parentId: result.parentChanged ? result.parentId : null,
                moveToRoot: result.moveToRoot,
                sortOrder: result.sortOrderChanged ? result.sortOrder : null,
                receipt: result.receiptChanged ? result.receipt : null,
                payment: result.paymentChanged ? result.payment : null,
                departmental: result.departmentalChanged
                    ? result.departmental
                    : null,
                status: result.statusChanged ? result.status : null,
              ),
            );
      },
      success: '类别已更新',
      errorFallback: '更新失败，请稍后重试',
    );
    if (!ok) return false;
    _invalidatePaymentStyleCaches();
    await _load(preferredSelectionId: id);
    return true;
  }

  Future<void> _toggleStatus(PaymentStyleDetail detail) async {
    final disabling = detail.status != '禁用';
    if (disabling) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('停用类别'),
          content: Text('停用「${detail.name}」后，新业务应不再选择它；历史单据仍保留原类别。确定继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('停用'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final nextStatus = disabling ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(paymentStyleRepositoryProvider)
          .update(detail.id, PaymentStyleUpdateInput(status: nextStatus)),
      success: disabling ? '类别已停用' : '类别已启用',
      errorFallback: disabling ? '停用失败，请稍后重试' : '启用失败，请稍后重试',
    );
    if (ok && mounted) {
      _invalidatePaymentStyleCaches();
      await _load(preferredSelectionId: detail.id);
    }
  }

  // ---- 目录 ---------------------------------------------------------------

  Widget _buildDirectory({bool closeOnSelect = false}) {
    final theme = Theme.of(context);
    final count = _nodeCount(_tree);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '类别目录',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _treeLoading && _tree.isEmpty
                            ? '正在加载'
                            : '${_category.label} · $count 项',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_canCreate)
                  IconButton(
                    tooltip: '添加顶级类别',
                    onPressed: () => _showCreate(),
                    icon: const Icon(Icons.add_rounded),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              0,
              UtenSpacing.s12,
              UtenSpacing.s12,
            ),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final category in PaymentStyleCategory.values)
                  ChoiceChip(
                    showCheckmark: false,
                    avatar: Icon(_categoryIcon(category), size: 16),
                    label: Text(category.label),
                    selected: category == _category,
                    onSelected: (_) => _switchCategory(category),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(child: _buildDirectoryContent(closeOnSelect)),
        ],
      ),
    );
  }

  Widget _buildDirectoryContent(bool closeOnSelect) {
    if (_treeLoading && _tree.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_treeError != null && _tree.isEmpty) {
      return UtenEmpty.error(
        message: _treeError,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    if (_tree.isEmpty) {
      return UtenEmpty(
        icon: Icons.account_tree_outlined,
        message: '${_category.label}下暂无类别',
        actionLabel: _canCreate ? '添加顶级类别' : null,
        onAction: _canCreate ? () => _showCreate() : null,
      );
    }

    final theme = Theme.of(context);
    return Stack(
      children: [
        Column(
          children: [
            if (_treeError != null)
              Material(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.error_outline_rounded,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  title: Text(
                    _treeError!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                  trailing: TextButton(
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ),
              ),
            Expanded(
              child: UtenCategoryTreeView<PaymentStyleNode>(
                nodes: _tree,
                selectedIds: {?_selectedId},
                expandOnRowTap: true,
                sortByCode: false,
                searchHint: '搜索类别名称或编号',
                onNodeTap: (node) =>
                    _select(node.id, closeDrawer: closeOnSelect),
                trailingBuilder: (node) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (node.status == '禁用')
                      const Padding(
                        padding: EdgeInsets.only(right: UtenSpacing.s4),
                        child: UtenStatusBadge(
                          label: '禁用',
                          type: UtenStatusBadgeType.neutral,
                          size: UtenStatusBadgeSize.small,
                        ),
                      ),
                    if (node.hasChildren)
                      Text(
                        '${node.children.length}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_treeLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  static IconData _categoryIcon(PaymentStyleCategory category) =>
      switch (category) {
        PaymentStyleCategory.account => Icons.account_balance_wallet_outlined,
        PaymentStyleCategory.liability => Icons.credit_card_outlined,
        PaymentStyleCategory.equity => Icons.pie_chart_outline_rounded,
        PaymentStyleCategory.expense => Icons.trending_down_rounded,
        PaymentStyleCategory.income => Icons.trending_up_rounded,
        PaymentStyleCategory.method => Icons.payments_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final selected = _selectedId == null
        ? null
        : _findById(_tree, _selectedId!);

    Widget detail = selected == null
        ? const UtenEmpty(
            icon: Icons.touch_app_outlined,
            message: '从类别目录选择一项查看属性',
          )
        : _PaymentStyleInspector(
            node: selected,
            revision: _detailRevision,
            canCreate: _canCreate,
            canManage: _canManage,
            canEdit: _canEdit,
            canStatus: _canStatus,
            onAddChild: () => _showCreate(parent: selected),
            onEdit: _showEdit,
            onToggleStatus: _toggleStatus,
            onSelectChild: (id) => _select(id),
          );

    // medium 断点及较窄桌面屏的可用内容宽度还要扣除左侧 Rail；
    // 960dp 以下改用抽屉，避免把目录树压成不可用的窄栏。
    final directoryInDrawer = MediaQuery.sizeOf(context).width < 960;
    if (directoryInDrawer) {
      detail = UtenContentContainer(
        child: Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: detail,
        ),
      );
    }

    final body = directoryInDrawer
        ? detail
        : UtenSplitView(
            persistenceKey: 'basicData.paymentStyle',
            initialLeadingWidth: 320,
            minLeadingWidth: 260,
            maxLeadingWidth: 460,
            minTrailingWidth: 440,
            leading: _buildDirectory(),
            trailing: detail,
          );

    return Scaffold(
      appBar: UtenAppBar(
        title: '收付款类别',
        subtitle: directoryInDrawer ? null : '维护财务类别层级、业务属性与使用状态',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _treeLoading ? null : _load,
          ),
          if (directoryInDrawer)
            Builder(
              builder: (scaffoldContext) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '类别目录',
                onPressed: () => Scaffold.of(scaffoldContext).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: directoryInDrawer
          ? Drawer(child: SafeArea(child: _buildDirectory(closeOnSelect: true)))
          : null,
      body: SafeArea(child: body),
    );
  }
}

/// 页面级属性检查器：分类没有下方主档表，因此用多个语义区块承载完整信息。
class _PaymentStyleInspector extends ConsumerStatefulWidget {
  const _PaymentStyleInspector({
    required this.node,
    required this.revision,
    required this.canCreate,
    required this.canManage,
    required this.canEdit,
    required this.canStatus,
    required this.onAddChild,
    required this.onEdit,
    required this.onToggleStatus,
    required this.onSelectChild,
  });

  final PaymentStyleNode node;
  final int revision;
  final bool canCreate;
  final bool canManage;
  final bool canEdit;
  final bool canStatus;
  final VoidCallback onAddChild;
  final ValueChanged<PaymentStyleDetail> onEdit;
  final Future<void> Function(PaymentStyleDetail detail) onToggleStatus;
  final ValueChanged<String> onSelectChild;

  @override
  ConsumerState<_PaymentStyleInspector> createState() =>
      _PaymentStyleInspectorState();
}

class _PaymentStyleInspectorState
    extends ConsumerState<_PaymentStyleInspector> {
  final _request = LatestRequestGuard();
  PaymentStyleDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PaymentStyleInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  Future<void> _load() async {
    final request = _request.begin();
    setState(() {
      if (_detail?.id != widget.node.id) _detail = null;
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(paymentStyleRepositoryProvider)
          .detail(widget.node.id);
      if (!mounted || !_request.isCurrent(request)) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_request.isCurrent(request)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_request.isCurrent(request)) return;
      setState(() {
        _error = '加载类别详情失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final detail = _detail;
    if (detail == null) {
      return const UtenEmpty(
        icon: Icons.info_outline_rounded,
        message: '未找到类别详情',
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            context.breakpoint.isCompact ? 0 : UtenSpacing.s24,
            UtenSpacing.s20,
            context.breakpoint.isCompact ? 0 : UtenSpacing.s24,
            UtenSpacing.s32,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InspectorHeader(
                detail: detail,
                canCreate: widget.canCreate,
                canManage: widget.canManage,
                canEdit: widget.canEdit,
                canStatus: widget.canStatus,
                hasActiveDescendant: _hasActiveDescendant(widget.node),
                onAddChild: widget.onAddChild,
                onEdit: () => widget.onEdit(detail),
                onToggleStatus: () => widget.onToggleStatus(detail),
              ),
              const SizedBox(height: UtenSpacing.s20),
              _BasicInfoSection(detail: detail),
              const SizedBox(height: UtenSpacing.s16),
              _BusinessAttributesSection(detail: detail),
              const SizedBox(height: UtenSpacing.s16),
              _HierarchySection(detail: detail),
              if (widget.node.children.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s16),
                _ChildrenSection(
                  children: widget.node.children,
                  onSelect: widget.onSelectChild,
                ),
              ],
              if (detail.legacyId != null ||
                  detail.linkedAccountLegacyId != null ||
                  detail.initBalance != null) ...[
                const SizedBox(height: UtenSpacing.s16),
                _MigrationSection(detail: detail),
              ],
              const SizedBox(height: UtenSpacing.s24),
              const _RetentionSection(),
            ],
          ),
        ),
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _InspectorHeader extends StatelessWidget {
  const _InspectorHeader({
    required this.detail,
    required this.canCreate,
    required this.canManage,
    required this.canEdit,
    required this.canStatus,
    required this.hasActiveDescendant,
    required this.onAddChild,
    required this.onEdit,
    required this.onToggleStatus,
  });

  final PaymentStyleDetail detail;
  final bool canCreate;
  final bool canManage;
  final bool canEdit;
  final bool canStatus;
  final bool hasActiveDescendant;
  final VoidCallback onAddChild;
  final VoidCallback onEdit;
  final Future<void> Function() onToggleStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = detail.status == '禁用';
    final systemLocked = _isProtectedSystemDetail(detail);
    final protectedLeaf = systemLocked && detail.childCount == 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final identity = Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: UtenRadius.lgAll,
              ),
              child: Icon(
                Icons.account_tree_outlined,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      Text(
                        detail.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      UtenStatusBadge(
                        label: disabled ? '禁用' : '使用中',
                        type: disabled
                            ? UtenStatusBadgeType.neutral
                            : UtenStatusBadgeType.success,
                        icon: disabled
                            ? Icons.block_outlined
                            : Icons.check_circle_outline_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '${PaymentStyleCategory.labelOf(detail.category)} · 编号 ${detail.code}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        final actions = Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            if (canCreate)
              UtenButton(
                type: UtenButtonType.tonal,
                icon: Icons.add_rounded,
                onPressed: disabled || protectedLeaf ? null : onAddChild,
                onDisabledTap: disabled || protectedLeaf
                    ? () => context.appWarning(
                        disabled ? '已禁用类别不能新增子类别' : '该系统科目是可过账叶子节点，不能变成目录',
                      )
                    : null,
                child: const Text('新增子类别'),
              ),
            if (canManage)
              UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.edit_outlined,
                onPressed: onEdit,
                child: const Text('编辑'),
              ),
            if (systemLocked && !disabled)
              const Tooltip(
                message: '关键财务科目必须保持使用状态',
                child: UtenStatusBadge(
                  label: '系统锁定',
                  type: UtenStatusBadgeType.info,
                  icon: Icons.lock_outline_rounded,
                ),
              )
            else if (!disabled && hasActiveDescendant)
              const Tooltip(
                message: '请先停用或迁移使用中的子类别',
                child: UtenStatusBadge(
                  label: '子类仍在使用',
                  type: UtenStatusBadgeType.warning,
                  icon: Icons.account_tree_outlined,
                ),
              )
            else if (canStatus)
              UtenActionButton(
                type: UtenActionButtonType.ghost,
                icon: disabled
                    ? Icons.play_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                label: Text(disabled ? '启用' : '停用'),
                onAction: onToggleStatus,
              ),
          ],
        );

        if (!canCreate && !canManage && !canStatus) return identity;
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity,
              const SizedBox(height: UtenSpacing.s16),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: identity),
            const SizedBox(width: UtenSpacing.s16),
            actions,
          ],
        );
      },
    );
  }
}

class _BasicInfoSection extends StatelessWidget {
  const _BasicInfoSection({required this.detail});
  final PaymentStyleDetail detail;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(title: '基本信息', icon: Icons.badge_outlined),
          const SizedBox(height: UtenSpacing.s12),
          UtenFormGrid(
            children: [
              _InfoField(label: '系统编号', value: detail.code),
              _InfoField(
                label: '所属大类',
                value: PaymentStyleCategory.labelOf(detail.category),
              ),
              _InfoField(label: '状态', value: detail.status ?? '使用'),
              _InfoField(
                label: '同级排序',
                value: '${detail.sortOrder ?? 0}',
                helper: '数字越小越靠前',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BusinessAttributesSection extends StatelessWidget {
  const _BusinessAttributesSection({required this.detail});
  final PaymentStyleDetail detail;

  @override
  Widget build(BuildContext context) {
    final category = PaymentStyleCategory.byValue(detail.category);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(title: '业务属性', icon: Icons.tune_rounded),
          const SizedBox(height: UtenSpacing.s12),
          UtenFormGrid(
            children: [
              _FlagField(
                icon: Icons.call_received_rounded,
                label: '收款标志',
                value: detail.receipt,
              ),
              _FlagField(
                icon: Icons.call_made_rounded,
                label: '付款标志',
                value: detail.payment,
              ),
              _FlagField(
                icon: Icons.apartment_rounded,
                label: '部门核算',
                value: detail.departmental,
              ),
              if (detail.linkedAccountId != null)
                _InfoField(
                  label: '关联账户',
                  value: detail.linkedAccountId!,
                  helper: '系统 UUID 关联；账户改编号不会影响此关系',
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _InlineNotice(
            icon: Icons.info_outline_rounded,
            text: category == PaymentStyleCategory.method
                ? '“结算方式”目前是预留分类，不等同于收款单、付款单中的具体结算方式。'
                : '这些标志用于保留主档分类语义；业务能否选择该类别仍以所属大类、启用状态和是否叶子节点为准。',
          ),
        ],
      ),
    );
  }
}

class _HierarchySection extends StatelessWidget {
  const _HierarchySection({required this.detail});
  final PaymentStyleDetail detail;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(
            title: '层级关系',
            icon: Icons.account_tree_outlined,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenFormGrid(
            children: [
              _InfoField(label: '父级类别', value: detail.parentName ?? '顶级类别'),
              _InfoField(label: '所在层级', value: 'L${detail.level}'),
              _InfoField(label: '直接子类别', value: '${detail.childCount} 项'),
              _InfoField(
                label: '完整位置',
                value: detail.path.isEmpty ? '—' : detail.path,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChildrenSection extends StatelessWidget {
  const _ChildrenSection({required this.children, required this.onSelect});

  final List<PaymentStyleNode> children;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final sorted = [...children]
      ..sort((a, b) {
        final order = (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0);
        return order != 0 ? order : a.name.compareTo(b.name);
      });
    return UtenCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s16,
              UtenSpacing.s16,
              UtenSpacing.s8,
            ),
            child: UtenSectionHeader(
              title: '直接子类别(${children.length})',
              icon: Icons.subdirectory_arrow_right_rounded,
            ),
          ),
          for (var index = 0; index < sorted.length; index++) ...[
            if (index > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.folder_outlined),
              title: Text(sorted[index].name),
              subtitle: Text('编号 ${sorted[index].code}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sorted[index].status == '禁用')
                    const UtenStatusBadge(
                      label: '禁用',
                      type: UtenStatusBadgeType.neutral,
                      size: UtenStatusBadgeSize.small,
                    ),
                  const SizedBox(width: UtenSpacing.s4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: () => onSelect(sorted[index].id),
            ),
          ],
        ],
      ),
    );
  }
}

class _MigrationSection extends StatelessWidget {
  const _MigrationSection({required this.detail});
  final PaymentStyleDetail detail;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      variant: UtenCardVariant.outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(
            title: '迁移溯源(只读)',
            icon: Icons.history_rounded,
            subdued: true,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenFormGrid(
            children: [
              if (detail.legacyId != null)
                _InfoField(label: '旧系统类别 ID', value: '${detail.legacyId}'),
              if (detail.linkedAccountLegacyId != null)
                _InfoField(
                  label: '关联账户旧 ID',
                  value: '${detail.linkedAccountLegacyId}',
                ),
              if (detail.initBalance != null)
                _InfoField(
                  label: '迁移期初金额',
                  value: detail.initBalance!.toStringAsFixed(2),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RetentionSection extends StatelessWidget {
  const _RetentionSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s12,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '主档保留策略',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '财务类别不直接删除，以免破坏历史、审计链或并发业务引用。'
                        '不再使用的普通类别请在页面顶部选择“停用”。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const UtenStatusBadge(
            label: '仅可停用',
            type: UtenStatusBadgeType.warning,
            icon: Icons.lock_outline_rounded,
          ),
        ],
      ),
    );
  }
}

class _InfoField extends StatelessWidget {
  const _InfoField({required this.label, required this.value, this.helper});

  final String label;
  final String value;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label：$value',
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  SelectableText(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (helper?.isNotEmpty ?? false) UtenFieldHintIcon(info: helper),
          ],
        ),
      ),
    );
  }
}

class _FlagField extends StatelessWidget {
  const _FlagField({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          UtenStatusBadge(
            label: value ? '是' : '否',
            type: value
                ? UtenStatusBadgeType.accent
                : UtenStatusBadgeType.neutral,
            size: UtenStatusBadgeSize.small,
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditResult {
  const _EditResult({
    required this.name,
    required this.sortOrder,
    required this.status,
    required this.nameChanged,
    required this.sortOrderChanged,
    required this.receiptChanged,
    required this.paymentChanged,
    required this.departmentalChanged,
    required this.statusChanged,
    this.parentId,
    this.parentChanged = false,
    this.moveToRoot = false,
    this.receipt = false,
    this.payment = false,
    this.departmental = false,
  });

  final String name;
  final bool nameChanged;
  final String? parentId;
  final bool parentChanged;
  final bool moveToRoot;
  final int sortOrder;
  final bool sortOrderChanged;
  final bool receipt;
  final bool receiptChanged;
  final bool payment;
  final bool paymentChanged;
  final bool departmental;
  final bool departmentalChanged;
  final String status;
  final bool statusChanged;

  bool get hasChanges =>
      nameChanged ||
      parentChanged ||
      sortOrderChanged ||
      receiptChanged ||
      paymentChanged ||
      departmentalChanged ||
      statusChanged;
}

class _PaymentStyleEditDialog extends StatefulWidget {
  const _PaymentStyleEditDialog({
    required this.tree,
    required this.category,
    required this.onSubmit,
    this.initialParent,
    this.editing,
    this.canEditFields = true,
    this.canMove = true,
    this.canReorder = true,
    this.canStatus = true,
  });

  final List<PaymentStyleNode> tree;
  final PaymentStyleCategory category;
  final PaymentStyleNode? initialParent;
  final PaymentStyleDetail? editing;
  final bool canEditFields;
  final bool canMove;
  final bool canReorder;
  final bool canStatus;
  final Future<bool> Function(_EditResult result) onSubmit;

  @override
  State<_PaymentStyleEditDialog> createState() =>
      _PaymentStyleEditDialogState();
}

class _PaymentStyleEditDialogState extends State<_PaymentStyleEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _sortOrderController;
  late PaymentStyleNode? _parent;
  late bool _receipt;
  late bool _payment;
  late bool _departmental;
  late String _status;
  late final Set<String> _blockedParentIds;
  late bool _parentResolved;
  bool _locationTouched = false;
  String? _formError;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _nameController = TextEditingController(text: editing?.name ?? '');
    _sortOrderController = TextEditingController(
      text: '${editing?.sortOrder ?? 0}',
    );
    _receipt = editing?.receipt ?? false;
    _payment = editing?.payment ?? false;
    _departmental = editing?.departmental ?? false;
    _status = editing?.status ?? '使用';
    if (editing?.parentId == null) {
      _parent = widget.initialParent;
      _parentResolved = true;
    } else {
      _parent = _findById(widget.tree, editing!.parentId!);
      _parentResolved = _parent != null;
    }
    _blockedParentIds = editing == null
        ? <String>{}
        : _descendantIds(editing.id);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sortOrderController.dispose();
    super.dispose();
  }

  PaymentStyleNode? _findById(List<PaymentStyleNode> nodes, String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
      final found = _findById(node.children, id);
      if (found != null) return found;
    }
    return null;
  }

  Set<String> _descendantIds(String id) {
    final root = _findById(widget.tree, id);
    if (root == null) return {id};
    final ids = <String>{id};
    void walk(List<PaymentStyleNode> nodes) {
      for (final node in nodes) {
        ids.add(node.id);
        walk(node.children);
      }
    }

    walk(root.children);
    return ids;
  }

  bool _canUseAsParent(PaymentStyleNode node) =>
      !_blockedParentIds.contains(node.id) && node.status != '禁用';

  bool get _positionChanged {
    if (!_isEdit || !_locationTouched) return false;
    return _parent?.id != widget.editing!.parentId;
  }

  String? _pathTo(String id) {
    List<String>? walk(List<PaymentStyleNode> nodes, List<String> path) {
      for (final node in nodes) {
        final next = [...path, node.name];
        if (node.id == id) return next;
        final found = walk(node.children, next);
        if (found != null) return found;
      }
      return null;
    }

    return walk(widget.tree, const [])?.join(' › ');
  }

  Future<void> _pickParent() async {
    final result = await showUtenPickerSheet<PaymentStyleNode>(
      context: context,
      title: '选择父级类别',
      rootLabel: '顶级类别',
      rootHint: '不归属于其他类别',
      initialSelection: !_parentResolved
          ? null
          : _parent == null
          ? (node: null, isRoot: true)
          : (node: _parent, isRoot: false),
      childBuilder: (sheetContext, pendingSelection, onSelect, onSelectRoot) {
        return Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: UtenCategoryTreeView<PaymentStyleNode>(
            nodes: widget.tree,
            mode: UtenCategoryTreeMode.single,
            selectedIds: {
              if (pendingSelection?.node != null) pendingSelection!.node!.id,
            },
            sortByCode: false,
            initiallyExpandDepth: 2,
            searchHint: '搜索类别名称或编号',
            nodeEnabledPredicate: _canUseAsParent,
            onToggleSelect: onSelect,
            trailingBuilder: (node) {
              if (_blockedParentIds.contains(node.id)) {
                return const Tooltip(
                  message: '不能选择自身或其下级',
                  child: Icon(Icons.block_rounded, size: 18),
                );
              }
              if (node.status == '禁用') {
                return const Tooltip(
                  message: '不能选择已禁用类别',
                  child: Icon(Icons.pause_circle_outline, size: 18),
                );
              }
              return null;
            },
          ),
        );
      },
    );
    if (result == null || !mounted) return;
    setState(() {
      _parent = result.isRoot ? null : result.node;
      _parentResolved = true;
      _locationTouched = true;
      _formError = null;
    });
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _formError = '请输入类别名称');
      return;
    }
    final sortOrder = int.tryParse(_sortOrderController.text.trim());
    if (sortOrder == null) {
      setState(() => _formError = '同级排序必须是整数');
      return;
    }
    if ((!_isEdit || _positionChanged) &&
        _parent != null &&
        !_canUseAsParent(_parent!)) {
      setState(() => _formError = '父级不能是自身、下级或已禁用类别');
      return;
    }

    setState(() => _formError = null);
    final editing = widget.editing;
    final ok = await widget.onSubmit(
      _EditResult(
        name: name,
        nameChanged: editing == null || name != editing.name,
        parentId: _parent?.id,
        parentChanged: _positionChanged,
        moveToRoot:
            _positionChanged &&
            editing != null &&
            editing.parentId != null &&
            _parent == null,
        sortOrder: sortOrder,
        sortOrderChanged: editing == null || sortOrder != editing.sortOrder,
        receipt: _receipt,
        receiptChanged: editing == null || _receipt != editing.receipt,
        payment: _payment,
        paymentChanged: editing == null || _payment != editing.payment,
        departmental: _departmental,
        departmentalChanged:
            editing == null || _departmental != editing.departmental,
        status: _status,
        statusChanged: editing == null || _status != editing.status,
      ),
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unresolvedParent =
        _isEdit && widget.editing!.parentId != null && !_parentResolved;
    final parentLevel = _parent?.level;
    final resultLevel = unresolvedParent
        ? widget.editing!.level
        : _parent == null
        ? 0
        : (parentLevel ?? 0) + 1;
    final parentPathLabel = unresolvedParent
        ? (widget.editing!.parentName?.isNotEmpty == true
              ? widget.editing!.parentName
              : '当前上级(目录尚未同步)')
        : _parent == null
        ? null
        : _pathTo(_parent!.id);
    final protectedName = _isEdit && _hasProtectedSystemName(widget.editing!);
    return AlertDialog(
      title: Text(_isEdit ? '编辑类别' : '新增${widget.category.label}类别'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isEdit)
                TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  enabled: false,
                  initialValue: widget.editing!.code,
                  decoration: const UtenInputDecoration(
                    InputDecoration(labelText: '系统编号'),
                  ),
                )
              else
                const _InlineNotice(
                  icon: Icons.auto_awesome_outlined,
                  text: '系统编号将在保存后自动生成，所属大类创建后不可更改。',
                ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _nameController,
                autofocus: !protectedName && (!_isEdit || widget.canEditFields),
                enabled: !protectedName && (!_isEdit || widget.canEditFields),
                maxLength: 120,
                decoration: const InputDecoration(labelText: '类别名称 *'),
              ),
              if (protectedName) ...[
                const SizedBox(height: UtenSpacing.s8),
                const _InlineNotice(
                  icon: Icons.lock_outline_rounded,
                  text: '该名称被财务过账流程按稳定身份使用，不能修改。',
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _sortOrderController,
                readOnly: _isEdit && !widget.canReorder,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '同级排序',
                      theme,
                      required: true,
                      info: '数字越小越靠前，仅在同一父级内比较',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              UtenLocationField(
                headingLabel: '所属位置',
                pathLabel: parentPathLabel,
                rootLabel: '顶级类别',
                resultLevelLabel: 'L$resultLevel',
                enabled:
                    (!_isEdit || widget.canMove) &&
                    (!_isEdit || !_isProtectedSystemDetail(widget.editing!)),
                onTap: _pickParent,
              ),
              const SizedBox(height: UtenSpacing.s20),
              const UtenSectionHeader(title: '业务属性', icon: Icons.tune_rounded),
              const SizedBox(height: UtenSpacing.s8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('收款标志'),
                subtitle: const Text('保留该类别的收方向主档属性'),
                value: _receipt,
                onChanged: _isEdit && !widget.canEditFields
                    ? null
                    : (value) => setState(() => _receipt = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('付款标志'),
                subtitle: const Text('保留该类别的付方向主档属性'),
                value: _payment,
                onChanged: _isEdit && !widget.canEditFields
                    ? null
                    : (value) => setState(() => _payment = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('部门核算'),
                subtitle: const Text('标识该类别是否具有部门核算属性'),
                value: _departmental,
                onChanged: _isEdit && !widget.canEditFields
                    ? null
                    : (value) => setState(() => _departmental = value),
              ),
              const SizedBox(height: UtenSpacing.s8),
              UtenDropdownField(
                label: '状态',
                value: _status,
                enabled:
                    widget.canStatus &&
                    (widget.editing == null ||
                        !_isProtectedSystemDetail(widget.editing!) ||
                        _status == '禁用'),
                items: const [
                  UtenDropdownItem(value: '使用', label: '使用'),
                  UtenDropdownItem(value: '禁用', label: '禁用'),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _status = value);
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              _InlineNotice(
                icon: Icons.info_outline_rounded,
                text: widget.category == PaymentStyleCategory.method
                    ? '结算方式分类目前为预留主档，不会自动绑定收款单或付款单的具体结算方式。'
                    : '业务是否允许选择还会校验大类、启用状态和叶子节点；这些开关不替代业务校验。',
              ),
              if (_formError != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _formError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenActionButton(
          icon: _isEdit ? Icons.save_outlined : Icons.add_rounded,
          label: Text(_isEdit ? '保存' : '创建'),
          loadingLabel: const Text('保存中'),
          onAction: _submit,
        ),
      ],
    );
  }
}
