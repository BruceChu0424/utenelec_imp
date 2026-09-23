// 总账附表/经营损益表「报表行 → 科目/部门」取数设置(ADR-112 / overhaul-gap-03)。
//
// GET  /finance/reports/gl/line-bindings            各可配置行当前绑定的科目/部门
// PUT  /finance/reports/gl/line-bindings/{lineKey}  整行替换(人工行选部门, 其余选费用类末级科目)
// POST /finance/reports/gl/line-bindings/defaults   按原科目名单为还没有绑定的行补默认绑定
//
// 没有绑定的行在报表上标注「未配置科目 / 未配置部门」且不计入合计。同一张表里一个科目只能归一行、
// 直接人工与间接人工的部门不能重叠——这些由服务端校验, 这里把原因原样告诉用户。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';

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
  });

  factory GlReportLineBinding.fromJson(Map<String, dynamic> json) =>
      GlReportLineBinding(
        lineKey: json['lineKey']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        bindingKind: json['bindingKind']?.toString() ?? 'STYLE',
        targets: [
          for (final item in (json['targets'] as List<dynamic>? ?? const []))
            if (item is Map<String, dynamic>) GlReportLineTarget.fromJson(item),
        ],
      );

  final String lineKey;
  final String label;
  final String bindingKind;
  final List<GlReportLineTarget> targets;

  bool get department => bindingKind == 'DEPARTMENT';
  String get notConfigured => department ? '未配置部门' : '未配置科目';
}

/// 候选目标(拍平后的科目或部门, depth 仅用于缩进显示)。
class GlReportLineCandidate {
  const GlReportLineCandidate({
    required this.id,
    required this.label,
    required this.depth,
    this.disabled = false,
  });

  final String id;
  final String label;
  final int depth;
  final bool disabled;
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

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await _api.getList(GlReportLineBindingEndpoints.list);
      if (!mounted) return;
      setState(() => _lines = rows.map(GlReportLineBinding.fromJson).toList());
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '取数设置加载失败，请检查网络后重试');
    }
  }

  Future<void> _seedDefaults() async {
    setState(() => _busy = true);
    try {
      // 带空 body: Web 端无 body 的 POST 受 15 秒连接上限影响。
      final rows = await _api.postList(
        GlReportLineBindingEndpoints.defaults,
        body: const <String, dynamic>{},
      );
      if (!mounted) return;
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
    setState(() => _busy = true);
    List<GlReportLineCandidate> candidates;
    try {
      candidates = line.department
          ? flattenDepartments(
              await _api.getList(GlReportLineBindingEndpoints.departments),
            )
          : flattenExpenseLeaves(
              await _api.getList(
                GlReportLineBindingEndpoints.expenseStyles,
                query: const {'category': 'EXPENSE'},
              ),
            );
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
    if (!mounted) return;
    setState(() => _busy = false);
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _TargetPickerDialog(
        title: '「${line.label}」取数${line.department ? '部门' : '科目'}',
        hint: line.department
            ? '所选部门(含下级)已审核工资单的应发计入本行'
            : '只列出费用类末级科目; 同一张表里一个科目只能归一行',
        candidates: candidates,
        initial: {for (final target in line.targets) target.id},
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final saved = GlReportLineBinding.fromJson(
        await _api.put(
          GlReportLineBindingEndpoints.line(line.lineKey),
          body: {'targetIds': picked.toList()},
        ),
      );
      if (!mounted) return;
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
    final theme = Theme.of(context);
    final lines = _lines;
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: SizedBox(
        width: 720,
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('附表取数设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '总账附表与经营损益表的每一行取哪些科目或部门的数。没有设置的行在报表上标注「未配置」，不计入合计。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final line = lines[index];
                          final configured = line.targets.isNotEmpty;
                          return ListTile(
                            key: ValueKey('gl-line-${line.lineKey}'),
                            dense: true,
                            title: Text(line.label),
                            subtitle: Text(
                              configured
                                  ? line.targets
                                        .map((target) => target.display)
                                        .join('、')
                                  : line.notConfigured,
                              style: configured
                                  ? null
                                  : TextStyle(color: theme.colorScheme.error),
                            ),
                            trailing: widget.canEdit
                                ? TextButton(
                                    key: ValueKey(
                                      'gl-line-edit-${line.lineKey}',
                                    ),
                                    onPressed: _busy ? null : () => _edit(line),
                                    child: const Text('修改'),
                                  )
                                : null,
                          );
                        },
                      ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.canEdit) ...[
                    OutlinedButton(
                      key: const ValueKey('gl-line-seed-defaults'),
                      onPressed: _busy || lines == null ? null : _seedDefaults,
                      child: const Text('按默认名单补齐'),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                  ],
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _changed),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 费用类科目树 → 末级科目(停用的也列出, 标注后可绑来统计历史发生额)。
List<GlReportLineCandidate> flattenExpenseLeaves(
  List<Map<String, dynamic>> roots,
) {
  final result = <GlReportLineCandidate>[];
  void walk(List<dynamic> nodes, List<String> parents) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final children = node['children'] as List<dynamic>? ?? const [];
      final name = node['name']?.toString() ?? '';
      if (children.isEmpty) {
        if ((node['category']?.toString() ?? 'EXPENSE') != 'EXPENSE') continue;
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
        ),
      );
      walk(node['children'] as List<dynamic>? ?? const [], depth + 1);
    }
  }

  walk(roots, 0);
  return result;
}

class _TargetPickerDialog extends StatefulWidget {
  const _TargetPickerDialog({
    required this.title,
    required this.hint,
    required this.candidates,
    required this.initial,
  });

  final String title;
  final String hint;
  final List<GlReportLineCandidate> candidates;
  final Set<String> initial;

  @override
  State<_TargetPickerDialog> createState() => _TargetPickerDialogState();
}

class _TargetPickerDialogState extends State<_TargetPickerDialog> {
  late final Set<String> _selected = {...widget.initial};
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyword = _keyword.trim().toLowerCase();
    final visible = keyword.isEmpty
        ? widget.candidates
        : widget.candidates
              .where((item) => item.label.toLowerCase().contains(keyword))
              .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              key: const ValueKey('gl-line-target-search'),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索名称或编码',
                isDense: true,
              ),
              onChanged: (value) => setState(() => _keyword = value),
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
          onPressed: () => Navigator.pop(context, _selected),
          child: Text('保存 (${_selected.length})'),
        ),
      ],
    );
  }
}
