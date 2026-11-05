import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../shared/search/keyword_search.dart';
// 总账附表/经营损益表「报表行 → 科目/部门」取数设置(ADR-112 / overhaul-gap-03)。
//
// GET  /finance/reports/gl/line-bindings            各可配置行当前绑定的科目/部门
// PUT  /finance/reports/gl/line-bindings/{lineKey}  整行替换(人工行选部门, 其余选费用类末级科目)
// POST /finance/reports/gl/line-bindings/defaults   按原科目名单为还没有绑定的行补默认绑定
//
// 没有绑定的行在报表上标注「未配置科目 / 未配置部门」且不计入合计。同一张表里一个科目只能归一行、
// 直接人工与间接人工的部门不能重叠——这些由服务端校验, 这里把原因原样告诉用户。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

/// 报表行绑定的一个目标(科目或部门)。
class GlReportLineTarget {
  const GlReportLineTarget({
    required this.id,
    required this.code,
    required this.name,
  });

  factory GlReportLineTarget.fromJson(Map<String, dynamic> json) =>
      GlReportLineTarget(
        id: json['id']?.toString() ?? '',
        code: json['code']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );

  final String id;
  final String code;
  final String name;

  String get display => code.isEmpty ? name : '$name ($code)';
}

/// 一条可配置的报表行。
class GlReportLineBinding {
  const GlReportLineBinding({
    required this.lineKey,
    required this.label,
    required this.bindingKind,
    required this.targets,
    this.category = 'EXPENSE',
    this.sheet,
    this.confirmedZero = false,
    this.defaultBasis,
    this.allowedCategories = const [],
    this.requiredFinanceCodePrefix,
  });

  factory GlReportLineBinding.fromJson(Map<String, dynamic> json) =>
      GlReportLineBinding(
        lineKey: json['lineKey']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        bindingKind: json['bindingKind']?.toString() ?? 'STYLE',
        category: json['category']?.toString() ?? 'EXPENSE',
        sheet: json['sheet']?.toString(),
        confirmedZero: json['confirmedZero'] == true,
        defaultBasis: json['defaultBasis']?.toString(),
        allowedCategories: [
          for (final item
              in json['allowedCategories'] as List<dynamic>? ?? const [])
            item.toString(),
        ],
        requiredFinanceCodePrefix: json['requiredFinanceCodePrefix']
            ?.toString(),
        targets: [
          for (final item in (json['targets'] as List<dynamic>? ?? const []))
            if (item is Map<String, dynamic>) GlReportLineTarget.fromJson(item),
        ],
      );

  final String lineKey;
  final String label;
  final String bindingKind;
  final List<GlReportLineTarget> targets;
  final String category;
  final String? sheet;
  final bool confirmedZero;
  final String? defaultBasis;
  final List<String> allowedCategories;
  final String? requiredFinanceCodePrefix;

  bool get department => bindingKind == 'DEPARTMENT';
  List<String> get effectiveCategories =>
      allowedCategories.isEmpty ? [category] : allowedCategories;
  String get notConfigured => confirmedZero
      ? '财务已确认本行单独取数为零'
      : defaultBasis ?? (department ? '未配置部门' : '未配置科目');
}

/// 候选目标(拍平后的科目或部门, depth 仅用于缩进显示)。
class GlReportLineCandidate {
  const GlReportLineCandidate({
    required this.id,
    required this.label,
    required this.depth,
    this.disabled = false,
    this.name,
    this.code,
  });

  final String id;
  final String label;
  final int depth;
  final bool disabled;
  final String? name;
  final String? code;
}

abstract final class GlReportLineBindingEndpoints {
  static const list = '/finance/reports/gl/line-bindings';
  static const defaults = '/finance/reports/gl/line-bindings/defaults';
  static String line(String key) => '/finance/reports/gl/line-bindings/$key';
  static const expenseStyles = '/master/payment-styles/tree';
  static const departments = '/org/departments/tree';
}

/// 打开取数设置。返回 true 表示有改动, 调用方应重新查询报表。
Future<bool> showGlReportLineBindingsDialog(
  BuildContext context, {
  required bool canEdit,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => GlReportLineBindingsDialog(canEdit: canEdit),
  );
  return changed ?? false;
}

class GlReportLineBindingsDialog extends ConsumerStatefulWidget {
  const GlReportLineBindingsDialog({required this.canEdit, super.key});

  final bool canEdit;

  @override
  ConsumerState<GlReportLineBindingsDialog> createState() =>
      _GlReportLineBindingsDialogState();
}

