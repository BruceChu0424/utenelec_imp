import 'package:flutter/material.dart';

import '../../components/buttons/uten_back_button.dart';
import '../../components/feedback/uten_empty.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Retains the editor's navigation after its inputs lose their original owner.
class EditorIdentityNotice extends StatelessWidget {
  const EditorIdentityNotice({
    super.key,
    required this.title,
    required this.onBack,
    required this.documentChanged,
  });

  final String title;
  final VoidCallback onBack;
  final bool documentChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          key: const ValueKey('editor-identity-back'),
          tooltip: l10n.commonBack,
          onPressed: onBack,
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: UtenEmpty(
            icon: Icons.refresh_rounded,
            message: documentChanged
                ? l10n.editorDocumentIdentityChanged
                : l10n.editorSessionIdentityChanged,
          ),
        ),
      ),
    );
  }
}
