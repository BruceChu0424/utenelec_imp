import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/components/uten_editable_grid_hscrollbar_test.dart' as grid;
import '../test/master_data_table_view_hscrollbar_test.dart' as table;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('shared-pointer-table', table.main);
  group('shared-pointer-grid', grid.main);
}
