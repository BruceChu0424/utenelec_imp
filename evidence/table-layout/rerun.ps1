param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
  [string]$RunName = (Get-Date -Format 'yyyyMMdd-HHmmss')
)
$ErrorActionPreference = 'Stop'
$runner = Join-Path $WorkspaceRoot 'evidence/table-layout/private_flutter.py'
$tests = @(
  'test/master_data_table_view_platform_refresh_test.dart',
  'test/master_data_table_view_width_cache_test.dart',
  'test/master_data_table_view_rich_width_budget_test.dart',
  'test/master_data_table_view_input_auto_width_test.dart',
  'test/master_data_table_view_column_chooser_test.dart',
  'test/master_data_table_view_header_menu_test.dart',
  'test/master_data_table_view_column_search_test.dart',
  'test/master_data_table_view_drag_hide_test.dart',
  'test/master_data_table_view_required_leading_test.dart',
  'test/master_data_table_view_local_work_budget_test.dart',
  'test/master_data_table_view_cell_scope_test.dart',
  'test/features/basic_data/widgets/master_inline_resize_draft_test.dart',
  'test/shared/platform_tables/platform_table_widgets_test.dart',
  'test/shared/platform_tables/platform_table_display_preferences_test.dart',
  'test/shared/platform_tables/table_search_page_return_test.dart',
  'test/components/master_data_table_progressive_batch_actions_test.dart',
  'test/shared/platform_tables/platform_table_recovery_test.dart',
  'test/shared/platform_tables/platform_table_deletion_test.dart',
  'test/shared/platform_tables/platform_progressive_reads_test.dart'
)
Push-Location $WorkspaceRoot
try {
  & python -X utf8 $runner "integrated-$RunName-test" test --no-pub --reporter=expanded --timeout=45s @tests
  if ($LASTEXITCODE -ne 0) { throw "Table regression failed: $LASTEXITCODE; original log retained" }
  & python -X utf8 $runner "integrated-$RunName-analyze" analyze --no-pub lib/features/basic_data/widgets/master_data_table_view.dart test/master_data_table_view_platform_refresh_test.dart
  if ($LASTEXITCODE -ne 0) { throw "Table analysis failed: $LASTEXITCODE; original log retained" }
} finally {
  Pop-Location
}
