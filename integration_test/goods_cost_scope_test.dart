// Exercise the real GoodsCostTab in a native Flutter window with the production
// ApiClient, read-scope interceptor and repository, using an offline HTTP fixture.
import 'package:integration_test/integration_test.dart';

import '../test/features/basic_data/widgets/goods_cost_startup_test.dart'
    as startup;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  startup.main();
}
