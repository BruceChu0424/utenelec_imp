// UtenPositionEntryPicker - 入职等表单使用的「岗位选择 + 自由填写」组件。
//
// 部门未选时禁用；打开后加载该部门全部岗位，可按名称/编码/职级过滤。
// 所有选择与输入都先保存在弹层草稿，只有点击「确认」才回填；未命中的文本
// 作为自定义岗位名交给后端按部门复用或创建。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../models/position.dart';
import '../repositories/position_repository.dart';
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
    final sheet = _PositionEntrySheet(
      departmentId: departmentId,
      initialValue: _value,
    );
    final PositionEntryValue? result;
    if (context.breakpoint.isCompact) {
      result = await showModalBottomSheet<PositionEntryValue>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(heightFactor: 0.9, child: sheet),
        ),
      );
    } else {
      result = await showGeneralDialog<PositionEntryValue>(
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
            child: SizedBox(width: 420, height: double.infinity, child: sheet),
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

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label ?? l10n.employeeFieldPosition,
      value: display ?? hint,
      child: InkWell(
        key: const Key('uten-position-entry-field'),
        onTap: enabled ? _open : null,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          isEmpty: display == null,
          decoration: utenPickerFieldDecoration(
            context,
            labelText: widget.label,
            hintText: hint,
            enabled: enabled,
            suffixIcon: Icon(
              Icons.unfold_more_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          child: display == null
              ? null
              : Text(display, overflow: TextOverflow.ellipsis),
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

  bool _matches(Position position, String normalizedQuery) =>
      position.name.toLowerCase().contains(normalizedQuery) ||
      position.code.toLowerCase().contains(normalizedQuery) ||
      position.level.toLowerCase().contains(normalizedQuery);

  List<Position> get _filteredPositions {
    final positions = _positions ?? const <Position>[];
    final normalized = _query.toLowerCase();
    if (normalized.isEmpty) return positions;
    return positions.where((item) => _matches(item, normalized)).toList();
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

  Widget _positionTile(Position position) {
    final theme = Theme.of(context);
    final selected = _selected?.id == position.id;
    final metadata = [
      if (position.code.trim().isNotEmpty) position.code.trim(),
      if (position.level.trim().isNotEmpty) position.level.trim(),
    ].join(' · ');
    return ListTile(
      key: Key('position-option-${position.id}'),
      minVerticalPadding: 10,
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.45,
      ),
      title: Text(position.name),
      subtitle: metadata.isEmpty ? null : Text(metadata),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
          : null,
      onTap: () => _select(position),
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
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Material(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
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
        if (_positions?.isEmpty == true && _query.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.positionPickerNoPositions,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (showCustom) _customTile(l10n),
        for (final position in filtered) _positionTile(position),
      ],
    );
  }

  ButtonStyle get _actionStyle =>
      TextButton.styleFrom(minimumSize: const Size(64, 48));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.positionPickerTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.commonCancel,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('uten-position-entry-search'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                hintText: l10n.positionPickerSearchHint,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.positionPickerClear,
                        onPressed: _clearDraft,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          Expanded(child: _listBody(l10n)),
          UtenBottomActionBar(
            child: Row(
              children: [
                TextButton(
                  key: const Key('uten-position-entry-clear'),
                  style: _actionStyle,
                  onPressed: _clearDraft,
                  child: Text(l10n.positionPickerClear),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('uten-position-entry-cancel'),
                  style: _actionStyle,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('uten-position-entry-confirm'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 48),
                  ),
                  onPressed: _confirm,
                  child: Text(l10n.commonConfirm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
