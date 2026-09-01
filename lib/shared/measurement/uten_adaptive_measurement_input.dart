import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'measurement_capture_profile.dart';

/// Mutable row state shared by editable grids and compact form cards.
///
/// Profile updates never write either controller. If the employee has started
/// editing, the current disclosure layout is also preserved for the rest of
/// that editing session.
class MeasurementCaptureRowState extends ChangeNotifier {
  MeasurementCaptureRowState({
    required MeasurementCaptureProfile profile,
    TextEditingController? businessQuantityController,
    TextEditingController? actualWeightController,
    String initialBusinessQuantity = '',
    String initialActualWeight = '',
  }) : _profile = profile,
       _ownsBusinessQuantityController = businessQuantityController == null,
       _ownsActualWeightController = actualWeightController == null,
       businessQuantityController =
           businessQuantityController ??
           TextEditingController(text: initialBusinessQuantity),
       actualWeightController =
           actualWeightController ??
           TextEditingController(text: initialActualWeight) {
    _actualWeightExpanded =
        profile.initiallyShowsActualWeight ||
        this.actualWeightController.text.trim().isNotEmpty;
    this.businessQuantityController.addListener(_onEmployeeInput);
    this.actualWeightController.addListener(_onActualWeightInput);
  }

  MeasurementCaptureProfile _profile;
  final bool _ownsBusinessQuantityController;
  final bool _ownsActualWeightController;
  final TextEditingController businessQuantityController;
  final TextEditingController actualWeightController;

  late bool _actualWeightExpanded;
  bool _hasEmployeeInput = false;
  bool _actualWeightUnitSelectionRequested = false;

  MeasurementCaptureProfile get profile => _profile;
  bool get actualWeightExpanded => _actualWeightExpanded;
  bool get hasEmployeeInput => _hasEmployeeInput;
  bool get actualWeightUnitSelectionRequested =>
      _actualWeightUnitSelectionRequested;

  void _onEmployeeInput() {
    _hasEmployeeInput = true;
    notifyListeners();
  }

  void _onActualWeightInput() {
    _hasEmployeeInput = true;
    if (actualWeightController.text.trim().isNotEmpty) {
      _actualWeightExpanded = true;
    }
    notifyListeners();
  }

  void updateProfile(MeasurementCaptureProfile next) {
    _profile = next;
    if (_actualWeightUnitSelectionRequested &&
        next.actualWeightUnitId != null) {
      _actualWeightUnitSelectionRequested = false;
      _actualWeightExpanded = true;
    }
    if (!_hasEmployeeInput) {
      _actualWeightExpanded =
          _actualWeightExpanded ||
          next.initiallyShowsActualWeight ||
          actualWeightController.text.trim().isNotEmpty;
    } else if (actualWeightController.text.trim().isNotEmpty) {
      _actualWeightExpanded = true;
    }
    notifyListeners();
  }

  void showActualWeight() {
    if (!_profile.canSupplementActualWeight || _actualWeightExpanded) return;
    if (_profile.actualWeightUnitId == null) {
      _actualWeightUnitSelectionRequested = true;
      notifyListeners();
      return;
    }
    _actualWeightExpanded = true;
    notifyListeners();
  }

  bool hideActualWeight() {
    if (actualWeightController.text.trim().isNotEmpty ||
        _profile.capturesActualWeight ||
        !_actualWeightExpanded) {
      return false;
    }
    _actualWeightExpanded = false;
    _actualWeightUnitSelectionRequested = false;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    businessQuantityController.removeListener(_onEmployeeInput);
    actualWeightController.removeListener(_onActualWeightInput);
    if (_ownsBusinessQuantityController) businessQuantityController.dispose();
    if (_ownsActualWeightController) actualWeightController.dispose();
    super.dispose();
  }
}

class UtenAdaptiveMeasurementInput extends StatelessWidget {
  const UtenAdaptiveMeasurementInput({
    super.key,
    required this.state,
    required this.itemLabel,
    this.enabled = true,
    this.businessQuantityLabel = '数量',
    this.actualWeightLabel = '实际重量',
    this.businessQuantityRequired = true,
    this.actualWeightRequired = false,
    this.businessQuantityValidator,
    this.actualWeightValidator,
    this.onSelectActualWeightUnit,
    this.onConflictAction,
    this.onEvidenceAction,
  });

