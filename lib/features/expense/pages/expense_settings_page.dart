import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/expense_settings.dart';
import '../providers/expense_settings_provider.dart';

class ExpenseSettingsPage extends ConsumerStatefulWidget {
  const ExpenseSettingsPage({super.key});

  @override
  ConsumerState<ExpenseSettingsPage> createState() =>
      _ExpenseSettingsPageState();
}

class _ExpenseSettingsPageState extends ConsumerState<ExpenseSettingsPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _taxNo = TextEditingController();
  final _guide = TextEditingController();
  ExpenseSettings? _loaded;
  bool _requireInvoice = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _taxNo.dispose();
    _guide.dispose();
    super.dispose();
  }

  void _fill(ExpenseSettings settings) {
    if (_loaded != null) return;
    _loaded = settings;
    _name.text = settings.companyName;
    _taxNo.text = settings.companyTaxNo;
    _guide.text = settings.submissionGuide;
    _requireInvoice = settings.requireInvoice;
  }

  Future<void> _save() async {
    if (_saving ||
        _loaded == null ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await saveExpenseSettings(
        ref,
        ExpenseSettings(
          companyName: _name.text,
          companyTaxNo: _taxNo.text,
          submissionGuide: _guide.text,
          requireInvoice: _requireInvoice,
          version: _loaded!.version,
        ),
      );
      final refreshed = await ref.read(expenseSettingsProvider.future);
      if (!mounted) return;
      setState(() => _loaded = refreshed);
      context.appSuccess(AppLocalizations.of(context).expenseFlowSettingsSaved);
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canEdit = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.expenseSettings);
    final settings = ref.watch(expenseSettingsProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.expenseFlowSettingsTitle,
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.refresh,
            onPressed: _saving
                ? null
                : () {
                    _loaded = null;
                    ref.invalidate(expenseSettingsProvider);
                  },
            child: Text(l10n.commonRefresh),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: settings.when(
            loading: () =>
                const Center(child: CircularProgressIndicator.adaptive()),
            error: (_, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.expenseFlowSettingsLoadFailed),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenButton(
                    onPressed: () {
                      _loaded = null;
                      ref.invalidate(expenseSettingsProvider);
                    },
                    child: Text(l10n.expenseFlowRetry),
                  ),
                ],
              ),
            ),
            data: (value) {
              _fill(value);
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                children: [
                  UtenCard(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              l10n.expenseFlowSettingsDescription,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                            TextFormField(
                              errorBuilder: utenTextFieldErrorBuilder,
                              controller: _name,
                              enabled: canEdit && !_saving,
                              maxLength: 200,
                              decoration: UtenInputDecoration(
                                InputDecoration(
                                  labelText: l10n.expenseFlowCompanyName,
                                ),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? l10n.expenseFlowCompanyNameRequired
                                  : null,
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                            TextFormField(
                              errorBuilder: utenTextFieldErrorBuilder,
                              controller: _taxNo,
                              enabled: canEdit && !_saving,
                              maxLength: 20,
                              decoration: UtenInputDecoration(
                                InputDecoration(
                                  labelText: l10n.expenseFlowCompanyTaxNo,
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                            TextFormField(
                              errorBuilder: utenTextFieldErrorBuilder,
                              controller: _guide,
                              enabled: canEdit && !_saving,
                              maxLength: 2000,
                              minLines: 3,
                              maxLines: 8,
                              decoration: UtenInputDecoration(
                                InputDecoration(
                                  labelText: l10n.expenseFlowSubmissionGuide,
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(l10n.expenseFlowRequireInvoice),
                              subtitle: Text(
                                l10n.expenseFlowRequireInvoiceHint,
                              ),
                              value: _requireInvoice,
                              onChanged: canEdit && !_saving
                                  ? (value) =>
                                        setState(() => _requireInvoice = value)
                                  : null,
                            ),
                            if (canEdit) ...[
                              const SizedBox(height: UtenSpacing.s16),
                              UtenButton(
                                onPressed: _save,
                                isLoading: _saving,
                                child: Text(l10n.expenseFlowSettingsSave),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
