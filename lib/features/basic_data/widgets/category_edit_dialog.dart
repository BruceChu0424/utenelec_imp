import '../../../components/feedback/uten_task_progress_dialog.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/hierarchy/category_sibling_names.dart';
// CategoryEditDialog - 货品/模具/客户/供应商 分类 新增/编辑 对话框。
//
// 仿 department_page._showCreateDialog 的 AlertDialog 范式，但抽成独立组件：
// - 字段：编号前缀、名称、备注、父级；分类身份始终是系统 UUID；
// - 父级通过树形选择子弹层挑选，预校验「不能选自己 / 不能选自己的后代」；
// - 新增态在「名称」下提供常用分类建议（[suggestions]），一键填入，降低起名门槛；
// - 提交按钮用 UtenActionButton（自带 loading + 防连点）。
//
// 提交通过 onSubmit 回调上抛，由页面执行真正的仓储调用并返回是否成功；
// 成功时对话框自行关闭。
import 'dart:async';

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_values.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/widgets/uten_location_field.dart';
import '../models/product_category_node.dart';
import 'uten_category_tree_view.dart';

class CategoryEditResult {
  const CategoryEditResult({
    required this.name,
    required this.codePrefix,
    required this.remark,
    this.parentId,
    this.version,
    this.sortOrder,
    this.moveToRoot = false,
  });

  final String name;
  final String codePrefix;
  final String remark;
  final int? version;
  final int? sortOrder;
  final bool moveToRoot;

  /// 新建时是所选父级；编辑时仅在父级实际改变后非空。
  final String? parentId;
}

class CategoryEditDialog extends ConsumerStatefulWidget {
  const CategoryEditDialog({
    super.key,
    this.draftSpec,
    this.resumeDraftId,
    this.routerPageKey,
    required this.tree,
    required this.onSubmit,
    this.initialParent,
    this.editing,
    this.onCheckPrefix,
    this.onPreviewPrefixChange,
    this.canEditFields = true,
    this.canMove = true,
    this.canReorder = true,
  });

  final FormDraftSpec? draftSpec;
  final String? resumeDraftId;
  final ValueKey<String>? routerPageKey;

  /// 全树，用于父级挑选子弹层。
  final List<ProductCategoryNode> tree;

  /// 新建模式下的默认父级（可空=顶级）。
  final ProductCategoryNode? initialParent;

  /// 编辑模式：传入现有详情。非 null 时为编辑态（code 只读）。
  final ProductCategoryDetail? editing;

  final bool canEditFields;
  final bool canMove;
  final bool canReorder;

  /// 只读检查全系统前缀占用；保存仍由服务器事务做最终查重。
  final Future<CategoryPrefixAvailability> Function(String requestedPrefix)?
  onCheckPrefix;

  /// 编辑时前缀发生变化才调用；返回影响数量并在提交前二次确认。
  final Future<CategoryPrefixPreview> Function(
    String requestedPrefix,
    String? requestedParentId,
  )?
  onPreviewPrefixChange;

  /// 提交回调：返回 true 表示成功（对话框关闭），false 表示失败（保持打开）。
  final Future<bool> Function(CategoryEditResult result) onSubmit;

  @override
  ConsumerState<CategoryEditDialog> createState() => _CategoryEditDialogState();
}

