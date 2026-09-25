import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_material_discovery_request_repository.dart';

class ProductionMaterialDiscoveryRequestPage extends ConsumerStatefulWidget {
  const ProductionMaterialDiscoveryRequestPage({
    super.key,
    required this.tasks,
  });
  final List<ProductionExecutionWorkbenchSegment> tasks;
  @override
  ConsumerState<ProductionMaterialDiscoveryRequestPage> createState() =>
      _RequestState();
}

class _RequestState
    extends ConsumerState<ProductionMaterialDiscoveryRequestPage> {
  bool _saving = false;
  final _completed = <String>{};
  String? _error;
  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      for (final task in widget.tasks) {
        if (_completed.contains(task.segmentId)) continue;
        await ref
            .read(productionMaterialDiscoveryRequestRepositoryProvider)
            .request(
              task.segmentId,
              task.lockVersion,
              businessIdempotencyKey(
                'discovery-request',
                '${task.segmentId}:${task.lockVersion}',
              ),
            );
        _completed.add(task.segmentId);
      }
      if (!mounted) return;
      context.appSuccess(
        AppLocalizations.of(context).materialDiscoveryRequestSent,
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        context.appApiError(e);
        setState(
          () => _error =
              e is ApiException && e.httpStatus != null && e.httpStatus! < 500
              ? e.message
              : AppLocalizations.of(context).materialDiscoveryUncertain,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.materialDiscoveryRequestTitle,
          showBackButton: true,
        ),
        body: SingleChildScrollView(
          child: UtenContentContainer(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.materialDiscoveryRequestHelp),
                  const SizedBox(height: 16),
                  for (final task in widget.tasks)
                    ListTile(
                      leading: Icon(
                        _completed.contains(task.segmentId)
                            ? Icons.check_circle_outline
                            : Icons.inventory_2_outlined,
                      ),
                      title: Text(
                        '${task.productCode ?? ''} ${task.productName ?? ''}',
                      ),
                      subtitle: Text(
                        '${task.planNo} · ${task.segmentCode} · ${task.workshopName ?? ''}',
                      ),
                      trailing: Text(
                        '${task.plannedQty} ${task.productUnitName ?? ''}',
                      ),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: UtenButton(
          key: const Key('discovery-request-submit'),
          type: UtenButtonType.danger,
          isLoading: _saving,
          onPressed: _submit,
          child: Text(l10n.materialDiscoverySend),
        ),
      ),
    );
  }
}
