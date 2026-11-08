package com.uten.imp.common.history;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.HeaderColumnFilter;
import jakarta.persistence.Table;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.lang.reflect.RecordComponent;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Set;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/** One origin contract for business lists; master records and physical stock are not documents.
 * Reads classify provenance through the V1120 registry of imported rows (one indexed lookup);
 * write guards and command checks keep the authoritative V926/V933 graph walk. */
public final class ImportedBusinessDocumentScope {
    public enum Origin { CURRENT, LEGACY, ALL }
    // Server-owned physical source contracts, verified against the migrated schema.
    // A direct legacy key is a cheap necessary condition; the registry carries every
    // imported row, including provenance-only and inherited imports.
    private static final Set<String> NATIVE_TABLES = Set.of(
            "plan_order_item_links", "procurement_order_approval_cases", "procurement_order_qty_change_logs",
            "production_daily_report_items", "production_daily_reports", "production_plan_items", "production_plans",
            "purchase_order_items", "purchase_orders", "purchase_receipt_items", "purchase_receipts",
            "purchase_request_items", "purchase_requests", "sales_order_items", "sales_orders", "sales_quotes",
            "sales_shipment_items", "sales_shipments", "stock_document_items", "stock_documents",
            "subcontract_application_items", "subcontract_applications", "subcontract_material_issue_items",
            "subcontract_material_issues", "subcontract_order_items", "subcontract_orders",
            "subcontract_receipt_items", "subcontract_receipts", "subcontract_return_items", "subcontract_returns",
            "subcontract_waste_items", "subcontract_wastes");
    private static final Set<String> WITHOUT_LEGACY_KEY = Set.of(
            "plan_order_item_links", "procurement_order_approval_cases", "procurement_order_qty_change_logs");
    private static final Set<String> WITH_IMPORT_RUN = Set.of(
            "purchase_receipt_items", "purchase_receipts", "subcontract_orders",
            "subcontract_receipt_items", "subcontract_receipts");
    private static final Set<String> LIFECYCLE_FILTERS = Set.of(
            "status", "sourceStatus", "closed", "stopped", "financeApproval", "financeStatus", "lifecycle",
            "issueStatus", "standaloneDrafts", "productionReturnRequests", "financeConfirmed", "financeRejected");
    private ImportedBusinessDocumentScope() { }

