import 'package:integration_test/integration_test.dart';

import '../test/table_single_view_contract_test.dart' as continuous;
import '../test/features/finance/supplier_credit_complete_read_test.dart'
    as credit;
import '../test/features/finance/finance_asset_workbench_page_test.dart'
    as assets;
import '../test/master_data_table_view_read_window_refresh_test.dart' as owners;
import '../test/features/production/delivery_processing_test.dart'
    as processing;
import '../test/features/applications/business_application_complete_list_test.dart'
    as applications;
import '../test/features/payroll/payroll_suggestion_responsive_detail_test.dart'
    as payroll;
import '../test/features/basic_data/pages/supplier_loss_navigation_test.dart'
    as supplier;
import '../test/features/production/pages/production_board_auxiliary_loading_test.dart'
    as progress;
import '../test/features/employee/employee_list_page_test.dart' as employees;
import '../test/features/basic_data/pages/master_record_history_page_test.dart'
    as history;
import '../test/features/finance/finance_complete_source_dialogs_test.dart'
    as finance_sources;
import '../test/features/finance/finance_native_legacy_opening_dialog_test.dart'
    as legacy_openings;
import '../test/features/finance/finance_material_statement_dialog_test.dart'
    as material_statements;
import '../test/features/finance/finance_payable_offset_test.dart'
    as payable_offsets;
import '../test/features/production/pages/production_workshop_tasks_return_refresh_test.dart'
    as workshop_returns;
import '../test/components/master_data_table_output_identity_test.dart'
    as output_identity;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  continuous.main();
  credit.main();
  assets.main();
  owners.main();
  processing.main();
  applications.main();
  payroll.main();
  supplier.main();
  progress.main();
  employees.main();
  history.main();
  finance_sources.main();
  legacy_openings.main();
  material_statements.main();
  payable_offsets.main();
  workshop_returns.main();
  output_identity.main();
}
