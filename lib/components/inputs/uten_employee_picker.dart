// UtenEmployeePicker - 抽屉式人员选择器（通用组件）
//
// 触发形态与 UtenDepartmentPicker 对齐：只读输入框样式 field
//（显示选中人姓名(工号)），点击拉开部门树 + 人员列表抽屉：
// - compact：约 85% 屏高的底部抽屉；
// - medium/expanded：与客户选择器同宽的右侧滑入面板。
// 响应式展示壳统一复用 showUtenAdaptivePanel。
//
// 抽屉内：标题行 + 关闭、UtenSearchBar（内置 300ms 防抖）调 loader、
// 可滚动结果列表（姓名(工号) + 部门副标题），点选后确认。
// 数据由调用方通过 loader 提供，本组件不关心 token / 接口来源。
import 'package:flutter/material.dart';

import 'required_field_decoration.dart';
import 'uten_employee_picker_models.dart';
import 'uten_employee_selection_panel.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

export 'uten_employee_picker_models.dart';
export 'uten_employee_selection_panel.dart';

/// 直接拉出人员选择面板（宽屏右侧滑入 / 窄屏底部抽屉），不经过表单字段壳。
/// 供表格单元格等非表单场景点开即选；返回 null = 用户取消。
Future<UtenEmployeePickerItem?> showUtenEmployeePickerPanel(
  BuildContext context, {
  required UtenEmployeePickerLoader loader,
  String title = '选择员工',
  String? selectedId,
  String? departmentName,
  Object? candidateScopeKey,
  bool showDepartmentFilter = true,
  String emptyMessage = '未找到匹配的人员',
  String? emptyDescription,
}) async {
  final selection = await showUtenEmployeeSelectionPanel(
    context,
    loader: loader,
    title: title,
    selectedId: selectedId,
    departmentName: departmentName,
    candidateScopeKey: candidateScopeKey,
    showDepartmentFilter: showDepartmentFilter,
    emptyMessage: emptyMessage,
    emptyDescription: emptyDescription,
  );
  return selection?.firstOrNull;
}

class UtenEmployeePicker extends StatefulWidget {
  const UtenEmployeePicker({
    super.key,
    required this.loader,
    required this.onChanged,
    this.initial,
    this.enabled = true,
    this.label,
    this.hint = '请选择员工',
    this.validator,
    this.departmentName,
    this.candidateScopeKey,
    this.showDepartmentFilter = true,
    this.sheetTitle = '选择员工',
    this.allowClear = false,
    this.emptyMessage = '未找到匹配的人员',
    this.emptyDescription,
    this.required = false,
  });

  /// 候选加载器（抽屉内搜索时调用）。
  final UtenEmployeePickerLoader loader;

  /// 选中变化回调。
  final ValueChanged<UtenEmployeePickerItem?> onChanged;

  /// 初始选中。
  final UtenEmployeePickerItem? initial;

  final bool enabled;
  final String? label;
  final String hint;

  /// 表单校验（返回错误文案或 null）。
  final String? Function(UtenEmployeePickerItem? value)? validator;

  /// 当前选择范围的部门名（抽屉标题下方提示，不参与人员主展示）。
  final String? departmentName;

  /// Stable business scope, e.g. the chosen workshop ID. Loader closures can
  /// change on every build and are deliberately not used as identity.
  final Object? candidateScopeKey;
  final bool showDepartmentFilter;

  final String sheetTitle;

  final bool allowClear;

  /// 未输入搜索词且候选为空时的业务空态；搜索无命中仍使用通用提示。
  final String emptyMessage;
  final String? emptyDescription;

  /// 是否必填：标签后显红 *；未选且启用时输入框描红边。
  final bool required;

  @override
  State<UtenEmployeePicker> createState() => _UtenEmployeePickerState();
}

class _UtenEmployeePickerState extends State<UtenEmployeePicker> {
  final _fieldKey = GlobalKey<FormFieldState<UtenEmployeePickerItem?>>();
  UtenEmployeePickerItem? _selected;
  int _hydrateSerial = 0;
  int _fieldVersion = 0;

