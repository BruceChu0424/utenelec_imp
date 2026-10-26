import '../../../shared/search/keyword_search.dart';
// UtenPositionEntryPicker - 入职等表单使用的「岗位选择 + 自由填写」组件。
//
// 部门未选时禁用；打开后加载该部门全部岗位，可按名称/编码/职级过滤。
// 所有选择与输入都先保存在弹层草稿，只有点击「确认」才回填；未命中的文本
// 作为自定义岗位名交给后端按部门复用或创建。
import '../../../core/theme/uten_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/position.dart';
import '../repositories/position_repository.dart';
import 'position_picker_table_columns.dart';
import 'uten_department_picker.dart';

/// 岗位输入的已确认值：已有岗位（保留 id）、自定义名称，或空值。
class PositionEntryValue {
  const PositionEntryValue.empty() : position = null, customName = null;

  const PositionEntryValue.existing(this.position) : customName = null;

  const PositionEntryValue.custom(this.customName) : position = null;

  final Position? position;
  final String? customName;

  bool get isEmpty => position == null && (customName?.trim().isEmpty ?? true);

  String get displayName => position?.name ?? customName?.trim() ?? '';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PositionEntryValue &&
          position?.id == other.position?.id &&
          customName?.trim() == other.customName?.trim();

  @override
  int get hashCode => Object.hash(position?.id, customName?.trim());
}

class UtenPositionEntryPicker extends ConsumerStatefulWidget {
  const UtenPositionEntryPicker({
    super.key,
    required this.departmentId,
    required this.onChanged,
    this.value = const PositionEntryValue.empty(),
    this.enabled = true,
    this.label,
  });

  final String? departmentId;
  final PositionEntryValue value;
  final ValueChanged<PositionEntryValue> onChanged;
  final bool enabled;
  final String? label;

  @override
  ConsumerState<UtenPositionEntryPicker> createState() =>
      _UtenPositionEntryPickerState();
}

