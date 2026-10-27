import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../shared/auth/permissions.dart';
import '../repositories/mould_manufacturer_repository.dart';
import '../repositories/supplier_repository.dart';

String mouldManufacturerDisplayText(
  String? value, {
  required String missingLabel,
}) => value?.trim().isNotEmpty == true ? value!.trim() : missingLabel;

AppLocalizations _manufacturerL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    lookupAppLocalizations(Localizations.localeOf(context));

/// Display-only placeholder; the underlying null value remains unchanged for
/// filtering, exports, drafts and writes.
class MouldManufacturerValue extends ConsumerWidget {
  const MouldManufacturerValue({super.key, this.value});
  final String? value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = _manufacturerL10n(context);
    final missing = value?.trim().isNotEmpty != true;
    final canEdit = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.mouldEdit);
    return Tooltip(
      message: missing
          ? canEdit
                ? l10n.mouldManufacturerMissingEditableHint
                : l10n.mouldManufacturerMissingHint
          : value!,
      child: Text(
        mouldManufacturerDisplayText(
          value,
          missingLabel: l10n.mouldManufacturerMissing,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: missing
            ? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
            : null,
      ),
    );
  }
}

/// A free text value with ranked historical suggestions. A new manufacturer
/// remains valid without creating another master or choosing a candidate.
class MouldManufacturerField extends ConsumerStatefulWidget {
  const MouldManufacturerField({
    super.key,
    this.value,
    this.enabled = true,
    this.dense = false,
    this.writePermission,
    required this.onChanged,
  });
  final String? value;
  final bool enabled;
  final bool dense;
  final String? writePermission;
  final ValueChanged<String> onChanged;
  @override
  ConsumerState<MouldManufacturerField> createState() =>
      _MouldManufacturerFieldState();
}