  // ADR-150: the chosen person (name and employee code) is readable by the AI
  // assistant; choosing someone stays with the user (no setter).
  final _aiSlot = AiPageSlot();

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
    final selected = _selected;
    final requiredEmpty = widget.required && widget.enabled && selected == null;
    return AiFieldSnapshot(
      label: label,
      value: selected == null ? null : aiSnapshotValue(selected.displayName),
      state: requiredEmpty ? AiFieldState.requiredEmpty : AiFieldState.normal,
      required: widget.required,
    );
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
    _hydrateSelectedIfNeeded();
  }

  @override
  void didUpdateWidget(UtenEmployeePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initialChanged = widget.initial == null
        ? oldWidget.initial != null
        : !widget.initial!.sameSnapshot(oldWidget.initial);
    final scopeChanged =
        widget.candidateScopeKey != oldWidget.candidateScopeKey ||
        widget.departmentName != oldWidget.departmentName ||
        widget.showDepartmentFilter != oldWidget.showDepartmentFilter;
    if (initialChanged || scopeChanged || widget.enabled != oldWidget.enabled) {
      _fieldVersion++;
      _hydrateSerial++;
    }
    if (initialChanged) {
      final next = widget.initial;
      final current = _selected;
      _selected =
          next != null &&
              current?.id == next.id &&
              next.employeeCode?.trim().isNotEmpty != true &&
              current?.employeeCode?.trim().isNotEmpty == true
          ? UtenEmployeePickerItem(
              id: next.id,
              name: next.name,
              employeeCode: current!.employeeCode,
              departmentId: next.departmentId,
              departmentName: next.departmentName,
              subtitle: next.subtitle,
              enabled: next.enabled,
              disabledReason: next.disabledReason,
            )
          : next;
    }
    if (initialChanged || scopeChanged) _hydrateSelectedIfNeeded();
  }

  /// 历史详情有时只带员工 id/姓名。复用当前 loader 按姓名补查一次工号，
  /// 让既有选中值也能升级为“姓名(工号)”；补查失败不阻塞表单。
  Future<void> _hydrateSelectedIfNeeded() async {
    final request = ++_hydrateSerial;
    final target = _selected;
    if (target == null || target.employeeCode?.trim().isNotEmpty == true) {
      return;
    }
    try {
      final keyword = target.name.trim();
      final items = await widget.loader(keyword.isEmpty ? null : keyword);
      if (!mounted || request != _hydrateSerial || _selected?.id != target.id) {
        return;
      }
      UtenEmployeePickerItem? hydrated;
      for (final item in items) {
        if (item.id == target.id &&
            item.employeeCode?.trim().isNotEmpty == true) {
          hydrated = item;
          break;
        }
      }
      if (hydrated == null) return;
      setState(() => _selected = hydrated);
      _fieldKey.currentState?.didChange(hydrated);
    } catch (_) {
      // 工号补查仅增强展示；权限受限、网络失败或历史人员缺失时保留原姓名。
    }
  }

  Future<void> _open() async {
    final version = ++_fieldVersion;
    _hydrateSerial++;
    final selection = await showUtenEmployeeSelectionPanel(
      context,
      loader: widget.loader,
      title: widget.sheetTitle,
      initialSelection: [?_selected],
      departmentName: widget.departmentName,
      candidateScopeKey: widget.candidateScopeKey,
      showDepartmentFilter: widget.showDepartmentFilter,
      emptyMessage: widget.emptyMessage,
      emptyDescription: widget.emptyDescription,
    );
    final selected = selection?.firstOrNull;
    if (selected == null ||
        !mounted ||
        !widget.enabled ||
        version != _fieldVersion) {
      return;
    }
    setState(() => _selected = selected);
    _fieldKey.currentState?.didChange(_selected);
    widget.onChanged(selected);
  }

  void _clear() {
    _fieldVersion++;
    _hydrateSerial++;
    setState(() => _selected = null);
    _fieldKey.currentState?.didChange(null);
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sel = _selected;
    final String? display = sel?.displayName;
    final requiredEmpty = widget.enabled && widget.required && sel == null;

    return FormField<UtenEmployeePickerItem?>(
      key: _fieldKey,
      initialValue: _selected,
      validator: widget.validator == null
          ? null
          : (_) => widget.validator!(_selected),
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.enabled ? _open : null,
            borderRadius: BorderRadius.circular(10),
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
                    prefixIcon: const Icon(Icons.person_search_rounded),
                    suffixIcon: sel != null && widget.allowClear
                        ? IconButton(
                            tooltip: '清除选择',
                            onPressed: widget.enabled ? _clear : null,
                            icon: const Icon(Icons.clear_rounded),
                          )
                        : Icon(
                            Icons.unfold_more_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: theme.colorScheme.outline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: theme.colorScheme.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
                theme,
                requiredEmpty: requiredEmpty,
              ),
              child: display == null
                  ? null
                  : Text(display, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}
