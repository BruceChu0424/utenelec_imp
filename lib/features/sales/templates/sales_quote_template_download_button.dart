import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import 'sales_quote_template.dart';
import 'sales_quote_template_repository.dart';

/// The detail action group must know whether this widget occupies an action slot.
/// Object/price scope is already represented by the authorized detail's mask;
/// the endpoint rechecks object permissions when the user actually exports.
bool canDownloadSalesQuoteTemplate(
  Set<String> permissions, {
  required bool priceMasked,
}) =>
    !priceMasked &&
    permissions.contains(Perm.salesQuoteView) &&
    permissions.contains(Perm.salesOrderPriceView) &&
    permissions.contains(Perm.salesQuoteExport);

/// Uses the same password, notification and download flow as other exports.
/// Template selection is a read; it never creates or changes customer data.
class SalesQuoteTemplateDownloadButton extends ConsumerWidget {
  const SalesQuoteTemplateDownloadButton({
    super.key,
    required this.quoteId,
    required this.billNo,
    required this.priceMasked,
  });

  final String quoteId;
  final String billNo;
  final bool priceMasked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    if (!canDownloadSalesQuoteTemplate(permissions, priceMasked: priceMasked)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return UtenExportButton(
      key: const ValueKey('sales-quote-template-download'),
      endpoint: '/sales/quotes/$quoteId/templates/export',
      report: 'quote',
      tableKey: 'sales.quote.items',
      queryParams: const {},
      filename: billNo,
      requiredPermission: Perm.salesQuoteExport,
      label: l10n.quoteTemplateDownload,
      type: UtenButtonType.secondary,
      size: UtenButtonSize.large,
      prepareExport: () async {
        final templates = await ref
            .read(salesQuoteTemplateRepositoryProvider)
            .listForQuote(quoteId);
        if (!context.mounted) return null;
        if (templates.isEmpty) {
          return const UtenExportSelection(
            bodyParams: {'templateIds': <String>[]},
          );
        }
        if (templates.length == 1) {
          return UtenExportSelection(
            bodyParams: {
              'templateIds': [templates.single.id],
            },
          );
        }
        return showDialog<UtenExportSelection>(
          context: context,
          builder: (_) => SalesQuoteTemplatePicker(templates: templates),
        );
      },
    );
  }
}

class SalesQuoteTemplatePicker extends StatefulWidget {
  const SalesQuoteTemplatePicker({super.key, required this.templates});
  final List<SalesQuoteTemplate> templates;

  @override
  State<SalesQuoteTemplatePicker> createState() =>
      _SalesQuoteTemplatePickerState();
}

class _SalesQuoteTemplatePickerState extends State<SalesQuoteTemplatePicker> {
  late final Set<String> _selected = {
    if (widget.templates.isNotEmpty) widget.templates.first.id,
  };

  void _finish({bool all = false, bool standard = false}) {
    final ids = standard
        ? <String>[]
        : widget.templates
              .where((template) => all || _selected.contains(template.id))
              .map((template) => template.id)
              .toList(growable: false);
    Navigator.of(context).pop(
      UtenExportSelection(
        bodyParams: {'templateIds': ids},
        extension: ids.length > 1 ? 'zip' : 'xlsx',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(l10n.quoteTemplateChoose),
      content: SizedBox(
        width: 480,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.55),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.quoteTemplateChooseHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.templates.length,
                  itemBuilder: (_, index) {
                    final template = widget.templates[index];
                    return CheckboxListTile(
                      key: ValueKey('quote-template-${template.id}'),
                      value: _selected.contains(template.id),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(template.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (template.sourceName?.trim().isNotEmpty ?? false)
                            Tooltip(
                              message: template.sourceName!,
                              child: Text(
                                template.sourceName!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          Text(
                            l10n.quoteTemplateVersionUsage(
                              template.version,
                              template.useCount,
                            ),
                          ),
                        ],
                      ),
                      onChanged: (selected) => setState(() {
                        if (selected == true) {
                          _selected.add(template.id);
                        } else {
                          _selected.remove(template.id);
                        }
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: Flexible(child: Text(l10n.commonCancel)),
        ),
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => _finish(standard: true),
          child: Flexible(child: Text(l10n.quoteTemplateStandard)),
        ),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => _finish(all: true),
          child: Flexible(child: Text(l10n.quoteTemplateDownloadAll)),
        ),
        UtenButton(
          onPressed: _selected.isEmpty ? null : _finish,
          child: Flexible(child: Text(l10n.quoteTemplateDownloadSelected)),
        ),
      ],
    );
  }
}
