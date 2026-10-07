// UtenEmployeeMultiPicker - 多选人员右滑窗 / 手机底部抽屉。
//
// 与 UtenEmployeePicker 共用候选模型与 loader：
// - compact：85% 高底部抽屉；
// - medium/expanded：与客户选择器同宽的部门树 + 人员列表；
// - 搜索只允许最新请求回写，避免弱网下旧结果覆盖新关键词；
// - 多选结果在点「确定」时一次提交，已选人员可在字段下方单独移除。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'required_field_decoration.dart';
import 'uten_employee_picker_models.dart';
import 'uten_employee_selection_panel.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

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
    this.searchHint = '搜索部门 / 姓名 / 工号',
    this.showDepartmentFilter = true,
    this.candidateScopeKey,
    this.emptyMessage = '未找到匹配的人员',
    this.selectedCountLabel,
    this.clearLabel = '清空',
    this.confirmLabel = '确定',
    this.validator,
    this.required = false,
    this.info,
  });

  final UtenEmployeePickerLoader loader;
  final ValueChanged<List<UtenEmployeePickerItem>> onChanged;
  final List<UtenEmployeePickerItem> initialSelection;
  final bool enabled;
  final String? label;
  final String hint;
  final String sheetTitle;
  final String searchHint;
  final bool showDepartmentFilter;

  /// Stable identity for candidates whose business scope can change.
  final Object? candidateScopeKey;
  final String emptyMessage;
  final String Function(int count)? selectedCountLabel;
  final String clearLabel;
  final String confirmLabel;
  final String? Function(List<UtenEmployeePickerItem> selection)? validator;

  /// 是否必填：标签后显红 *；未选且启用时输入框描红边。
  final bool required;

  /// ⓘ 说明（悬停/点按出 Tooltip）——与 fieldLabel(info:) 同一口径。经
  /// UtenInputDecoration 适配后渲染在输入框内的后缀区，不在标签旁。
  final String? info;

  @override
  State<UtenEmployeeMultiPicker> createState() =>
      _UtenEmployeeMultiPickerState();
}

class _UtenEmployeeMultiPickerState extends State<UtenEmployeeMultiPicker> {
  final _fieldKey = GlobalKey<FormFieldState<List<UtenEmployeePickerItem>>>();
  List<UtenEmployeePickerItem> _selection = const [];
  int _fieldVersion = 0;

  // ADR-150: the chosen people are readable by the AI assistant (names only,
  // computed on capture); choosing people stays with the user (no setter).
  final _aiSlot = AiPageSlot();

  @override
  void initState() {
    super.initState();
    _selection = List.of(widget.initialSelection);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiSlot.attach(
      context,
      widget.label == null ? null : AiFieldSource(capture: _aiField),
    );
  }

  @override
  void dispose() {
    _aiSlot.detach();
    super.dispose();
  }

  AiFieldSnapshot? _aiField(AiCaptureContext ctx) {
    final label = aiSnapshotLabel(widget.label);
    if (!mounted || label == null) return null;
    final requiredEmpty =
        widget.enabled && widget.required && _selection.isEmpty;
    return AiFieldSnapshot(
      label: label,
      value: _selection.isEmpty
          ? null
          : aiSnapshotValue(
              _selection.map((item) => item.displayName).join('、'),
            ),
      state: requiredEmpty ? AiFieldState.requiredEmpty : AiFieldState.normal,
      required: widget.required,
      info: aiSnapshotValue(widget.info, AiSnapshotLimits.info),
    );
  }

  @override
  void didUpdateWidget(UtenEmployeeMultiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initialChanged = !sameEmployeePickerSelection(
      widget.initialSelection,
      oldWidget.initialSelection,
    );
    if (initialChanged ||
        widget.enabled != oldWidget.enabled ||
        widget.candidateScopeKey != oldWidget.candidateScopeKey ||
        widget.showDepartmentFilter != oldWidget.showDepartmentFilter) {
      _fieldVersion++;
    }
    if (initialChanged) {
      _selection = List.of(widget.initialSelection);
      _fieldKey.currentState?.didChange(_selection);
    }
  }

  Future<void> _open() async {
    final version = ++_fieldVersion;
    final result = await showUtenEmployeeSelectionPanel(
      context,
      loader: widget.loader,
      multiple: true,
      initialSelection: _selection,
      title: widget.sheetTitle,
      searchHint: widget.searchHint,
      showDepartmentFilter: widget.showDepartmentFilter,
      candidateScopeKey: widget.candidateScopeKey,
      emptyMessage: widget.emptyMessage,
      selectedCountLabel: widget.selectedCountLabel,
      clearLabel: widget.clearLabel,
      confirmLabel: widget.confirmLabel,
    );
    if (result == null ||
        !mounted ||
        !widget.enabled ||
        version != _fieldVersion) {
      return;
    }
    setState(() => _selection = result);
    _fieldKey.currentState?.didChange(_selection);
    widget.onChanged(_selection);
  }

  void _remove(UtenEmployeePickerItem item) {
    _fieldVersion++;
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
                          : fieldLabel(
                              widget.label!,
                              theme,
                              required: widget.required,
                              info: widget.info,
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
