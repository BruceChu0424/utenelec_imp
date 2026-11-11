param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
  [string]$RunName = (Get-Date -Format 'yyyyMMdd-HHmmss'),
  [ValidateSet('all', 'test', 'analyze')][string]$Phase = 'all'
)
$ErrorActionPreference = 'Stop'
$runner = Join-Path $WorkspaceRoot 'evidence/output-writes/private_flutter.py'
$tests = @(
  'test/features/basic_data/widgets/master_entity_inline_edit_test.dart',
  'test/features/basic_data/widgets/master_entity_lifecycle_authority_test.dart',
  'test/features/basic_data/widgets/master_entity_detail_pane_test.dart',
  'test/features/basic_data/pages/master_complete_print_consumers_test.dart',
  'test/features/basic_data/pages/color_inline_edit_test.dart',
  'test/features/basic_data/pages/settlement_method_filter_race_test.dart',
  'test/features/basic_data/pages/warehouse_page_single_main_test.dart',
  'test/shared/export/report_export_job_waiting_test.dart',
  'test/shared/paging/complete_output_guard_test.dart',
  'test/components/uten_export_button_permission_test.dart',
  'test/components/uten_export_complete_scope_test.dart',
  'test/shared/export/report_export_jobs_test.dart',
  'test/shared/export/report_export_precision_test.dart',
  'test/shared/paging/scoped_paged_read_view_mixin_test.dart',
  'test/features/basic_data/pages/settlement_method_paging_test.dart',
  'test/features/basic_data/pages/settlement_method_layout_parity_test.dart',
  'test/features/basic_data/pages/master_inline_create_pages_test.dart',
  'test/features/basic_data/pages/account_workspace_batch_test.dart',
  'test/features/basic_data/pages/product_category_page_paste_test.dart',
  'test/features/basic_data/pages/product_category_detail_return_test.dart',
  'test/features/basic_data/pages/client_category_page_refresh_test.dart',
  'test/features/basic_data/pages/unit_inline_busy_once_test.dart',
  'test/features/basic_data/pages/supplier_loss_navigation_test.dart',
  'test/features/basic_data/pages/product_category_page_column_permissions_test.dart',
  'test/features/basic_data/pages/unit_page_simple_fields_test.dart',
  'test/features/basic_data/pages/warehouse_page_layout_test.dart'
)
$sources = @(
  'lib/components/buttons/uten_export_button.dart',
  'lib/shared/paging/complete_output_guard.dart',
  'lib/shared/paging/complete_output_view_mixin.dart',
  'lib/shared/paging/scoped_paged_read_view_mixin.dart',
  'lib/shared/export/report_export_job_dialog.dart',
  'lib/features/basic_data/pages/account_workspace_page.dart',
  'lib/features/basic_data/pages/client_category_page.dart',
  'lib/features/basic_data/pages/color_page.dart',
  'lib/features/basic_data/pages/currency_page.dart',
  'lib/features/basic_data/pages/mould_category_page.dart',
  'lib/features/basic_data/pages/product_category_page.dart',
  'lib/features/basic_data/pages/settlement_method_page.dart',
  'lib/features/basic_data/pages/supplier_category_page.dart',
  'lib/features/basic_data/pages/unit_page.dart',
  'lib/features/basic_data/pages/warehouse_page.dart',
  'lib/features/basic_data/widgets/master_entity_detail_pane.dart',
  'lib/features/basic_data/widgets/master_inline_page_mixin.dart',
  'test/shared/paging/complete_output_guard_test.dart',
  'test/shared/export/report_export_job_waiting_test.dart',
  'test/features/basic_data/pages/master_complete_print_consumers_test.dart'
)
Push-Location $WorkspaceRoot
try {
  if ($Phase -in @('all', 'test')) {
    & python -X utf8 $runner "integrated-$RunName-test" test --no-pub --reporter=expanded --timeout=45s @tests
    if ($LASTEXITCODE -ne 0) { throw "Flutter regression failed: $LASTEXITCODE; original log retained" }
  }
  if ($Phase -in @('all', 'analyze')) {
    & python -X utf8 $runner "integrated-$RunName-analyze" analyze --no-pub @sources
    if ($LASTEXITCODE -ne 0) { throw "Flutter analysis failed: $LASTEXITCODE; original log retained" }
  }
} finally {
  Pop-Location
}
