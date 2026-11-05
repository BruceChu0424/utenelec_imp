// Exercise the production pages and router on a native Flutter surface using
// isolated API fixtures. This never connects to the company service.
import 'package:integration_test/integration_test.dart';

import '../test/features/production/pages/production_material_analysis_page_test.dart'
    as material_analysis;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  material_analysis.registerMaterialAnalysisCancelReentryTests();
}