class _MouldManufacturerFieldState
    extends ConsumerState<MouldManufacturerField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final _focus = FocusNode();
  final _menu = MenuController();
  final _menuFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  bool _closingForSelection = false;
  Timer? _debounce;
  int _generation = 0;
  List<String> _options = const [];
  List<String> _supplierOptions = const [];
  bool _loading = false;
  bool _failed = false;
  bool _supplierFailed = false;

  bool get _enabled =>
      widget.enabled &&
      (widget.writePermission == null ||
          ref
              .read(currentPermissionsProvider)
              .contains(widget.writePermission));

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    _menuFocus.addListener(_menuFocusChanged);
  }

  @override
  void didUpdateWidget(MouldManufacturerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && widget.value != _text.text) {
      _text.text = widget.value ?? '';
      _invalidateCandidates();
    }
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.writePermission != widget.writePermission) {
      _invalidateCandidates();
    }
  }

  void _invalidateCandidates() {
    _generation++;
    _debounce?.cancel();
    _options = const [];
    _supplierOptions = const [];
    _loading = false;
    _menu.close();
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      if (!_closingForSelection) _search(immediate: true);
    } else {
      _generation++;
      _debounce?.cancel();
      _closeIfFocusLeft();
    }
  }

  void _menuFocusChanged() {
    if (!_menuFocus.hasFocus) _closeIfFocusLeft();
  }

  void _closeIfFocusLeft() {
    if (!_menu.isOpen) return;
    // Focus can move from the input into a candidate on pointer-down. Wait for
    // the whole transfer before closing, so the candidate's click still commits.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus && !_menuFocus.hasFocus) _menu.close();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _search({bool immediate = false}) {
    if (!_enabled) return;
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _supplierFailed = false;
      _options = const [];
      _supplierOptions = const [];
    });
    if (!_menu.isOpen) _menu.open();
    if (immediate) {
      unawaited(_load(generation));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 280),
        () => _load(generation),
      );
    }
  }

  Future<void> _load(int generation) async {
    final repository = ref.read(mouldManufacturerRepositoryProvider);
    final canReadSuppliers = ref
        .read(currentPermissionsProvider)
        .contains(Perm.supplierView);
    final suppliers = canReadSuppliers
        ? ref.read(supplierRepositoryProvider)
        : null;
    final keyword = _text.text;
    Future<({List<String> values, bool failed})> tolerate(
      Future<List<String>> request,
    ) async {
      try {
        return (values: await request, failed: false);
      } catch (_) {
        return (values: const <String>[], failed: true);
      }
    }

    final results = await Future.wait([
      tolerate(repository.suggestions(keyword)),
      if (suppliers != null)
        tolerate(
          suppliers
              .search(keyword, size: 8, selectableOnly: true)
              .then(
                (page) => [
                  ...page.items
                      .map((supplier) {
                        final name = supplier.name?.trim() ?? '';
                        return name.isNotEmpty
                            ? name
                            : supplier.description?.trim() ?? '';
                      })
                      .where((name) => name.isNotEmpty && name.length <= 200)
                      .toSet(),
                ],
              ),
        ),
    ]);
    if (!mounted ||
        generation != _generation ||
        !_enabled ||
        !identical(repository, ref.read(mouldManufacturerRepositoryProvider)) ||
        (suppliers != null &&
            (!ref
                    .read(currentPermissionsProvider)
                    .contains(Perm.supplierView) ||
                !identical(suppliers, ref.read(supplierRepositoryProvider))))) {
      return;
    }
    setState(() {
      _options = results.first.values;
      _failed = results.first.failed;
      _supplierOptions = suppliers == null ? const [] : results[1].values;
      _supplierFailed = suppliers != null && results[1].failed;
      _loading = false;
    });
  }

  void _choose(
    String value, {
    required int generation,
    bool supplierName = false,
  }) {
    final canWrite = _enabled;
    if (!canWrite ||
        generation != _generation ||
        (supplierName &&
            !ref
                .read(currentPermissionsProvider)
                .contains(Perm.supplierView))) {
      return;
    }
    _closingForSelection = true;
    _generation++;
    _debounce?.cancel();
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged(value);
    _menu.close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _closingForSelection = false;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _manufacturerL10n(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canReadSuppliers = permissions.contains(Perm.supplierView);
    final generation = _generation;
    ref.listen(currentPermissionsProvider, (_, _) => _invalidateCandidates());
    if (canReadSuppliers) {
      ref.listen(supplierRepositoryProvider, (_, _) => _invalidateCandidates());
    }
    ref.listen(mouldManufacturerRepositoryProvider, (_, _) {
      _invalidateCandidates();
    });
    final field = LayoutBuilder(
      builder: (context, constraints) => UtenDropdownScrollScope(
        child: MenuAnchor(
          controller: _menu,
          crossAxisUnconstrained: false,
          style: MenuStyle(
            maximumSize: WidgetStatePropertyAll(
              Size(constraints.maxWidth, 280),
            ),
          ),
          menuChildren: [
            Focus(
              focusNode: _menuFocus,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(UtenSpacing.s12),
                      child: LinearProgressIndicator(),
                    )
                  else if (_failed || _options.isEmpty)
                    MenuItemButton(
                      child: Text(
                        _failed
                            ? l10n.mouldManufacturerHistoryUnavailable
                            : l10n.mouldManufacturerHistoryEmpty,
                      ),
                    )
                  else
                    for (final value in _options)
                      MenuItemButton(
                        onPressed: () => _choose(value, generation: generation),
                        child: Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  if (!_loading && canReadSuppliers) ...[
                    MenuItemButton(
                      child: Text(l10n.mouldManufacturerSupplierCandidates),
                    ),
                    if (_supplierFailed || _supplierOptions.isEmpty)
                      MenuItemButton(
                        child: Text(
                          _supplierFailed
                              ? l10n.mouldManufacturerSupplierUnavailable
                              : l10n.mouldManufacturerSupplierEmpty,
                        ),
                      )
                    else
                      for (final value in _supplierOptions)
                        MenuItemButton(
                          onPressed: () => _choose(
                            value,
                            generation: generation,
                            supplierName: true,
                          ),
                          child: Text(
                            value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ],
          builder: (context, controller, _) => TextField(
            controller: _text,
            focusNode: _focus,
            enabled: _enabled,
            maxLength: 200,
            onChanged: (value) {
              if (!_enabled) return;
              widget.onChanged(value);
              _search();
            },
            onTap: () {
              if (!controller.isOpen) _search(immediate: true);
            },
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: widget.dense ? null : l10n.mouldManufacturerLabel,
                isDense: widget.dense,
                hintText: l10n.mouldManufacturerInputHint,
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: l10n.mouldManufacturerChooseHistoryTooltip,
                  icon: const Icon(Icons.arrow_drop_down),
                  onPressed: !_enabled
                      ? null
                      : () {
                          _focus.requestFocus();
                          _search(immediate: true);
                        },
                ),
              ),
              info: widget.dense ? null : l10n.mouldManufacturerInputHelp,
            ),
          ),
        ),
      ),
    );
    return widget.dense
        ? SizedBox(
            height: UtenEditableGridCellSpec.heightOf(context),
            child: field,
          )
        : field;
  }
}