class _UtenPositionEntryPickerState
    extends ConsumerState<UtenPositionEntryPicker> {
  late PositionEntryValue _value;

  bool get _hasDepartment => widget.departmentId?.trim().isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(UtenPositionEntryPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.departmentId != oldWidget.departmentId) {
      final shouldNotify = !widget.value.isEmpty;
      _value = const PositionEntryValue.empty();
      if (shouldNotify) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onChanged(const PositionEntryValue.empty());
        });
      }
      return;
    }
    if (widget.value != oldWidget.value) _value = widget.value;
  }

  Future<void> _open() async {
    final departmentId = widget.departmentId?.trim();
    if (!widget.enabled || departmentId == null || departmentId.isEmpty) {
      return;
    }
    final result = await showUtenAdaptivePanel<PositionEntryValue>(
      context: context,
      compactHeightFactor: 0.9,
      widthFraction: UtenPanelWidth.form,
      builder: (_) =>
          _PositionEntrySheet(departmentId: departmentId, initialValue: _value),
    );
    final confirmed = result;
    if (!mounted ||
        confirmed == null ||
        widget.departmentId?.trim() != departmentId) {
      return;
    }
    setState(() => _value = confirmed);
    widget.onChanged(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final enabled = widget.enabled && _hasDepartment;
    final display = _value.isEmpty ? null : _value.displayName;
    final hint = _hasDepartment
        ? l10n.positionPickerHint
        : l10n.positionPickerDepartmentFirst;
    final label = widget.label ?? l10n.employeeFieldPosition;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      value: display ?? label,
      hint: _hasDepartment ? null : l10n.positionPickerDepartmentFirst,
      child: InkWell(
        key: const Key('uten-position-entry-field'),
        onTap: enabled ? _open : null,
        borderRadius: BorderRadius.circular(UtenRadius.control),
        child: InputDecorator(
          isEmpty: display == null,
          decoration: utenPickerFieldDecoration(
            context,
            labelText: label,
            hintText: hint,
            enabled: enabled,
            suffixIcon: Icon(
              Icons.unfold_more_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          child: display == null
              ? null
              : Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
        ),
      ),
    );
  }
}

class _PositionEntrySheet extends ConsumerStatefulWidget {
  const _PositionEntrySheet({
    required this.departmentId,
    required this.initialValue,
  });

  final String departmentId;
  final PositionEntryValue initialValue;

  @override
  ConsumerState<_PositionEntrySheet> createState() =>
      _PositionEntrySheetState();
}

class _PositionEntrySheetState extends ConsumerState<_PositionEntrySheet> {
  late final TextEditingController _controller;
  Position? _selected;
  List<Position>? _positions;
  String? _error;
  int _requestVersion = 0;

  String get _query => _controller.text.trim();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialValue.position;
    _controller = TextEditingController(text: widget.initialValue.displayName)
      ..addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _requestVersion++;
    _controller
      ..removeListener(_onQueryChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_requestVersion;
    setState(() {
      _positions = null;
      _error = null;
    });
    try {
      final positions = await ref
          .read(positionRepositoryProvider)
          .listByDepartment(widget.departmentId);
      if (!mounted || request != _requestVersion) return;
      setState(() => _positions = _sortPositions(positions));
    } on ApiException catch (error) {
      if (!mounted || request != _requestVersion) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
      setState(
        () => _error = AppLocalizations.of(context).positionPickerLoadFailed,
      );
    }
  }

  List<Position> _sortPositions(List<Position> positions) {
    final sorted = List<Position>.of(positions);
    sorted.sort((a, b) {
      final aLeader = a.level == '领导层' ? 0 : 1;
      final bLeader = b.level == '领导层' ? 0 : 1;
      final leaderOrder = aLeader.compareTo(bLeader);
      if (leaderOrder != 0) return leaderOrder;
      final sortOrder = (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0);
      if (sortOrder != 0) return sortOrder;
      return a.name.compareTo(b.name);
    });
    return sorted;
  }

  void _onQueryChanged() {
    // 拼音组合中（composing 非空）不过滤不清选中：半截拼音把列表闪成「未找到」
    // 还会误清已选岗位；组合结束会再通知一次（2026-10-09 根因修复）。
    if (_controller.value.composing != TextRange.empty) return;
    final selected = _selected;
    if (selected != null) {
      final normalized = _query.toLowerCase();
      if (normalized != selected.name.trim().toLowerCase() &&
          normalized != selected.code.trim().toLowerCase()) {
        _selected = null;
      }
    }
    if (mounted) setState(() {});
  }

  List<Position> get _filteredPositions {
    final positions = _positions ?? const <Position>[];
    if (_query.isEmpty) return positions;
    final result = positions
        .where(
          (position) => matchesKeywordSearch([
            position.name,
            position.code,
            position.level,
          ], _query),
        )
        .toList();
    final originalOrder = {
      for (var index = 0; index < positions.length; index++)
        positions[index].id: index,
    };
    result.sort((a, b) {
      final rankA = keywordSearchRank([a.name, a.code], _query) ?? 4;
      final rankB = keywordSearchRank([b.name, b.code], _query) ?? 4;
      final rank = rankA.compareTo(rankB);
      return rank != 0
          ? rank
          : originalOrder[a.id]!.compareTo(originalOrder[b.id]!);
    });
    return result;
  }

  Position? get _exactMatch {
    final selected = _selected;
    final normalized = _query.toLowerCase();
    if (normalized.isEmpty) return null;
    if (selected != null &&
        (selected.name.trim().toLowerCase() == normalized ||
            selected.code.trim().toLowerCase() == normalized)) {
      return selected;
    }
    for (final position in _positions ?? const <Position>[]) {
      if (position.name.trim().toLowerCase() == normalized ||
          position.code.trim().toLowerCase() == normalized) {
        return position;
      }
    }
    return null;
  }

  void _select(Position position) {
    setState(() => _selected = position);
    _controller.value = TextEditingValue(
      text: position.name,
      selection: TextSelection.collapsed(offset: position.name.length),
    );
  }

  void _clearDraft() {
    _selected = null;
    _controller.clear();
  }

  void _confirm() {
    final text = _query;
    if (text.isEmpty) {
      Navigator.of(context).pop(const PositionEntryValue.empty());
      return;
    }
    final existing = _exactMatch;
    Navigator.of(context).pop(
      existing == null
          ? PositionEntryValue.custom(text)
          : PositionEntryValue.existing(existing),
    );
  }

  Widget _customTile(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return ListTile(
      key: const Key('position-custom-option'),
      minVerticalPadding: 10,
      leading: Icon(Icons.add_circle_outline, color: theme.colorScheme.primary),
      title: Text(l10n.positionPickerUseCustom(_query)),
      subtitle: Text(l10n.positionPickerCustomDescription),
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => _selected = null);
      },
    );
  }

  Widget _listBody(AppLocalizations l10n) {
    final theme = Theme.of(context);
    if (_positions == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = _filteredPositions;
    final showCustom = _query.isNotEmpty && _exactMatch == null;
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Material(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(UtenRadius.control),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
                  ],
                ),
              ),
            ),
          ),
        if (showCustom) _customTile(l10n),
        Expanded(
          child: MasterDataTableView<Position>(
            key: const Key('position-entry-candidates-table'),
            columns: positionPickerTableColumns(),
            items: filtered,
            rowKeyOf: (position) => position.id,
            rowWidgetKeyOf: (position) => Key('position-option-${position.id}'),
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            isSelected: (position) => _selected?.id == position.id,
            onRowTap: _select,
            singleTapRows: true,
            showFullscreenToggle: false,
            showColumnChooser: false,
            showPaginationControls: false,
            enableTextSelection: false,
            emptyMessage: _error != null || showCustom
                ? ''
                : l10n.positionPickerNoPositions,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          UtenPanelHeader(
            title: l10n.positionPickerTitle,
            closeTooltip: l10n.commonCancel,
            onClose: () => Navigator.of(context).pop(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: UtenSearchBar(
              key: const Key('uten-position-entry-search'),
              controller: _controller,
              autofocus: true,
              hint: l10n.positionPickerSearchHint,
              onSubmitted: (_) => _confirm(),
            ),
          ),
          Expanded(child: _listBody(l10n)),
          UtenBottomActionBar(
            child: Align(
              alignment: Alignment.centerRight,
              child: UtenPickerActions(
                showClear: true,
                onClear: _clearDraft,
                onCancel: () => Navigator.of(context).pop(),
                onConfirm: _confirm,
                clearLabel: l10n.positionPickerClear,
                cancelLabel: l10n.commonCancel,
                confirmLabel: l10n.commonConfirm,
                clearButtonKey: const Key('uten-position-entry-clear'),
                cancelButtonKey: const Key('uten-position-entry-cancel'),
                confirmButtonKey: const Key('uten-position-entry-confirm'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
