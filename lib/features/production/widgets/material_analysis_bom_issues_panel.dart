import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../models/material_analysis_bom_diagnostic.dart';

/// A bounded, lazy list: all findings are available together without building an entire BOM on a frame.
class MaterialAnalysisBomIssuesPanel extends StatefulWidget {
  const MaterialAnalysisBomIssuesPanel({
    super.key,
    required this.diagnostic,
    required this.sourceCount,
    required this.busy,
    required this.onRecheck,
    required this.onForward,
    this.onContinue,
  });
  final MaterialAnalysisBomDiagnostic diagnostic;
  final int sourceCount;
  final bool busy;
  final Future<void> Function() onRecheck;
  final Future<void> Function(Set<String>)? onForward;
  final VoidCallback? onContinue;

  @override
  State<MaterialAnalysisBomIssuesPanel> createState() => _IssuesState();
}

class _IssuesState extends State<MaterialAnalysisBomIssuesPanel> {
  final Set<String> _selected = {};

  @override
  void didUpdateWidget(covariant MaterialAnalysisBomIssuesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.diagnostic.findings.map((item) => item.key).toSet();
    _selected.removeWhere((key) => !current.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    final findings = widget.diagnostic.findings;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final available =
        widget.sourceCount - widget.diagnostic.blockedSourceIndexes.length;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .5,
      ),
      child: SingleChildScrollView(
        child: Material(
          key: const Key('material-analysis-bom-issues'),
          color: theme.colorScheme.errorContainer.withValues(alpha: .35),
          borderRadius: UtenRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.materialBomIssueHeading(
                    findings.length,
                    widget.diagnostic.blockedSourceIndexes.length,
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  l10n.materialBomIssueGuidance,
                  style: theme.textTheme.bodySmall,
                ),
                SizedBox(
                  height: math.min(
                    240,
                    MediaQuery.sizeOf(context).height * .28,
                  ),
                  child: ListView.builder(
                    key: const Key('material-analysis-bom-findings'),
                    itemCount: findings.length,
                    itemBuilder: (context, index) {
                      final issue = findings[index];
                      return CheckboxListTile(
                        key: ValueKey('bom-finding-${issue.key}'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(issue.key),
                        onChanged: widget.busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(issue.key);
                                } else {
                                  _selected.remove(issue.key);
                                }
                              }),
                        title: Text(
                          '${issue.rootLabel} · ${issue.parentLabel} → ${issue.componentLabel}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        subtitle: Text(
                          '${issue.reason}。${issue.fix}。${issue.taskNo == null ? '' : l10n.materialBomIssueForwardedTask(issue.taskNo!)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
                ),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      onPressed: widget.busy
                          ? null
                          : () => setState(() {
                              if (_selected.length == findings.length) {
                                _selected.clear();
                              } else {
                                _selected.addAll(
                                  findings.map((item) => item.key),
                                );
                              }
                            }),
                      child: Text(
                        _selected.length == findings.length
                            ? l10n.materialBomIssueDeselectAll
                            : l10n.materialBomIssueSelectAll,
                      ),
                    ),
                    if (widget.onForward != null)
                      UtenButton(
                        key: const Key('bom-issues-forward'),
                        size: UtenButtonSize.small,
                        isLoading: widget.busy,
                        onPressed: _selected.isEmpty
                            ? null
                            : () => widget.onForward!(Set.of(_selected)),
                        child: Text(
                          l10n.materialBomIssueForward(_selected.length),
                        ),
                      ),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      onPressed: widget.busy ? null : widget.onRecheck,
                      child: Text(l10n.materialBomIssueRecheck),
                    ),
                    if (widget.onContinue != null && available > 0)
                      UtenButton(
                        key: const Key('bom-issues-continue'),
                        size: UtenButtonSize.small,
                        onPressed: widget.busy ? null : widget.onContinue,
                        child: Text(l10n.materialBomIssueContinue(available)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
