import 'package:integration_test/integration_test.dart';

import '../test/components/inputs/uten_employee_organization_read_test.dart'
    as organization;
import '../test/features/basic_data/widgets/uten_goods_picker_test.dart'
    as goods;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  organization.main();
  goods.main();
}
