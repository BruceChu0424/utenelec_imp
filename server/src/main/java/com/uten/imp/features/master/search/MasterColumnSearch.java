package com.uten.imp.features.master.search;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.KeywordSearch;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import org.hibernate.query.criteria.HibernateCriteriaBuilder;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.ArrayList;

/** Display-text matching stays inside the owning service's authorized count/page
 * query. SQL structure is server-owned; every user term is a Criteria value bind. */
public final class MasterColumnSearch {
    public enum Domain { GOODS, CLIENT, SUPPLIER, MOULD }
    private MasterColumnSearch() { }

    public static Predicate predicate(CriteriaBuilder cb, Expression<?> recordId,
                                      Domain domain, Map<String, String> searches) {
        Map<String, String> fields = fields(domain);
        var terms = ColumnKeywordSearch.validate(searches, fields.keySet());
        if (terms.isEmpty()) return cb.conjunction();
        if (!(cb instanceof HibernateCriteriaBuilder hibernate)) {
            throw new IllegalStateException("Column keyword search requires the configured Hibernate Criteria provider");
        }
        String table = switch (domain) {
            case GOODS -> "goods"; case CLIENT -> "clients";
            case SUPPLIER -> "suppliers"; case MOULD -> "moulds";
        };
        StringBuilder sql = new StringBuilder("(? IN (SELECT master.id FROM " + table + " master WHERE NOT master.is_deleted");
        List<Expression<?>> arguments = new ArrayList<>();
        arguments.add(recordId);
        for (var search : terms.entrySet()) {
            for (String term : KeywordSearch.terms(search.getValue())) {
                sql.append(" AND (").append(fields.get(search.getKey())).append(" ILIKE ? ESCAPE '\\')");
                arguments.add(hibernate.value(KeywordSearch.containsPattern(term)));
            }
        }
        sql.append("))");
        return cb.isTrue(hibernate.sql(sql.toString(), Boolean.class, arguments.toArray(Expression<?>[]::new)));
    }

    private static Map<String, String> fields(Domain domain) {
        Map<String, String> fields = new LinkedHashMap<>();
        switch (domain) {
            case GOODS -> {
                direct(fields, "name", "nameEn", "code", "series", "model", "spec", "cNumber", "rearInsertCode", "material", "requireRemark");
                fields.put("paper", "COALESCE(master.paper, master.require_remark)");
                fields.put("colorLegacyId", legacyReference("colors", "color_id", "color_legacy_id", "name", true));
                fields.put("colorName", fields.get("colorLegacyId"));
                fields.put("colorRef", fields.get("colorLegacyId"));
                fields.put("unitLegacyId", legacyReference("units", "unit_id", "unit_legacy_id", "name", true));
                fields.put("unitName", fields.get("unitLegacyId"));
                fields.put("unitRef", fields.get("unitLegacyId"));
                fields.put("mouldCode", legacyReference("moulds", "mould_id", "mould_legacy_id", "code", false));
                fields.put("mouldName", legacyReference("moulds", "mould_id", "mould_legacy_id", "name", false));
                fields.put("owningWarehouse", "(SELECT name FROM warehouses WHERE id = master.owning_warehouse_id AND NOT is_deleted)");
                fields.put("owningWarehouseName", fields.get("owningWarehouse"));
                fields.put("owningWorkshop", "(SELECT name FROM departments WHERE id = master.owning_workshop_department_id AND NOT is_deleted)");
                fields.put("owningWorkshopName", fields.get("owningWorkshop"));
            }
            case CLIENT -> {
                direct(fields, "code", "name", "nameEn", "fullName", "region", "placeId", "legalPerson", "linkman", "mobile", "phone", "phone2", "fax", "postcode", "address", "bank", "bankAccount", "taxId", "website");
                fields.put("defaultSettlementMethodName", "(SELECT name FROM settlement_methods WHERE id = master.default_settlement_method_id)");
                owner(fields);
                String customerOwners = "COALESCE((SELECT string_agg(employee.full_name, '、' ORDER BY responsibility.sort_order, employee.id) "
                        + "FROM (SELECT master.owner_employee_id AS employee_id, 0 AS sort_order UNION ALL "
                        + "SELECT co_owner.employee_id, co_owner.sort_order FROM client_co_owners co_owner WHERE co_owner.client_id=master.id) responsibility "
                        + "JOIN employees employee ON employee.id=responsibility.employee_id), " + fields.get("ownerEmployeeName") + ")";
                fields.put("ownerEmployeeName", customerOwners);
                fields.put("ownerEmployeeId", customerOwners);
                fields.put("empId", customerOwners);
            }
            case SUPPLIER -> {
                direct(fields, "code", "name", "description", "place", "legalPerson", "linkman", "mobile", "phone", "phone2", "fax", "postcode", "address", "bank", "bankAccount", "taxId", "website", "shipVia", "shipAddress");
                owner(fields);
            }
            case MOULD -> {
                direct(fields, "code", "name", "place", "manufacturer", "remark", "qty");
                fields.put("categoryName", "(SELECT name FROM mould_categories WHERE id = master.category_id AND NOT is_deleted)");
            }
        }
        return fields;
    }

    private static void direct(Map<String, String> fields, String... names) {
        for (String name : names) fields.put(name, "master." + name.replaceAll("([a-z])([A-Z])", "$1_$2").toLowerCase(java.util.Locale.ROOT));
    }

    private static void owner(Map<String, String> fields) {
        String name = "COALESCE((SELECT full_name FROM employees WHERE id = master.owner_employee_id), "
                + "(SELECT employee.full_name FROM users account JOIN employees employee ON employee.id = account.employee_id WHERE account.id = master.owner_employee_id), '未分配')";
        fields.put("ownerEmployeeId", name);
        fields.put("ownerEmployeeName", name);
        fields.put("empId", name);
    }

    private static String legacyReference(String table, String idColumn, String legacyColumn, String label, boolean fallbackId) {
        String name = "CASE WHEN master." + idColumn + " IS NOT NULL THEN (SELECT " + label + " FROM " + table
                + " WHERE id = master." + idColumn + " AND NOT is_deleted) ELSE (SELECT " + label + " FROM " + table
                + " WHERE legacy_id = master." + legacyColumn + " AND NOT is_deleted ORDER BY id LIMIT 1) END";
        return fallbackId ? "COALESCE((" + name + "), CASE WHEN master." + legacyColumn
                + " <> 0 THEN '#' || CAST(master." + legacyColumn + " AS text) END)" : "(" + name + ")";
    }
}
