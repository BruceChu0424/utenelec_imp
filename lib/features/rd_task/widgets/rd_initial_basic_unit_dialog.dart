import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/unit_node.dart';
import '../../basic_data/repositories/unit_repository.dart';
import '../models/rd_task.dart';
import '../repositories/rd_task_repository.dart';

class RdInitialBasicUnitInput {
  const RdInitialBasicUnitInput(this.unitId, this.evidence) : openGoods = false;
  const RdInitialBasicUnitInput.openGoods()
    : unitId = '',
      evidence = '',
      openGoods = true;
  final String unitId;
  final String evidence;
  final bool openGoods;
}

class RdInitialBasicUnitDialog extends ConsumerStatefulWidget {
  const RdInitialBasicUnitDialog({
    super.key,
    required this.task,
    this.requestScope,
    this.isCurrent,
  });
  final RdTaskRow task;
  final AuthenticatedRequestScope? requestScope;
  final bool Function()? isCurrent;
  @override
  ConsumerState<RdInitialBasicUnitDialog> createState() => _UnitState();
}

class _UnitState extends ConsumerState<RdInitialBasicUnitDialog> {
  late Future<List<Object>> _data = _load();

  Future<List<Object>> _load() async {
    bool current() => mounted && (widget.isCurrent?.call() ?? true);
    if (!current()) throw AuthenticatedRequestScope.changed();
    Future<List<Object>> read() => Future.wait<Object>([
      ref.read(unitRepositoryProvider).dict(),
      ref
          .read(rdTaskRepositoryProvider)
          .initialBasicUnitContext(widget.task.id),
    ]);
    final values = await (widget.requestScope?.run(read) ?? read());
    if (!current()) throw AuthenticatedRequestScope.changed();
    return values;
  }

  final _evidence = TextEditingController();
  String? _unitId;
  bool _attempted = false;

  @override
  void dispose() {
    _evidence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<List<Object>>(
      future: _data,
      builder: (context, snapshot) {
        final units = snapshot.data?[0] as List<UnitListItem>?;
        final admission = snapshot.data?[1] as RdInitialUnitContext?;
        final allowed =
            admission?.allowed == true && (widget.isCurrent?.call() ?? true);
        return UtenAlertDialog(
          maxWidth: 600,
          title: Text(l10n.rdInitialUnitTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.task.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (widget.task.description?.isNotEmpty ?? false) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  SelectableText(
                    widget.task.description!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  l10n.rdInitialUnitGuidance,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s12),
                if (snapshot.hasError) ...[
                  UtenDropdownField(
                    label: l10n.rdInitialUnitLabel,
                    value: null,
                    items: const [],
                    onChanged: (_) {},
                    enabled: false,
                    errorMessage: l10n.rdInitialUnitLoadFailed,
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => setState(() {
                      _data = _load();
                    }),
                    child: Text(l10n.rdInitialUnitRetry),
                  ),
                ] else if (!snapshot.hasData)
                  const Center(child: CircularProgressIndicator())
                else
                  UtenDropdownField(
                    key: const Key('rd-initial-unit-choice'),
                    label: l10n.rdInitialUnitLabel,
                    required: true,
                    value: _unitId,
                    enabled: allowed,
                    items: [
                      for (final unit in units!)
                        if (unit.status == '使用')
                          UtenDropdownItem(
                            value: unit.id,
                            label: unit.name ?? unit.code ?? unit.id,
                          ),
                    ],
                    errorMessage: !allowed
                        ? admission?.reason
                        : _attempted && _unitId == null
                        ? l10n.rdInitialUnitRequired
                        : null,
                    onChanged: (value) => setState(() => _unitId = value),
                  ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const Key('rd-initial-unit-evidence'),
                  controller: _evidence,
                  enabled: allowed,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 1000,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: l10n.rdInitialUnitEvidence,
                      error: _attempted && _evidence.text.trim().length < 2
                          ? UtenFieldMessage.error(
                              l10n.rdInitialUnitEvidenceRequired,
                            )
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(
                context,
                const RdInitialBasicUnitInput.openGoods(),
              ),
              child: Text(l10n.materialBomIssueOpenGoods),
            ),
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.rdInitialUnitCancel),
            ),
            UtenButton(
              key: const Key('rd-initial-unit-confirm'),
              onPressed: !allowed
                  ? null
                  : () {
                      if (!(widget.isCurrent?.call() ?? true)) {
                        Navigator.pop(context);
                        return;
                      }
                      setState(() => _attempted = true);
                      if (_unitId == null || _evidence.text.trim().length < 2) {
                        return;
                      }
                      Navigator.pop(
                        context,
                        RdInitialBasicUnitInput(
                          _unitId!,
                          _evidence.text.trim(),
                        ),
                      );
                    },
              child: Text(l10n.rdInitialUnitConfirm),
            ),
          ],
        );
      },
    );
  }
}
