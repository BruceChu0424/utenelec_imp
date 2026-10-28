package com.uten.imp.features.master.search;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NumericColumnFilter;
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
        var numeric = numericFields(domain);
        var allowed = new java.util.LinkedHashSet<>(fields.keySet());
        allowed.addAll(numeric.keySet());
        var terms = ColumnKeywordSearch.validate(searches, allowed);
        if (terms.isEmpty()) return cb.conjunction();
        var numbers = new LinkedHashMap<String,NumericColumnFilter>();
        terms.forEach((key,value) -> { if(numeric.containsKey(key)) numbers.put(key,NumericColumnFilter.parse(value)); });
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
            if(numeric.containsKey(search.getKey())) continue;
            for (String term : KeywordSearch.terms(search.getValue())) {
                sql.append(" AND (").append(fields.get(search.getKey())).append(" ILIKE ? ESCAPE '\\')");
                arguments.add(hibernate.value(KeywordSearch.containsPattern(term)));
            }
        }
        sql.append("))");
        Predicate text=cb.isTrue(hibernate.sql(sql.toString(), Boolean.class, arguments.toArray(Expression<?>[]::new)));
        if(numbers.isEmpty()) return text;
        var predicates=new ArrayList<Predicate>();predicates.add(text);
        numbers.forEach((key,value)->predicates.add(value.predicate(cb,numericValue(cb,recordId,domain,key))));
        return cb.and(predicates.toArray(Predicate[]::new));
    }

    /** Fixed display-grain numeric projection, also reused for derived-column ordering. */
    public static Expression<java.math.BigDecimal> numericValue(CriteriaBuilder cb,Expression<?> recordId,Domain domain,String key) {
        var expression=numericFields(domain).get(key);
        if(expression==null) throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"数值列不支持检索");
        if(!(cb instanceof HibernateCriteriaBuilder hibernate)) throw new IllegalStateException("Numeric master columns require Hibernate Criteria");
        if(domain==Domain.GOODS&&"stockQty".equals(key)) return hibernate.sql(
                "round("+com.uten.imp.features.master.goods.GoodsStockQuantities.TOTAL_FOR_ID+",2)",java.math.BigDecimal.class,recordId);
        String table=switch(domain) { case GOODS->"goods";case CLIENT->"clients";case SUPPLIER->"suppliers";case MOULD->"moulds"; };
        return hibernate.sql("(SELECT "+expression+" FROM "+table+" master WHERE master.id=?)",java.math.BigDecimal.class,recordId);
    }

    private static Map<String,String> numericFields(Domain domain) {
        return switch(domain) {
            case GOODS->Map.of("price","round(master.price,2)","discount","round(master.zk,2)",
                    "stockQty","stockQty", "minOrderQty","master.min_order_qty", "orderMultipleQty","master.order_multiple_qty");
            case CLIENT->Map.of("tday","master.tday::numeric","credit","round(master.credit,2)",
                    "creditFloor","round(coalesce(master.credit_floor,0),2)");
            case SUPPLIER->Map.of("tday","master.tday::numeric","lossRate",
                    "(SELECT supplier_loss.loss_pct FROM v_subcontract_supplier_loss_summary supplier_loss WHERE supplier_loss.supplier_id=master.id)");
            case MOULD->Map.of("tqty","master.tqty");
        };
    }

    private static Map<String, String> fields(Domain domain) {
        Map<String, String> fields = new LinkedHashMap<>();
        switch (domain) {
            case GOODS -> {
                direct(fields, "name", "nameEn", "clientGoodsName", "code", "series", "model", "spec", "cNumber", "rearInsertCode", "material", "requireRemark");
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
