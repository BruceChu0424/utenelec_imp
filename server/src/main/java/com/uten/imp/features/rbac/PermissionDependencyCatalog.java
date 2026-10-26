package com.uten.imp.features.rbac;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

/**
 * Explicit permission combinations already required by the application.
 * Grant-time navigation reads never become an additional API authorization condition.
 */
public final class PermissionDependencyCatalog {
    private final Map<String, List<List<String>>> grantRequirements;
    private final Map<String, List<List<String>>> hardRequirements;
    private final String rulesJson;

    public PermissionDependencyCatalog(Collection<Permission> permissions) {
        Map<String, Permission> catalog = new LinkedHashMap<>();
        permissions.stream().filter(permission -> permission.getCode() != null)
                .forEach(permission -> catalog.put(permission.getCode(), permission));
        Map<String, List<List<String>>> hard = new LinkedHashMap<>();
        // These are existing controller/service AND conditions, not naming conventions.
        actions(hard, catalog, "finance_order_approval", "approve", "reject");
        actions(hard, catalog, "sales_order_finance", "confirm");
        actions(hard, catalog, "sales_quote_finance", "confirm", "reject", "reverse");
        actions(hard, catalog, "sales_shipment_finance", "approve", "reject");
        actions(hard, catalog, "production_quality_inspection", "approve");
        actions(hard, catalog, "website", "content_edit", "product_edit", "media_manage", "publish", "rollback");
        actions(hard, catalog, "company_file", "download", "upload", "create", "edit", "move", "delete", "restore", "manage_permissions");
        add(hard, catalog, "company_file:upload", "attachment:view");
        add(hard, catalog, "company_file:upload", "attachment:upload");
        add(hard, catalog, "company_file:download", "attachment:view");
        add(hard, catalog, "company_file:download", "attachment:download");
        add(hard, catalog, "goods:price_analysis:view", "goods:view");
        add(hard, catalog, "goods:purchase:edit", "goods:view");
        add(hard, catalog, "goods:sales:edit", "goods:view");
        add(hard, catalog, "production_material_analysis:forward_rd", "production_material_analysis:view");
        // Import preview legitimately edits cost inputs without general goods browsing.
        add(hard, catalog, "goods:cost:edit", "goods:cost:view");
        for (String operation : List.of("confirm", "export", "template")) {
            add(hard, catalog, "goods:cost:" + operation, "goods:view");
            add(hard, catalog, "goods:cost:" + operation, "goods:cost:view");
        }
        // The return can be handled from either the warehouse workbench or the financial case.
        // Preserve a read already held; otherwise prefer the warehouse task, without granting
        // financial amounts, all-owner scope or any additional write authority.
        either(hard, catalog, "procurement_iqc_rejection:record_return",
                List.of("warehouse_iqc_return:view", "procurement_iqc_rejection:view"));
        hardRequirements = Map.copyOf(hard);

        Map<String, List<List<String>>> navigation = navigationRequirements(catalog);
        hard.forEach((code, groups) -> groups.forEach(group -> {
            List<List<String>> existing = navigation.computeIfAbsent(code, ignored -> new ArrayList<>());
            if (!existing.contains(group)) existing.add(group);
        }));
        grantRequirements = Map.copyOf(navigation);
        try {
            rulesJson = new ObjectMapper().writeValueAsString(hardRequirements);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Cannot serialize permission dependencies", exception);
        }
    }

