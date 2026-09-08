// UtenEmployeeMultiPicker - 多选人员右滑窗 / 手机底部抽屉。
//
// 与 UtenEmployeePicker 共用候选模型与 loader：
// - compact：85% 高底部抽屉；
// - medium/expanded：420dp 右侧滑入面板；
// - 搜索只允许最新请求回写，避免弱网下旧结果覆盖新关键词；
// - 多选结果在点「确定」时一次提交，已选人员可在字段下方单独移除。
import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_empty.dart';
import '../feedback/uten_skeleton.dart';
import '../layout/uten_bottom_action_bar.dart';
import 'required_field_decoration.dart';
import 'uten_employee_picker.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import 'uten_search_bar.dart';

class UtenEmployeeMultiPicker extends StatefulWidget {
  const UtenEmployeeMultiPicker({
    super.key,
    required this.loader,
    required this.onChanged,
    this.initialSelection = const [],
    this.enabled = true,
    this.label,
    this.hint = '请选择人员',
    this.sheetTitle = '选择人员',
    this.searchHint = '搜索姓名 / 工号',
    this.emptyMessage = '未找到匹配的人员',
    this.selectedCountLabel,
    this.clearLabel = '清空',
    this.confirmLabel = '确定',
    this.validator,
    this.required = false,
  });

  final UtenEmployeePickerLoader loader;
  final ValueChanged<List<UtenEmployeePickerItem>> onChanged;
  final List<UtenEmployeePickerItem> initialSelection;
  final bool enabled;
  final String? label;
  final String hint;
  final String sheetTitle;
  final String searchHint;
  final String emptyMessage;
  final String Function(int count)? selectedCountLabel;
  final String clearLabel;
  final String confirmLabel;
  final String? Function(List<UtenEmployeePickerItem> selection)? validator;

  /// 是否必填：标签后显红 *；未选且启用时输入框描红边。
  final bool required;

  @override
  State<UtenEmployeeMultiPicker> createState() =>
      _UtenEmployeeMultiPickerState();
}

class _UtenEmployeeMultiPickerState extends State<UtenEmployeeMultiPicker> {
  final _fieldKey = GlobalKey<FormFieldState<List<UtenEmployeePickerItem>>>();
  List<UtenEmployeePickerItem> _selection = const [];

  @override
  void initState() {
    super.initState();
    _selection = List.of(widget.initialSelection);
  }

