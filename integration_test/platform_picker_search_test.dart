// Reuse the production picker interaction scenarios in a real native Flutter window.
import 'package:integration_test/integration_test.dart';

import '../test/features/basic_data/widgets/uten_client_picker_test.dart'
    as picker;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  picker.main();
}