    /** Checked page entry points only: new catalog codes do not silently inherit a rule. */
    private static Map<String, List<List<String>>> navigationRequirements(Map<String, Permission> catalog) {
        Map<String, List<List<String>>> rules = new LinkedHashMap<>();
        actions(rules, catalog, "goods", "create", "edit", "delete", "status", "export", "import");
        actions(rules, catalog, "client", "create", "edit", "delete", "status", "export", "assign");
        actions(rules, catalog, "supplier", "create", "edit", "delete", "status", "export");
        actions(rules, catalog, "mould", "create", "edit", "delete", "status", "export");
        for (String resource : List.of("material_category", "client_category", "supplier_category",
                "mould_category", "color", "unit", "currency", "warehouse")) {
            actions(rules, catalog, resource, "create", "edit", "delete", "move", "export");
        }
        actions(rules, catalog, "employee", "edit", "offboard");
        actions(rules, catalog, "department", "create", "edit", "delete", "move", "manager_assign");
        actions(rules, catalog, "account", "create", "edit", "delete", "status", "export");
        actions(rules, catalog, "sales_quote", "create", "edit", "delete", "export", "reverse", "convert");
        actions(rules, catalog, "sales_order", "create", "edit", "delete", "approve", "reverse", "stop",
                "change_qty", "cancel", "change_planned", "confirm_partial_shipment", "priority", "reallocate");
        actions(rules, catalog, "sales_shipment", "create", "edit", "delete", "approve", "reverse", "reject");
        actions(rules, catalog, "sales_other_shipment", "create", "edit", "delete", "approve", "reverse");
        actions(rules, catalog, "sales_return", "create", "edit", "delete", "approve", "reverse", "disposition");
        actions(rules, catalog, "sales_return_quality", "correct", "dispose");
        actions(rules, catalog, "purchase_order", "create", "edit", "delete", "cancel", "reverse",
                "decompose", "change_qty", "submit_finance");
        actions(rules, catalog, "subcontract_order", "create", "edit", "delete", "reverse", "decompose",
                "change_qty", "submit_finance", "draw");
        for (String resource : List.of("purchase_receipt", "purchase_return", "subcontract_inquiry",
                "subcontract_receipt", "subcontract_return", "subcontract_material_issue",
                "subcontract_material_return", "subcontract_waste")) {
            actions(rules, catalog, resource, "create", "edit", "delete", "approve", "reverse");
        }
        actions(rules, catalog, "stock_doc", "create", "edit", "delete", "approve", "reverse", "issue", "reverse_issue");
        actions(rules, catalog, "warehouse_inbound", "stock_in");
        actions(rules, catalog, "warehouse_iqc_stock_in", "confirm", "before_inspection");
        actions(rules, catalog, "warehouse_sales_outbound", "execute");
        actions(rules, catalog, "subcontract_outbound", "execute");
        actions(rules, catalog, "procurement_inspection", "handle");
        actions(rules, catalog, "supplier_return_task", "complete");
        actions(rules, catalog, "production_plan", "create", "edit", "delete", "approve", "reverse", "flags");
        actions(rules, catalog, "production_execution", "assign", "release_defer", "dispatch", "start",
                "request_material_increment", "request_overproduction_rate", "request_supplement_plan");
        actions(rules, catalog, "production_daily_report", "create", "edit", "delete", "approve", "reverse");
        actions(rules, catalog, "production_material_analysis", "create", "refresh", "cancel", "route", "notify",
                "generate", "reallocate", "cross_reallocate", "over_supply", "claim_shared_future", "forward_rd");
        actions(rules, catalog, "production_fqc_replenishment", "confirm");
        for (String resource : List.of("finance_receipt", "finance_payment", "finance_expense",
                "finance_other_income", "finance_bank_transfer")) {
            actions(rules, catalog, resource, "create", "edit", "delete", "approve", "reverse");
        }
        actions(rules, catalog, "finance_expense", "gl_confirm");
        actions(rules, catalog, "finance_asset", "create", "edit", "delete", "approve", "post", "reverse", "dispose");
        actions(rules, catalog, "sales_shipment_finance", "reverse");
        actions(rules, catalog, "supplier_settlement", "create", "confirm", "dispute", "reverse");
        actions(rules, catalog, "subcontract_loss_claim", "review", "fulfill", "reverse");
        for (String resource : List.of("sales_report", "purchase_report", "subcontract_report", "stock_report",
                "production_report", "finance_report")) actions(rules, catalog, resource, "export");
        for (String operation : List.of("create", "edit", "delete", "audit")) {
            add(rules, catalog, "goods:bom:" + operation, "goods:view");
        }
        add(rules, catalog, "goods:import:undo", "goods:view");
        add(rules, catalog, "goods:create", "material_category:view");
        add(rules, catalog, "goods:bom:create", "material_category:view");
        add(rules, catalog, "client:create", "client_category:view");
        add(rules, catalog, "supplier:create", "supplier_category:view");
        add(rules, catalog, "mould:create", "mould_category:view");
        add(rules, catalog, "employee:create", "department:view");
        add(rules, catalog, "employee:edit", "department:view");
        add(rules, catalog, "goods:purchase:edit", "supplier:view");
        add(rules, catalog, "goods:sales:edit", "client:view");
        // These reads belong to specific pages/previews. The same action also has
        // legal consumers that do not require them, so they cannot prune authority.
        add(rules, catalog, "purchase_order:decompose", "purchase_request:view");
        add(rules, catalog, "subcontract_order:decompose", "subcontract_application:view");
        add(rules, catalog, "account:balance:adjust", "account:view");
        add(rules, catalog, "account:balance:adjust", "account:balance:view");
        add(rules, catalog, "goods:cost:edit", "goods:view");
        add(rules, catalog, "sales_quote:convert", "sales_order:view");
        add(rules, catalog, "finance_asset_period:manage", "finance_asset:view");
        add(rules, catalog, "visitor:check_in", "visitor:verify");
        return rules;
    }