class _CategoryEditDialogState extends ConsumerState<CategoryEditDialog>
    with FormDraftMixin<CategoryEditDialog> {
  late final TextEditingController _prefixCtl;
  late final TextEditingController _nameCtl;
  late final TextEditingController _remarkCtl;
  late final TextEditingController _sortCtl;
  ProductCategoryNode? _parent;
  String? _formError;

  String? get _nameError {
    final name = _nameCtl.text.trim();
    final editing = widget.editing;
    if (editing != null &&
        name == editing.name.trim() &&
        _parent?.id == editing.parentId) {
      return null;
    }
    if (name.isEmpty) return null;
    return hasDuplicateSiblingName<ProductCategoryNode>(
          roots: widget.tree,
          childrenOf: (node) => node.children,
          idOf: (node) => node.id,
          parentIdOf: (node) => node.parentId,
          nameOf: (node) => node.name,
          name: name,
          parentId: _parent?.id,
          excludingId: widget.editing?.id,
        )
        ? '同一上级下已有分类“$name”，请更换名称'
        : null;
  }

  void _nameChanged() {
    if (mounted) setState(() => _formError = null);
  }

  Timer? _prefixDebounce;
  int _prefixRevision = 0;
  String? _observedPrefix;
  String? _prefixError;
  bool _prefixChecking = false;
  bool _prefixCheckFailed = false;

  String get _normalizedPrefix => _prefixCtl.text.trim().toUpperCase();
  bool get _canCheckPrefix =>
      widget.onCheckPrefix != null && (!_isEdit || widget.canEditFields);

  String? _prefixFormatError(String prefix) =>
      prefix.isNotEmpty && !RegExp(r'^[A-Z0-9]{1,8}$').hasMatch(prefix)
      ? '编号前缀只能包含 1–8 位字母或数字，可用数字开头'
      : null;

  void _onPrefixChanged() {
    final prefix = _normalizedPrefix;
    if (prefix == _observedPrefix) return;
    _observedPrefix = prefix;
    _queuePrefixCheck();
  }

  void _queuePrefixCheck({bool immediately = false}) {
    _prefixDebounce?.cancel();
    final revision = ++_prefixRevision;
    final prefix = _normalizedPrefix;
    final formatError = _serverCreated ? null : _prefixFormatError(prefix);
    final shouldCheck =
        !_serverCreated &&
        _canCheckPrefix &&
        prefix.isNotEmpty &&
        formatError == null;
    setState(() {
      _prefixError = formatError;
      _prefixCheckFailed = false;
      _prefixChecking = shouldCheck;
    });
    if (shouldCheck) {
      _prefixDebounce = Timer(
        immediately ? Duration.zero : const Duration(milliseconds: 300),
        () => unawaited(_checkPrefix(prefix, revision)),
      );
    }
  }

  Future<bool> _checkPrefix(String prefix, int revision) async {
    try {
      final result = await widget.onCheckPrefix!(prefix);
      if (!mounted || revision != _prefixRevision) return false;
      if (result.normalizedPrefix != prefix) {
        throw StateError('前缀检查结果与当前输入不一致');
      }
      setState(() {
        _prefixChecking = false;
        _prefixCheckFailed = false;
        _prefixError = result.available ? null : '编号前缀“$prefix”已被占用，请更换后再保存。';
      });
      return result.available;
    } catch (_) {
      if (!mounted || revision != _prefixRevision) return false;
      setState(() {
        _prefixChecking = false;
        _prefixCheckFailed = true;
        _prefixError = '暂时无法检查编号前缀，请重新检查后保存。';
      });
      return false;
    }
  }

  bool get _isEdit => widget.editing != null;

  late final bool Function() _ownerIsCurrent;

  bool _saving = false;
  bool _submissionWaiting = false;
  final _ownerChanges = ValueNotifier<int>(0);
  bool _serverCreated = false;
  @override
  bool get formDraftEnabled => !_isEdit && widget.draftSpec != null;
  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => _serverCreated;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  ValueKey<String>? get formDraftRouterPageKey => widget.routerPageKey;
  @override
  FormDraftSpec get formDraftSpec => widget.draftSpec!;
  Map<String, TextEditingController> get _draftControllers => {
    'prefixCtl': _prefixCtl,
    'nameCtl': _nameCtl,
    'remarkCtl': _remarkCtl,
    'sortCtl': _sortCtl,
  };
  @override
  Iterable<Listenable> get formDraftListenables => _draftControllers.values;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'text': draftTextValues(_draftControllers),
    'parentId': _parent?.id,
    'serverCreated': _serverCreated,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    restoreDraftTextValues(_draftControllers, draftMap(data['text']));
    final parentId = data['parentId'] as String?;
    _parent = parentId == null ? null : _findById(widget.tree, parentId);
    if (parentId != null && _parent == null) {
      throw StateError('草稿的上级位置已不存在，请核查后重新选择');
    }
    _serverCreated = data['serverCreated'] == true;
    _queuePrefixCheck();
  }

  Future<void> _close() async {
    if (_saving || !await confirmFormDraftExit() || !mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    _ownerIsCurrent = captureReadOwner(ref);
    listenReadOwner(ref, () {
      invalidateFormDraftIdentity();
      _ownerChanges.value++;
    });
    final e = widget.editing;
    _prefixCtl = TextEditingController(text: e?.codePrefix ?? '');
    _nameCtl = TextEditingController(text: e?.name ?? '');
    _remarkCtl = TextEditingController(text: e?.remark ?? e?.code ?? '');
    _sortCtl = TextEditingController(text: '${e?.sortOrder ?? 0}');
    // 编辑态：用详情里的 parentId 在树里反查父节点；新建态：用传入的默认父级。
    if (e != null) {
      if (e.parentId != null) {
        _parent = _findById(widget.tree, e.parentId!);
      }
    } else {
      _parent = widget.initialParent;
    }
    _nameCtl.addListener(_nameChanged);
    _prefixCtl.addListener(_onPrefixChanged);
    _onPrefixChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    _ownerChanges.value++;
    _ownerChanges.dispose();
    _prefixDebounce?.cancel();
    _prefixRevision++;
    _prefixCtl.removeListener(_onPrefixChanged);
    _prefixCtl.dispose();
    _nameCtl.removeListener(_nameChanged);
    _nameCtl.dispose();
    _remarkCtl.dispose();
    _sortCtl.dispose();
    super.dispose();
  }

  /// 新节点将落在的层级（根=0，子=父+1）。
  int get _resultLevel => (_parent?.level ?? -1) + 1;

  ProductCategoryNode? _findById(List<ProductCategoryNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  /// node 是否为 selfId 自身或其后代。
  bool _isSelfOrDescendant(ProductCategoryNode node, String selfId) {
    if (node.id == selfId) return true;
    for (final c in node.children) {
      if (_isSelfOrDescendant(c, selfId)) return true;
    }
    return false;
  }

  String? _validate() {
    final prefixError = _prefixFormatError(_normalizedPrefix) ?? _prefixError;
    if (prefixError != null) return prefixError;
    if (int.tryParse(_sortCtl.text.trim()) == null) {
      return '显示顺序必须填整数';
    }
    if (_nameCtl.text.trim().isEmpty) {
      return '请输入分类名称'; // TODO(l10n): 补 arb
    }
    if (_nameError != null) return _nameError;
    // 编辑态：新父级不能是自身或自身的后代（否则成环）。
    // 注意：要在「自身的子树」里找新父级 id —— 旧代码写成在父级子树里找自身，
    // 而自身本就是父级的子节点 → 恒为 true，导致只改名字也误报。仅改名字时父级未变，
    // 父级不在自身子树内 → 不报错。
    final selfId = widget.editing?.id;
    if (_isEdit && selfId != null && _parent != null) {
      final selfNode = _findById(widget.tree, selfId);
      if (selfNode != null && _isSelfOrDescendant(selfNode, _parent!.id)) {
        return '不能将分类移动到自身或其子分类下'; // TODO(l10n): 补 arb
      }
    }
    return null;
  }

  Future<bool> _confirmPrefixImpact(String requestedPrefix) async {
    final callback = widget.onPreviewPrefixChange;
    final editing = widget.editing;
    if (callback == null || editing == null) return true;
    // 只有编号前缀本身变化才预览并二次确认批量改号；仅调整上级分类不再
    // 触发改号（2026-10-30 用户口径：归拢系列时已有主档编号保持不变）。
    if (requestedPrefix == (editing.codePrefix ?? '').toUpperCase()) {
      return true;
    }

    late final CategoryPrefixPreview preview;
    try {
      preview = await callback(requestedPrefix, _parent?.id);
    } catch (e) {
      if (mounted) context.appApiError(e, fallback: '改号影响预览失败，请重试');
      return false;
    }
    if (!mounted) return false;
    if (preview.conflicts > 0) {
      final samples = preview.conflictSamples.isEmpty
          ? ''
          : '：${preview.conflictSamples.join('、')}';
      context.appError('有 ${preview.conflicts} 个编号重复$samples，请先调整前缀');
      return false;
    }
    if (preview.affectedRecords == 0) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const UtenDialogHeading(
          title: Text('确认批量改号'),
          icon: Icons.drive_file_rename_outline,
        ),
        content: Text(
          '${preview.affectedRecords} 条主档编号将按「${preview.resultingEffectivePrefix} + 序号」从 01 重排。'
          '${preview.customOrLegacyRecords > 0 ? '\n包含 ${preview.customOrLegacyRecords} 条手工或历史编号。' : ''}'
          '${preview.descendantOverrides > 0 ? '\n${preview.descendantOverrides} 个下级分类保留自己的前缀。' : ''}\n\n'
          '订单关联和已审核单据的历史编号保持不变。',
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回检查'),
          ),
          UtenButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认改号'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _submit() async {
    if (_saving || (!_serverCreated && _prefixChecking)) return;
    if (!_ownerIsCurrent()) return;
    final current = _ownerIsCurrent;
    if (_serverCreated) {
      setState(() => _saving = true);
      try {
        await completeFormDraft();
        if (mounted && current()) Navigator.of(context).pop();
      } catch (e) {
        if (mounted && current()) context.appApiError(e);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    final err = _validate();
    if (err != null) {
      setState(() => _formError = err);
      return;
    }
    // 兜底：onSubmit 内部通常已自带成功/失败通知；此处只兜未捕获异常，防止静默失败。
    late final bool ok;
    setState(() {
      _formError = null;
      _saving = true;
    });
    try {
      final prefix = _normalizedPrefix;
      if (_canCheckPrefix && prefix.isNotEmpty) {
        // 提交前重新读取占用，覆盖输入检查后被另一用户抢占的情况。
        _prefixDebounce?.cancel();
        final revision = ++_prefixRevision;
        setState(() => _prefixChecking = true);
        if (!await _checkPrefix(prefix, revision)) return;
      }
      if (!await _confirmPrefixImpact(prefix) || !mounted || !current()) return;
      final result = CategoryEditResult(
        name: _nameCtl.text.trim(),
        codePrefix: prefix,
        remark: _remarkCtl.text.trim(),
        version: widget.editing?.version,
        sortOrder: int.parse(_sortCtl.text.trim()),
        moveToRoot:
            _isEdit && widget.editing?.parentId != null && _parent == null,
        parentId: _isEdit && _parent?.id == widget.editing?.parentId
            ? null
            : _parent?.id,
      );
      setState(() => _submissionWaiting = true);
      ok = await runUtenBlockingTask<bool>(
        context: context,
        title: _isEdit ? '正在保存分类' : '正在创建分类',
        isCurrent: current,
        invalidation: _ownerChanges,
        task: () async {
          await saveFormDraftNow();
          final accepted = await runFormDraftSubmission(
            () => current() ? widget.onSubmit(result) : Future.value(false),
          );
          if (accepted && mounted && current()) {
            setState(() => _serverCreated = true);
            await saveFormDraftNow();
            await completeFormDraft();
          }
          return accepted;
        },
      );
      if (!mounted || !current()) return;
      if (!ok) _queuePrefixCheck(immediately: true);
    } catch (e) {
      if (!mounted || !current()) return;
      _queuePrefixCheck(immediately: true);
      context.appApiError(e);
      return;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _submissionWaiting = false;
        });
      }
    }
    if (!mounted || !current()) return;
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _pickParent() async {
    final selfId = widget.editing?.id;
    // 自身节点（编辑态）：在自身子树内判定候选父级，禁用自身及其后代（否则成环）。
    final selfNode = selfId == null ? null : _findById(widget.tree, selfId);
    final result = await showUtenPickerSheet<ProductCategoryNode>(
      context: context,
      title: _isEdit ? '选择上级分类' : '选择添加位置', // TODO(l10n): 补 arb
      rootLabel: '顶级分类', // TODO(l10n): 补 arb
      showRootOption: !_isEdit || widget.canMove,
      initialSelection: (node: _parent, isRoot: _parent == null),
      childBuilder: (ctx, pendingSelection, onSelect, onSelectRoot) =>
          UtenCategoryTreeView(
            mode: UtenCategoryTreeMode.single,
            nodes: widget.tree,
            selectedIds: {pendingSelection?.node?.id ?? ''},
            nodeEnabledPredicate: (n) {
              // 系统根（未分类/虚拟总根）不可作上级：它们是收容/视图节点，
              // 不是业务层级；编辑态另禁自身及其后代（防成环）。
              if (n.systemManaged) return false;
              if (selfNode == null) return true;
              return !_isSelfOrDescendant(selfNode, n.id);
            },
            onToggleSelect: onSelect,
          ),
    );
    if (!mounted || result == null) return;
    setState(() => _parent = result.isRoot ? null : result.node);
  }

  @override
  Widget build(BuildContext context) => withFormDraft(_buildDialog(context));

  Widget _buildDialog(BuildContext context) {
    final theme = Theme.of(context);
    return UtenAlertDialog(
      scrollable: false,
      title: UtenDialogHeading(
        title: Text(_isEdit ? '编辑分类' : '新增分类'),
        icon: _isEdit
            ? Icons.drive_file_rename_outline
            : Icons.create_new_folder_outlined,
      ),
      // 显式三档宽度（compact 近全屏 / medium 收窄 / expanded 560）：
      // 前缀 helper 文案较长，Material 默认窄弹窗换行严重。
      insetPadding: utenDialogInsetPadding(context),
      content: SizedBox(
        width: utenDialogWidth(context, 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenLocationField(
                pathLabel: _parent?.name,
                rootLabel: '顶级分类', // TODO(l10n): 补 arb
                resultLevelLabel: 'L$_resultLevel',
                headingLabel: _isEdit ? '上级分类' : '添加位置',
                enabled:
                    !_saving && !_serverCreated && (!_isEdit || widget.canMove),
                onTap: _pickParent,
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _sortCtl,
                readOnly:
                    _saving ||
                    _serverCreated ||
                    (_isEdit && !widget.canReorder),
                keyboardType: TextInputType.number,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel('显示顺序', theme, info: '数字越小越靠前'),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _prefixCtl,
                readOnly:
                    _saving ||
                    _serverCreated ||
                    (_isEdit && !widget.canEditFields),
                textCapitalization: TextCapitalization.characters,
                maxLength: 8,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '编号前缀',
                      theme,
                      info:
                          '留空时沿用最近上级的前缀；前缀全系统唯一，'
                          '不区分大小写，一经使用会一直占用。'
                          '设置前缀后，该分类下新建的主档编号自动按「前缀+序号」'
                          '发号（如前缀 2080358 → 208035801、208035802…），'
                          '自动跳过已占用的号，超过 99 自然进位到三位。'
                          '仅调整上级分类不会改动已有编号。'
                          '修改前缀并确认后，该分类下全部编号会按新前缀从头重排。'
                          '输入时自动检查，被占用时请更换前缀后再保存。',
                    ),
                    hintText: '例如 2080358',
                    counterText: '',
                    error: utenFieldError(_prefixError),
                    errorStyle: TextStyle(color: theme.colorScheme.error),
                    enabledBorder: _prefixError == null
                        ? null
                        : OutlineInputBorder(
                            borderSide: BorderSide(
                              color: theme.colorScheme.error,
                            ),
                          ),
                    focusedBorder: _prefixError == null
                        ? null
                        : OutlineInputBorder(
                            borderSide: BorderSide(
                              color: theme.colorScheme.error,
                              width: 2,
                            ),
                          ),
                    suffixIcon: _prefixCheckFailed
                        ? IconButton(
                            tooltip: '重新检查编号前缀',
                            onPressed: _saving
                                ? null
                                : () => _queuePrefixCheck(immediately: true),
                            icon: const Icon(Icons.refresh),
                          )
                        : null,
                  ),
                ),
              ),
              if (_prefixError != null || _prefixChecking) ...[
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _prefixError ?? '正在检查编号前缀…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _prefixError == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                      fontWeight: _prefixError == null ? null : FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _nameCtl,
                readOnly:
                    _saving ||
                    _serverCreated ||
                    (_isEdit && !widget.canEditFields),
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '名称',
                    error: utenFieldError(_nameError),
                    errorStyle: TextStyle(color: theme.colorScheme.error),
                    errorBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: theme.colorScheme.error),
                    ),
                    focusedErrorBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: theme.colorScheme.error,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              if (_nameError != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  _nameError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _remarkCtl,
                readOnly:
                    _saving ||
                    _serverCreated ||
                    (_isEdit && !widget.canEditFields),
                minLines: 2,
                maxLines: 3,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '备注',
                      theme,
                      info: '旧分类编码已迁移到这里，可按业务需要修改',
                    ),
                  ),
                ),
              ),
              if (_formError != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _formError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _saving ? null : _close,
          child: const Text('取消'), // TODO(l10n): 补 arb
        ),
        UtenButton(
          isLoading: _saving && !_submissionWaiting,
          onPressed:
              _saving ||
                  (!_serverCreated &&
                      (_prefixChecking ||
                          _prefixError != null ||
                          _nameError != null))
              ? null
              : _submit,
          child: Text(_isEdit ? '保存' : '创建'), // TODO(l10n): 补 arb
        ),
      ],
    );
  }
}