  @override
  void didUpdateWidget(UtenEmployeeMultiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSelection != oldWidget.initialSelection) {
      _selection = List.of(widget.initialSelection);
      _fieldKey.currentState?.didChange(_selection);
    }
  }

  Future<void> _open() async {
    final sheet = _EmployeeMultiPickerSheet(
      loader: widget.loader,
      initialSelection: _selection,
      title: widget.sheetTitle,
      searchHint: widget.searchHint,
      emptyMessage: widget.emptyMessage,
      selectedCountLabel: widget.selectedCountLabel,
      clearLabel: widget.clearLabel,
      confirmLabel: widget.confirmLabel,
    );
    final List<UtenEmployeePickerItem>? result;
    if (context.breakpoint.isCompact) {
      result = await showModalBottomSheet<List<UtenEmployeePickerItem>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.85,
            child: sheet,
          ),
        ),
      );
    } else {
      result = await showGeneralDialog<List<UtenEmployeePickerItem>>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (dialogContext, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(dialogContext).colorScheme.surface,
            child: SafeArea(
              left: false,
              child: SizedBox(
                width: 420,
                height: double.infinity,
                child: sheet,
              ),
            ),
          ),
        ),
        transitionBuilder: (dialogContext, animation, _, child) =>
            SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            ),
      );
    }
    if (result == null || !mounted) return;
    setState(() => _selection = result!);
    _fieldKey.currentState?.didChange(_selection);
    widget.onChanged(_selection);
  }

  void _remove(UtenEmployeePickerItem item) {
    setState(() {
      _selection = _selection.where((entry) => entry.id != item.id).toList();
    });
    _fieldKey.currentState?.didChange(_selection);
    widget.onChanged(_selection);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = _selection.isEmpty
        ? null
        : widget.selectedCountLabel?.call(_selection.length) ??
              '已选 ${_selection.length} 人';
    final requiredEmpty =
        widget.enabled && widget.required && _selection.isEmpty;
    return FormField<List<UtenEmployeePickerItem>>(
      key: _fieldKey,
      initialValue: _selection,
      validator: widget.validator == null
          ? null
          : (_) => widget.validator!(_selection),
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            enabled: widget.enabled,
            label: widget.label ?? widget.hint,
            value: display,
            child: InkWell(
              onTap: widget.enabled ? _open : null,
              borderRadius: UtenRadius.mdAll,
              child: InputDecorator(
                isEmpty: display == null,
                decoration: applyRequiredEmpty(
                  UtenInputDecoration(
                    InputDecoration(
                      label: widget.label == null
                          ? null
                          : requiredLabel(
                              widget.label!,
                              theme,
                              required: widget.required,
                              base: theme.inputDecorationTheme.labelStyle,
                            ),
                      hintText: widget.hint,
                      enabled: widget.enabled,
                      error: field.errorText == null
                          ? null
                          : UtenFieldMessage.error(field.errorText!),
                      prefixIcon: const Icon(Icons.group_add_outlined),
                      suffixIcon: Icon(
                        Icons.unfold_more_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s16,
                        vertical: UtenSpacing.s16,
                      ),
                    ),
                  ),
                  theme,
                  requiredEmpty: requiredEmpty,
                ),
                child: display == null ? null : Text(display),
              ),
            ),
          ),
          if (_selection.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final item in _selection)
                    InputChip(
                      avatar: const Icon(
                        Icons.person_outline_rounded,
                        size: 18,
                      ),
                      label: Text(item.displayName),
                      tooltip: item.departmentName,
                      onDeleted: widget.enabled ? () => _remove(item) : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EmployeeMultiPickerSheet extends StatefulWidget {
  const _EmployeeMultiPickerSheet({
    required this.loader,
    required this.initialSelection,
    required this.title,
    required this.searchHint,
    required this.emptyMessage,
    required this.selectedCountLabel,
    required this.clearLabel,
    required this.confirmLabel,
  });

  final UtenEmployeePickerLoader loader;
  final List<UtenEmployeePickerItem> initialSelection;
  final String title;
  final String searchHint;
  final String emptyMessage;
  final String Function(int count)? selectedCountLabel;
  final String clearLabel;
  final String confirmLabel;

  @override
  State<_EmployeeMultiPickerSheet> createState() =>
      _EmployeeMultiPickerSheetState();
}

class _EmployeeMultiPickerSheetState extends State<_EmployeeMultiPickerSheet> {
  late final Map<String, UtenEmployeePickerItem> _selected;
  List<UtenEmployeePickerItem> _items = const [];
  String _keyword = '';
  bool _loading = true;
  Object? _error;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    _selected = {for (final item in widget.initialSelection) item.id: item};
    _load();
  }

  Future<void> _load() async {
    final request = ++_requestSerial;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keyword = _keyword.trim();
      final items = await widget.loader(keyword.isEmpty ? null : keyword);
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _toggle(UtenEmployeePickerItem item) {
    setState(() {
      if (_selected.containsKey(item.id)) {
        _selected.remove(item.id);
      } else {
        _selected[item.id] = item;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      widget.selectedCountLabel?.call(_selected.length) ??
                          '已选 ${_selected.length} 人',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            0,
            UtenSpacing.s16,
            UtenSpacing.s8,
          ),
          child: UtenSearchBar(
            hint: widget.searchHint,
            onInputChanged: (value) {
              _keyword = value;
              _requestSerial++;
              setState(() {
                _loading = true;
                _error = null;
              });
            },
            onChanged: (value) {
              _keyword = value;
              _load();
            },
          ),
        ),
        Expanded(
          child: _loading
              ? const UtenSkeletonList()
              : _error != null
              ? UtenEmpty.error(message: '$_error', onAction: _load)
              : _items.isEmpty
              ? UtenEmpty(
                  icon: Icons.person_off_outlined,
                  message: widget.emptyMessage,
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    indent: UtenSpacing.s16,
                    endIndent: UtenSpacing.s16,
                  ),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final selected = _selected.containsKey(item.id);
                    return Semantics(
                      selected: selected,
                      child: CheckboxListTile(
                        value: selected,
                        onChanged: (_) => _toggle(item),
                        secondary: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                          child: Text(
                            item.name.isEmpty
                                ? '?'
                                : item.name.characters.first,
                          ),
                        ),
                        title: Text(item.displayName),
                        subtitle: Text(
                          [
                            if (item.departmentName?.isNotEmpty == true)
                              item.departmentName!,
                          ].join(' · '),
                        ),
                        controlAffinity: ListTileControlAffinity.trailing,
                      ),
                    );
                  },
                ),
        ),
        UtenBottomActionBar(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.selectedCountLabel?.call(_selected.length) ??
                      '已选 ${_selected.length} 人',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: Text(widget.clearLabel),
              ),
              const SizedBox(width: UtenSpacing.s8),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(_selected.values.toList()),
                child: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