  final MeasurementCaptureRowState state;
  final String itemLabel;
  final bool enabled;
  final String businessQuantityLabel;
  final String actualWeightLabel;
  final bool businessQuantityRequired;
  final bool actualWeightRequired;
  final FormFieldValidator<String>? businessQuantityValidator;
  final FormFieldValidator<String>? actualWeightValidator;
  final VoidCallback? onSelectActualWeightUnit;
  final VoidCallback? onConflictAction;
  final VoidCallback? onEvidenceAction;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final profile = state.profile;
        final semantics = <String>[
          itemLabel,
          profile.statusLabel,
          '$businessQuantityLabel单位${profile.businessUnitName ?? '未命名'}',
          if (state.actualWeightExpanded)
            '$actualWeightLabel单位${profile.actualWeightUnitName ?? '未命名'}',
        ].join('，');
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: semantics,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
              final stacked = constraints.maxWidth < 480 || textScale > 1.35;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (profile.status != Status.unknown ||
                      onEvidenceAction != null)
                    _MeasurementStatusRow(
                      profile: profile,
                      onConflictAction: onConflictAction,
                      onEvidenceAction: onEvidenceAction,
                    ),
                  if (profile.status == Status.provisional) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      profile.evidenceCount > 0
                          ? '正在学习，可补充实际重量；已有 ${profile.evidenceCount} 条依据'
                          : '正在学习，可补充实际重量',
                      key: const Key('measurement-learning-hint'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (profile.status != Status.unknown ||
                      onEvidenceAction != null)
                    const SizedBox(height: UtenSpacing.s8),
                  _MeasurementFields(
                    stacked: stacked,
                    state: state,
                    enabled: enabled,
                    businessQuantityLabel: businessQuantityLabel,
                    actualWeightLabel: actualWeightLabel,
                    businessQuantityRequired: businessQuantityRequired,
                    actualWeightRequired: actualWeightRequired,
                    businessQuantityValidator: businessQuantityValidator,
                    actualWeightValidator: actualWeightValidator,
                  ),
                  if (state.actualWeightUnitSelectionRequested &&
                      profile.actualWeightUnitId == null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Semantics(
                        button: true,
                        label: '$itemLabel，选择实际重量单位',
                        child: OutlinedButton.icon(
                          key: const Key('measurement-select-weight-unit'),
                          autofocus: true,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                          onPressed: enabled ? onSelectActualWeightUnit : null,
                          icon: const Icon(Icons.straighten_outlined, size: 18),
                          label: const Text('选择重量单位'),
                        ),
                      ),
                    ),
                  ],
                  if (!state.actualWeightExpanded &&
                      !state.actualWeightUnitSelectionRequested &&
                      profile.canSupplementActualWeight) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Semantics(
                        button: true,
                        expanded: false,
                        label: '$itemLabel，补充实际重量',
                        child: TextButton.icon(
                          key: const Key('measurement-add-weight'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                          onPressed: enabled ? state.showActualWeight : null,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('补充实际重量'),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _MeasurementFields extends StatelessWidget {
  const _MeasurementFields({
    required this.stacked,
    required this.state,
    required this.enabled,
    required this.businessQuantityLabel,
    required this.actualWeightLabel,
    required this.businessQuantityRequired,
    required this.actualWeightRequired,
    required this.businessQuantityValidator,
    required this.actualWeightValidator,
  });

  final bool stacked;
  final MeasurementCaptureRowState state;
  final bool enabled;
  final String businessQuantityLabel;
  final String actualWeightLabel;
  final bool businessQuantityRequired;
  final bool actualWeightRequired;
  final FormFieldValidator<String>? businessQuantityValidator;
  final FormFieldValidator<String>? actualWeightValidator;

  @override
  Widget build(BuildContext context) {
    final profile = state.profile;
    final quantity = _field(
      key: const Key('measurement-business-quantity'),
      controller: state.businessQuantityController,
      label: businessQuantityLabel,
      unit: profile.businessUnitName,
      required: businessQuantityRequired,
      validator: businessQuantityValidator,
    );
    final weight = state.actualWeightExpanded
        ? _field(
            key: const Key('measurement-actual-weight'),
            controller: state.actualWeightController,
            label: actualWeightLabel,
            unit: profile.actualWeightUnitName,
            required: actualWeightRequired,
            validator: actualWeightValidator,
          )
        : null;
    if (stacked || weight == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          quantity,
          if (weight != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            weight,
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: quantity),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: weight),
      ],
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String? unit,
    required bool required,
    required FormFieldValidator<String>? validator,
  }) {
    final displayUnit = unit?.trim().isNotEmpty == true
        ? unit!.trim()
        : '单位未命名';
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: TextFormField(
        key: key,
        controller: controller,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: '$label（$displayUnit）${required ? ' *' : ''}',
        ),
        validator: validator,
      ),
    );
  }
}

class _MeasurementStatusRow extends StatelessWidget {
  const _MeasurementStatusRow({
    required this.profile,
    required this.onConflictAction,
    required this.onEvidenceAction,
  });

  final MeasurementCaptureProfile profile;
  final VoidCallback? onConflictAction;
  final VoidCallback? onEvidenceAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (background, foreground, icon) = switch (profile.status) {
      Status.provisional => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
        Icons.auto_awesome_outlined,
      ),
      Status.confirmed => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
        Icons.check_circle_outline_rounded,
      ),
      Status.conflict => (
        colors.errorContainer,
        colors.onErrorContainer,
        Icons.warning_amber_rounded,
      ),
      Status.manualOverride => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
        Icons.person_outline_rounded,
      ),
      Status.unknown => (
        colors.surfaceContainerHigh,
        colors.onSurfaceVariant,
        Icons.help_outline_rounded,
      ),
    };
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          label: profile.statusLabel,
          child: Container(
            key: const Key('measurement-status'),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  profile.statusLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (profile.status == Status.conflict)
          Semantics(
            button: true,
            label: '选择本次计量方式',
            child: TextButton(
              key: const Key('measurement-conflict-action'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              onPressed: onConflictAction,
              child: const Text('请选择本次'),
            ),
          )
        else if (onEvidenceAction != null)
          Semantics(
            button: true,
            label: '查看计量依据',
            child: TextButton(
              key: const Key('measurement-evidence-action'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              onPressed: onEvidenceAction,
              child: const Text('查看依据'),
            ),
          ),
      ],
    );
  }
}