class _GlReportLineBindingsDialogState
    extends ConsumerState<GlReportLineBindingsDialog> {
  List<GlReportLineBinding>? _lines;
  String? _error;
  bool _busy = false;
  bool _changed = false;

  late final ApiClient _api;
  late final int _ownerEpoch;
  bool get _current =>
      mounted &&
      _ownerEpoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _ownerEpoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await _api.getList(GlReportLineBindingEndpoints.list);
      if (!mounted || !_current) return;
      setState(() => _lines = rows.map(GlReportLineBinding.fromJson).toList());
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '取数设置加载失败，请检查网络后重试');
    }
  }

  Future<void> _seedDefaults() async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      // 带空 body: Web 端无 body 的 POST 受 15 秒连接上限影响。
      final rows = await _api.postList(
        GlReportLineBindingEndpoints.defaults,
        body: const <String, dynamic>{},
      );
      if (!mounted || !_current) return;
      setState(() {
        _lines = rows.map(GlReportLineBinding.fromJson).toList();
        _changed = true;
      });
      context.appSuccess('已按默认科目名单补齐还没有设置的行');
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('补齐失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(GlReportLineBinding line) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    List<GlReportLineCandidate> candidates;
    try {
      candidates = await loadGlReportLineCandidates(_api, line);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        context.appError(error.message);
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        context.appError('候选科目或部门加载失败，请稍后重试');
      }
      return;
    }
    if (!mounted || !_current) return;
    setState(() => _busy = false);
    final picked = await showDialog<_BindingSelection>(
      context: context,
      builder: (_) => _TargetPickerDialog(
        title: '「${line.label}」取数${line.department ? '部门' : '科目'}',
        hint: line.department
            ? '所选部门(含下级)已审核工资单的应发计入本行'
            : '选择本项目对应的末级科目；同一张报表不重复归集。红字涉及的业务分类待财务确认。',
        candidates: candidates,
        initial: {for (final target in line.targets) target.id},
        canConfirmZero: line.sheet != null,
        confirmedZero: line.confirmedZero,
        ownerEpoch: _ownerEpoch,
      ),
    );
    if (picked == null || !mounted || !_current) return;
    setState(() => _busy = true);
    try {
      final saved = GlReportLineBinding.fromJson(
        await _api.put(
          GlReportLineBindingEndpoints.line(line.lineKey),
          body: {
            'targetIds': picked.ids.toList(),
            if (line.sheet != null) 'confirmedZero': picked.zero,
          },
        ),
      );
      if (!_current) return;
      setState(() {
        _lines = [
          for (final item in _lines ?? const <GlReportLineBinding>[])
            item.lineKey == saved.lineKey ? saved : item,
        ];
        _changed = true;
      });
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _ownerEpoch) {
      return UtenAlertDialog(
        title: const Text('访问范围已变化'),
        showCloseButton: true,
        closeButtonKey: const ValueKey('gl-line-retired-close'),
        onClose: () => Navigator.pop(context, false),
      );
    }
    final theme = Theme.of(context);
    final lines = _lines;
    return UtenDialogFrame(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: SizedBox(
        width: 720,
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenDialogHeader(
                    padding: EdgeInsets.zero,
                    icon: Icons.account_tree_outlined,
                    title: const Text('附表取数设置'),
                    showCloseButton: true,
                    onClose: () => Navigator.pop(context, _changed),
                    trailing: const UtenFieldHintIcon(
                      info:
                          '按报表项目配置取数科目或部门。财务报表缺少配置时保留空值，并提示合计不完整；无业务项目需由财务明确确认。',
                      dense: true,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Expanded(
                    child: _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          )
                        : lines == null
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : ListView.separated(
                            itemCount: lines.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (_, index) {
                              final line = lines[index];
                              final configured =
                                  line.targets.isNotEmpty || line.confirmedZero;
                              return ListTile(
                                key: ValueKey('gl-line-${line.lineKey}'),
                                dense: true,
                                title: Text(line.label),
                                subtitle: Text(
                                  line.targets.isNotEmpty
                                      ? line.targets
                                            .map((target) => target.display)
                                            .join('、')
                                      : line.notConfigured,
                                  style: configured
                                      ? null
                                      : TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                ),
                                trailing: widget.canEdit
                                    ? TextButton(
                                        key: ValueKey(
                                          'gl-line-edit-${line.lineKey}',
                                        ),
                                        onPressed: _busy
                                            ? null
                                            : () => _edit(line),
                                        child: const Text('修改'),
                                      )
                                    : null,
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenDialogActions(
                    padding: const EdgeInsets.only(top: UtenSpacing.s16),
                    children: [
                      if (widget.canEdit) ...[
                        OutlinedButton(
                          key: const ValueKey('gl-line-seed-defaults'),
                          onPressed: _busy || lines == null
                              ? null
                              : _seedDefaults,
                          child: const Text('按默认名单补齐'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 补齐/保存网络段的全屏居中遮罩（2026-09-25 统一口径：不再只有
            // 按钮置灰无反馈）。
            if (_busy)
              const Positioned.fill(
                child: UtenBusyOverlay(title: '正在处理取数设置，请稍候'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Same candidate contract for report settings and cost-expense selectors.
Future<List<GlReportLineCandidate>> loadGlReportLineCandidates(
  ApiClient api,
  GlReportLineBinding line,
) async {
  if (line.department) {
    return flattenDepartments(
      await api.getList(GlReportLineBindingEndpoints.departments),
    );
  }
  final categories = line.effectiveCategories;
  final trees = await Future.wait([
    for (final category in categories)
      api.getList(
        GlReportLineBindingEndpoints.expenseStyles,
        query: {'category': category},
      ),
  ]);
  Set<String>? costIds;
  if (line.requiredFinanceCodePrefix != null &&
      categories.contains('ACCOUNT')) {
    final chart = await api.get('/finance/chart');
    costIds = {
      for (final row in chart['items'] as List<dynamic>? ?? const [])
        if (row is Map<String, dynamic> &&
            row['code'].toString().startsWith(line.requiredFinanceCodePrefix!))
          for (final target in row['targets'] as List<dynamic>? ?? const [])
            if (target is Map<String, dynamic>) target['id'].toString(),
    };
  }
  return [
    for (var i = 0; i < categories.length; i++)
      for (final candidate in flattenExpenseLeaves(
        trees[i],
        category: categories[i],
      ))
        if ((categories[i] != 'ACCOUNT' &&
                line.lineKey != 'MFG_LABOR_CONTROL') ||
            costIds == null ||
            costIds.contains(candidate.id))
          candidate,
  ];
}

/// 费用类科目树 → 末级科目(停用的也列出, 标注后可绑来统计历史发生额)。
List<GlReportLineCandidate> flattenExpenseLeaves(
  List<Map<String, dynamic>> roots, {
  String category = 'EXPENSE',
}) {
  final result = <GlReportLineCandidate>[];
  void walk(List<dynamic> nodes, List<String> parents) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final children = node['children'] as List<dynamic>? ?? const [];
      final name = node['name']?.toString() ?? '';
      if (children.isEmpty) {
        if ((node['category']?.toString() ?? category) != category) continue;
        final code = node['code']?.toString() ?? '';
        final disabled = (node['status']?.toString() ?? '使用') != '使用';
        result.add(
          GlReportLineCandidate(
            id: node['id']?.toString() ?? '',
            label:
                [
                  ...parents,
                  code.isEmpty ? name : '$name ($code)',
                ].join(' / ') +
                (disabled ? ' (停用)' : ''),
            depth: 0,
            disabled: disabled,
            name: name,
            code: code,
          ),
        );
      } else {
        walk(children, [...parents, name]);
      }
    }
  }

  walk(roots, const []);
  return result;
}

/// 部门树 → 全部部门(按层级缩进)。
List<GlReportLineCandidate> flattenDepartments(
  List<Map<String, dynamic>> roots,
) {
  final result = <GlReportLineCandidate>[];
  void walk(List<dynamic> nodes, int depth) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final code = node['code']?.toString() ?? '';
      final name = node['name']?.toString() ?? '';
      result.add(
        GlReportLineCandidate(
          id: node['id']?.toString() ?? '',
          label: code.isEmpty ? name : '$name ($code)',
          depth: depth,
          name: name,
          code: code,
        ),
      );
      walk(node['children'] as List<dynamic>? ?? const [], depth + 1);
    }
  }

  walk(roots, 0);
  return result;
}

/// Shared UUID picker for both the original report settings and accounting-code mapping.
Future<Set<String>?> showGlReportTargetPicker(
  BuildContext context, {
  required String title,
  required List<GlReportLineCandidate> candidates,
  required Set<String> initial,
}) async {
  final ownerEpoch = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(exportContextEpochProvider);
  final result = await showDialog<_BindingSelection>(
    context: context,
    builder: (_) => _TargetPickerDialog(
      title: title,
      hint: '对应真实系统末级科目；同名项目请同时核对编号与所属分类',
      candidates: candidates,
      initial: initial,
      ownerEpoch: ownerEpoch,
    ),
  );
  return result?.ids;
}

class _BindingSelection {
  const _BindingSelection(this.ids, this.zero);
  final Set<String> ids;
  final bool zero;
}

class _TargetPickerDialog extends ConsumerStatefulWidget {
  const _TargetPickerDialog({
    required this.title,
    required this.hint,
    required this.candidates,
    required this.initial,
    this.canConfirmZero = false,
    this.confirmedZero = false,
    this.ownerEpoch,
  });

  final String title;
  final String hint;
  final List<GlReportLineCandidate> candidates;
  final Set<String> initial;
  final bool canConfirmZero;
  final bool confirmedZero;
  final int? ownerEpoch;

  @override
  ConsumerState<_TargetPickerDialog> createState() =>
      _TargetPickerDialogState();
}

class _TargetPickerDialogState extends ConsumerState<_TargetPickerDialog> {
  late final int _ownerEpoch =
      widget.ownerEpoch ?? ref.read(exportContextEpochProvider);
  late final Set<String> _selected = {...widget.initial};
  late bool _zero = widget.confirmedZero;
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _ownerEpoch) {
      return UtenAlertDialog(
        title: const Text('访问范围已变化'),
        showCloseButton: true,
        closeButtonKey: const ValueKey('gl-line-picker-retired-close'),
        onClose: () => Navigator.pop(context),
      );
    }
    final keyword = _keyword.trim().toLowerCase();
    final visible = keyword.isEmpty
        ? List<GlReportLineCandidate>.of(widget.candidates)
        : widget.candidates
              .where((item) => matchesKeywordSearch([item.label], keyword))
              .toList();
    if (keyword.isNotEmpty) {
      final order = {
        for (var index = 0; index < widget.candidates.length; index++)
          widget.candidates[index].id: index,
      };
      visible.sort((left, right) {
        final rankLeft = keywordSearchRankWithPrimary(
          [left.name ?? left.label],
          [left.label, left.code],
          keyword,
        )!;
        final rankRight = keywordSearchRankWithPrimary(
          [right.name ?? right.label],
          [right.label, right.code],
          keyword,
        )!;
        final rank = rankLeft.compareTo(rankRight);
        return rank != 0 ? rank : order[left.id]!.compareTo(order[right.id]!);
      });
    }
    return UtenAlertDialog(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(widget.title)),
          const SizedBox(width: UtenSpacing.s8),
          UtenFieldHintIcon(info: widget.hint),
        ],
      ),
      showCloseButton: true,
      closeButtonKey: const ValueKey('gl-line-target-close'),
      onClose: () => Navigator.pop(context),
      content: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.canConfirmZero)
              CheckboxListTile(
                key: const ValueKey('gl-line-confirm-zero'),
                title: const Row(
                  children: [
                    Expanded(child: Text('财务确认本行单独取数为零')),
                    SizedBox(width: UtenSpacing.s8),
                    UtenFieldHintIcon(info: '其中明细和未结转损益仍按实际计算；已有金额会提示冲突'),
                  ],
                ),
                value: _zero,
                onChanged: (value) => setState(() {
                  _zero = value ?? false;
                  if (_zero) _selected.clear();
                }),
              ),
            UtenSearchBar(
              key: const ValueKey('gl-line-target-search'),
              hint: '搜索名称或编码',
              // 纯本地过滤：输入即筛（onInputChanged 无防抖，组合期由组件挂起）。
              onInputChanged: (value) => setState(() => _keyword = value),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有可选的项目'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final item = visible[index];
                        return CheckboxListTile(
                          key: ValueKey('gl-line-target-${item.id}'),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.only(
                            left: UtenSpacing.s8 + item.depth * UtenSpacing.s16,
                          ),
                          value: _selected.contains(item.id),
                          title: Text(item.label),
                          onChanged: (checked) => setState(() {
                            if (checked ?? false) {
                              _zero = false;
                              _selected.add(item.id);
                            } else {
                              _selected.remove(item.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('gl-line-target-save'),
          onPressed: () => Navigator.pop(
            context,
            _BindingSelection(Set.of(_selected), _zero),
          ),
          child: Text('保存 (${_selected.length})'),
        ),
      ],
    );
  }
}
