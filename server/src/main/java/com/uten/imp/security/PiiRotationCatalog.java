package com.uten.imp.security;

import java.util.List;

/** Explicit pgcrypto fields; SQL identifiers never come from a maintenance request. */
final class PiiRotationCatalog {
    static final String VERSION = "pii-pgp-v1";
    record Target(String table, String keySql, String predicate, String payloadPrefix, List<String> columns) { }
    static final List<Target> TARGETS = List.of(
            new Target("employee_sensitive", "employee_id::text", "TRUE", "", List.of(
                    "id_card_enc", "phone_enc", "bank_account_enc", "bank_branch_enc", "huji_address_enc",
                    "residence_address_enc", "email_enc", "birth_date_enc", "marital_status_enc",
                    "political_status_enc", "office_phone_enc")),
            new Target("employee_compensation", "employee_id::text", "TRUE", "", List.of(
                    "base_salary_enc", "perf_salary_enc", "social_insurance_base_enc", "housing_fund_base_enc", "allowance_standard_enc")),
            new Target("emergency_contacts", "id::text", "TRUE", "", List.of("phone_enc")),
            new Target("employee_phones", "id::text", "TRUE", "", List.of("phone_enc")),
            new Target("visitor_accounts", "id::text", "TRUE", "", List.of("phone_enc")),
            new Target("visitor_applications", "id::text", "TRUE", "", List.of("phone_enc", "id_card_enc", "plate_no_enc")),
            new Target("profile_change_requests", "id::text", "value_encoding='PGCRYPTO_V1'",
                    "uten-profile-change-snapshot:v1:", List.of("old_value_enc", "new_value_enc")),
            new Target("employee_reconcile_plan_items", "plan_id::text || ':' || lpad(row_no::text,10,'0') || ':' || lpad(item_no::text,5,'0')",
                    "TRUE", "", List.of("old_value_enc", "new_value_enc", "candidates_enc")));
    private PiiRotationCatalog() { }
}
