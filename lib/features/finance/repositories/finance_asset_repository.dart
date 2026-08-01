// Compatibility entrypoint. The professional workbench contract lives in the
// strongly typed repository below; keep this export so older imports do not
// fork a second API implementation.
export '../models/finance_asset_models.dart';
export 'finance_asset_workbench_repository.dart';

import 'finance_asset_workbench_repository.dart';

typedef FinanceAssetRepository = ApiFinanceAssetWorkbenchRepository;

final financeAssetRepositoryProvider = financeAssetWorkbenchRepositoryProvider;