    private static void actions(Map<String, List<List<String>>> rules, Map<String, Permission> catalog,
            String resource, String... operations) {
        for (String operation : operations) add(rules, catalog, resource + ":" + operation, resource + ":view");
    }

    private static void add(Map<String, List<List<String>>> rules, Map<String, Permission> catalog,
            String code, String required) {
        if (code.equals(required) || !catalog.containsKey(code) || !catalog.containsKey(required)) return;
        List<String> group = List.of(required);
        List<List<String>> existing = rules.computeIfAbsent(code, ignored -> new ArrayList<>());
        if (!existing.contains(group)) existing.add(group);
    }

    private static void either(Map<String, List<List<String>>> rules, Map<String, Permission> catalog,
            String code, List<String> choices) {
        if (!catalog.containsKey(code)) return;
        List<String> existing = choices.stream().filter(catalog::containsKey).toList();
        if (existing.isEmpty()) return;
        List<List<String>> groups = new ArrayList<>();
        groups.add(existing);
        rules.put(code, groups);
    }

    /** Grant-time completion of checked navigation reads and existing hard read conditions. */
    public List<String> requiredPermissions(String code, Collection<String> held) {
        return requiredPermissions(code, held, ignored -> false);
    }

    public List<String> requiredPermissions(String code, Collection<String> held,
            Predicate<String> preferredWhenMissing) {
        return required(grantRequirements, code, held, preferredWhenMissing);
    }

    /** Universal read conditions only; page/navigation conveniences are excluded. */
    public List<String> hardRequiredPermissions(String code, Collection<String> held) {
        return hardRequiredPermissions(code, held, ignored -> false);
    }

    /** Prefer a legally grantable missing OR alternative, while preserving reads already held. */
    public List<String> hardRequiredPermissions(String code, Collection<String> held,
            Predicate<String> preferredWhenMissing) {
        return required(hardRequirements, code, held, preferredWhenMissing);
    }

    public List<String> missingHardDependencies(String code, Collection<String> held) {
        return missingHardDependencies(code, held, ignored -> false);
    }

    public List<String> missingHardDependencies(String code, Collection<String> held,
            Predicate<String> preferredWhenMissing) {
        Set<String> owned = Set.copyOf(held);
        return hardRequiredPermissions(code, owned, preferredWhenMissing).stream()
                .filter(required -> !owned.contains(required)).toList();
    }

    private List<String> required(Map<String, List<List<String>>> rules, String code,
            Collection<String> held, Predicate<String> preferredWhenMissing) {
        LinkedHashSet<String> required = new LinkedHashSet<>();
        collect(rules, code, Set.copyOf(held), required, new LinkedHashSet<>(), preferredWhenMissing);
        return List.copyOf(required);
    }

    private void collect(Map<String, List<List<String>>> rules, String code, Set<String> held,
            Set<String> required, Set<String> visited, Predicate<String> preferredWhenMissing) {
        if (!visited.add(code)) return;
        for (List<String> alternatives : rules.getOrDefault(code, List.of())) {
            String selected = alternatives.stream().filter(held::contains).findFirst().orElseGet(() ->
                    alternatives.stream().filter(preferredWhenMissing).findFirst().orElse(alternatives.getFirst()));
            required.add(selected);
            collect(rules, selected, held, required, visited, preferredWhenMissing);
        }
    }

    public List<String> missingDependencies(String code, Collection<String> held) {
        return missingDependencies(code, held, ignored -> false);
    }

    public List<String> missingDependencies(String code, Collection<String> held,
            Predicate<String> preferredWhenMissing) {
        Set<String> owned = Set.copyOf(held);
        return requiredPermissions(code, owned, preferredWhenMissing).stream()
                .filter(required -> !owned.contains(required)).toList();
    }

    /** Only existing API/service conjunctions affect usable authority; navigation does not. */
    public Set<String> usablePermissions(Collection<String> configured) {
        Set<String> usable = new LinkedHashSet<>(configured);
        boolean changed;
        do {
            changed = usable.removeIf(code -> hardRequirements.getOrDefault(code, List.of()).stream()
                    .anyMatch(alternatives -> alternatives.stream().noneMatch(usable::contains)));
        } while (changed);
        return Set.copyOf(usable);
    }

    /** Include every read alternative in the same MVCC authority statement. */
    public Set<String> lookupPermissions(Collection<String> requested) {
        Set<String> result = new LinkedHashSet<>(requested);
        boolean changed;
        do {
            int before = result.size();
            for (String code : List.copyOf(result)) {
                hardRequirements.getOrDefault(code, List.of()).forEach(result::addAll);
            }
            changed = result.size() != before;
        } while (changed);
        return Set.copyOf(result);
    }

    /** Only existing hard read conditions, bound as JSON in the batch authority query. */
    public String rulesJson() { return rulesJson; }
}
