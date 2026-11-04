// Native Windows interaction against isolated fixture repositories. This does
// not connect to the company service or establish production/Win7 acceptance.
import 'package:integration_test/integration_test.dart';

import '../test/features/applications/business_application_edit_and_print_test.dart'
    as applications;
import '../test/features/applications/business_application_payment_recovery_test.dart'
    as payment;
import '../test/features/expense/expense_editable_items_test.dart' as items;
import '../test/features/expense/expense_workflow_visual_stress_test.dart'
    as expense_workflow;
import '../test/features/expense/expense_abandon_history_test.dart' as history;
import '../test/features/expense/expense_detail_route_review_test.dart'
    as expense_route;
import '../test/features/applications/business_application_route_review_test.dart'
    as application_route;
import '../test/features/applications/expense_application_editor_identity_test.dart'
    as editor_identity;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  applications.main();
  payment.main();
  items.main();
  expense_workflow.main();
  history.main();
  expense_route.main();
  application_route.main();
  editor_identity.main();
}