    public static Origin origin() {
        var attributes = RequestContextHolder.getRequestAttributes();
        String value = attributes instanceof ServletRequestAttributes request
                ? request.getRequest().getParameter("originScope") : null;
        if (value == null || value.isBlank()) return Origin.CURRENT;
        try { return Origin.valueOf(value.strip().toUpperCase(Locale.ROOT)); }
        catch (IllegalArgumentException invalid) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据来源筛选须为 CURRENT、LEGACY 或 ALL");
        }
    }

    public static boolean legacyOnly() { return origin() == Origin.LEGACY; }

    /** The registry also recognizes provenance-only imports and imported parent ownership. */
    public static Predicate predicate(Root<?> root, CriteriaBuilder cb) {
        return predicate(root,cb,origin());
    }

    /** Explicit column origin uses the same provenance fact as the surrounding list scope. */
    public static Predicate predicate(Root<?> root,CriteriaBuilder cb,Origin origin) {
        if (origin == Origin.ALL) return cb.conjunction();
        var imported = imported(root, cb);
        if (origin == Origin.LEGACY) return cb.isTrue(imported);
        // Master legacy keys are identities, not imported business provenance.
        if (!ImportedBusinessDocumentPolicy.businessRecord(root.getJavaType())) return cb.isFalse(imported);
        var conditions = new java.util.ArrayList<Predicate>();
        for (Class<?> type = root.getJavaType(); type != null; type = type.getSuperclass()) {
            for (var field : type.getDeclaredFields()) {
                var column = field.getAnnotation(jakarta.persistence.Column.class);
                if (column != null && ("legacy_id".equals(column.name())
                        && Number.class.isAssignableFrom(field.getType())
                        || "legacy_import_run_id".equals(column.name()) && field.getType() == java.util.UUID.class)) {
                    conditions.add(cb.isNull(root.get(field.getName())));
                }
            }
        }
        var authority = cb.isFalse(imported);
        if (conditions.isEmpty()) return authority;
        conditions.add(authority);
        return cb.and(conditions.toArray(Predicate[]::new));
    }

    /** Same native-only source as the original JSON prefilter, with usable legacy
     * indexes and one shared SQL owner. The registry is the read-side materialization
     * of the authoritative verdict, not a cache that a caller may refresh. */
    public static String nativeTable(String table) {
        return "(SELECT * FROM " + table + " archive_origin WHERE " + nativePredicate(table,"archive_origin") + ")";
    }

    /** Correlated reads select their real relationship, then apply the same native predicate. */
    public static String nativeRowsByKey(String table,String keyColumn,String referenceAliasField) {
        String predicate=nativePredicate(table,"archive_origin");
        if(keyColumn==null || !keyColumn.matches("[a-zA-Z_][a-zA-Z0-9_]*") || !reference(referenceAliasField))
            throw new IllegalArgumentException("Invalid internal native relationship");
        return "LATERAL (SELECT archive_origin.* FROM "+table+" archive_origin WHERE archive_origin."+keyColumn
                +"="+referenceAliasField+" AND "+predicate+")";
    }

    /** Correlated/materialized sources use the same predicate after their exact
     * relationship has been selected; their existing query scope stays intact. */
    public static String nativePredicate(String table,String alias) {
        if (!NATIVE_TABLES.contains(table)) throw new IllegalArgumentException("Unsupported native business source");
        if (!alias.matches("[a-zA-Z_][a-zA-Z0-9_]*")) throw new IllegalArgumentException("Invalid internal SQL alias");
        String direct = WITHOUT_LEGACY_KEY.contains(table) ? "" : alias+".legacy_id IS NULL AND ";
        if (WITH_IMPORT_RUN.contains(table)) direct += alias+".legacy_import_run_id IS NULL AND ";
        return direct+"NOT "+registeredSql(table,alias+".id");
    }

    /** Imported verdict of one server-owned table row, e.g. {@code registeredSql("sales_orders","o.id")}. */
    public static String registeredSql(String table,String idReference) {
        if (table==null || !table.matches("[a-z][a-z0-9_]*") || !reference(idReference))
            throw new IllegalArgumentException("Invalid internal provenance reference");
        return "EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='"
                +table+"' AND archive_registry.row_id="+idReference+")";
    }

    /** Typed polymorphic sources resolve their relation through the same scope mapping as the
     * authority. The relation differs per row, so this stays a per-row registered lookup: a
     * set-based anti-join on a computed relation name would hash every registration. */
    public static String scopedRegisteredSql(String scopeReference,String idReference) {
        if (!reference(scopeReference) || !reference(idReference))
            throw new IllegalArgumentException("Invalid internal provenance reference");
        return "fn_imported_business_document_registered(fn_imported_business_document_scope_table("
                +scopeReference+"),"+idReference+")";
    }

    private static boolean reference(String value) {
        return value!=null && value.matches("[a-zA-Z_][a-zA-Z0-9_]*\\.[a-zA-Z_][a-zA-Z0-9_]*");
    }

    /** Action queues and source selectors never inherit a caller's historical-list scope. */
    public static Predicate nativeOnly(Root<?> root, CriteriaBuilder cb) { return predicate(root,cb,Origin.CURRENT); }

    /** Existing native-history segments must not hide source 0/-1 imports. */
    public static Predicate lifecycle(Root<?> root, CriteriaBuilder cb, Predicate nativeLifecycle) {
        return switch (origin()) {
            case CURRENT -> nativeLifecycle;
            case LEGACY -> cb.conjunction();
            case ALL -> cb.or(cb.isTrue(imported(root, cb)), nativeLifecycle);
        };
    }

    private static jakarta.persistence.criteria.Expression<Boolean> imported(Root<?> root, CriteriaBuilder cb) {
        Table table = root.getJavaType().getAnnotation(Table.class);
        if (table == null) throw new IllegalArgumentException("Business origin requires a mapped table");
        return cb.function("fn_imported_business_document_registered", Boolean.class, cb.literal(table.name()), root.get("id"));
    }

    /** Ignore automatic lifecycle segments in legacy history; explicit dates/search/ownership remain. */
    @SuppressWarnings("unchecked")
    public static <T> T historyFilter(T input) {
        if (input == null || origin() == Origin.CURRENT) return input;
        Class<?> type = input.getClass();
        if (!type.isRecord()) throw new IllegalArgumentException("Business history filter must be an immutable record");
        RecordComponent[] components = type.getRecordComponents();
        Object[] values = new Object[components.length];
        try {
            for (int index = 0; index < components.length; index++) {
                var component = components[index];
                Object value = component.getAccessor().invoke(input);
                if (LIFECYCLE_FILTERS.contains(component.getName())) {
                    value = component.getType() == boolean.class ? false : null;
                } else if (value instanceof HeaderColumnFilter headers) {
                    var retained = new LinkedHashMap<>(headers.values());
                    retained.remove("apPosted");
                    value = new HeaderColumnFilter(retained);
                }
                values[index] = value;
            }
            return (T) type.getDeclaredConstructor(Arrays.stream(components).map(RecordComponent::getType)
                    .toArray(Class<?>[]::new)).newInstance(values);
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Cannot preserve business history filter contract", failure);
        }
    }
}
