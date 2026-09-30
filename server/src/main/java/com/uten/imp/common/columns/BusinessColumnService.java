package com.uten.imp.common.columns;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.text.Normalizer;
import java.util.*;

@Service
@RequiredArgsConstructor
public class BusinessColumnService {
    private static final Set<String> SCOPES = Set.of("sales_quote", "sales_order", "purchase_order", "subcontract_order");
    private static final Set<String> TYPES = Set.of("TEXT", "NUMBER", "AMOUNT");
    private static final Set<String> OPERATIONS = Set.of("NONE", "ADD", "SUBTRACT", "MULTIPLY", "DIVIDE");
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper mapper;

    public record Definition(UUID id, String scope, String name, String type, String operation, long usageCount) { }
    public record Create(String scope, String name, String type, String operation) { }
    public record Capabilities(String scope, boolean arithmetic, int maxColumns) { }

    public Capabilities capabilities(String scope) {
        requireScope(scope);
        requirePermission(scope, false);
        return new Capabilities(scope, arithmetic(scope), 32);
    }

    @Transactional(readOnly = true)
    public List<Definition> search(String scope, String q) {
        requireScope(scope);
        requirePermission(scope, false);
        String needle = normalize(q == null ? "" : q);
        if (needle.length() > 80) throw invalid("列名搜索过长");
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT id, scope, name, value_type, operation, usage_count, created_by
                FROM business_column_definitions
                WHERE scope = :scope AND (:q = '' OR position(:q IN normalized_name) > 0
                    OR EXISTS (SELECT 1 FROM generate_series(1,length(CAST(:q AS text))-1) n
                        WHERE position(substring(CAST(:q AS text) from n for 2) IN normalized_name) > 0))
                ORDER BY CASE WHEN normalized_name = :q THEN 0
                              WHEN position(:q IN normalized_name) > 0 THEN 1 ELSE 2 END,
                         usage_count DESC, name, id LIMIT 500
                """).setParameter("scope", scope).setParameter("q", needle).getResultList();
        UUID actor = currentUser.id().orElse(null);
        return rank(rows.stream().map(r -> new Suggestion(definition(r),
                actor != null && actor.equals(r[6]))).toList(), needle);
    }

    record Suggestion(Definition definition, boolean createdByUser) { }

    /** Similarity suggests an existing definition; its type and operation always remain explicit. */
    static List<Definition> rank(List<Suggestion> suggestions, String needle) {
        Comparator<Suggestion> ranking = Comparator
                .comparingInt((Suggestion s) -> matchTier(normalize(s.definition().name()), needle))
                .thenComparing(Comparator.comparingDouble((Suggestion s) -> similarity(s.definition().name(), needle)).reversed())
                .thenComparing(Suggestion::createdByUser, Comparator.reverseOrder())
                .thenComparing(Comparator.comparingLong((Suggestion s) -> s.definition().usageCount()).reversed())
                .thenComparing(s -> s.definition().name()).thenComparing(s -> s.definition().id());
        return suggestions.stream().filter(s -> needle.isEmpty()
                        || normalize(s.definition().name()).contains(needle)
                        || similarity(s.definition().name(), needle) >= 0.4)
                .sorted(ranking).limit(50).map(Suggestion::definition).toList();
    }

    private static int matchTier(String name, String needle) {
        return name.equals(needle) ? 0 : name.contains(needle) ? 1 : 2;
    }
    private static double similarity(String name, String needle) {
        return com.uten.imp.common.text.IntakeTextNormalizer.bigramDice(normalize(name), needle);
    }

    /** Repeated identical definitions are one catalog entry, including concurrent creates. */
    @Transactional
    public Definition create(Create input) {
        if (input == null) throw invalid("请填写列定义");
        requireScope(input.scope());
        requirePermission(input.scope(), true);
        String name = input.name() == null ? "" : input.name().strip();
        String normalized = normalize(name);
        String type = input.type() == null ? "TEXT" : input.type();
        String operation = input.operation() == null ? "NONE" : input.operation();
        if (normalized.isBlank() || name.length() > 80 || name.chars().anyMatch(Character::isISOControl)) {
            throw invalid("列名称需为 1 至 80 个可见字符");
        }
        if (!TYPES.contains(type) || !OPERATIONS.contains(operation)
                || ("TEXT".equals(type) && !"NONE".equals(operation))) throw invalid("扩展列类型或运算无效");
        if (!"NONE".equals(operation)) {
            if (!arithmetic(input.scope())) throw invalid("当前单据只支持记录信息，费用运算尚未开放");
        }
        if (!"NONE".equals(operation) || "AMOUNT".equals(type)) requirePricePermission(input.scope());
        em.createNativeQuery("""
                INSERT INTO business_column_definitions(id, scope, name, normalized_name, value_type, operation, created_by)
                VALUES (:id, :scope, :name, :normalized, :type, :operation, :actor)
                ON CONFLICT(scope, normalized_name, value_type, operation) DO NOTHING
                """).setParameter("id", UUID.randomUUID()).setParameter("scope", input.scope())
                .setParameter("name", name).setParameter("normalized", normalized)
                .setParameter("type", type).setParameter("operation", operation)
                .setParameter("actor", currentUser.requireId()).executeUpdate();
        Object[] row = (Object[]) em.createNativeQuery("""
                SELECT id, scope, name, value_type, operation, usage_count
                FROM business_column_definitions
                WHERE scope=:scope AND normalized_name=:name AND value_type=:type AND operation=:operation
                """).setParameter("scope", input.scope()).setParameter("name", normalized)
                .setParameter("type", type).setParameter("operation", operation).getSingleResult();
        return definition(row);
    }

    /** All definitions are authoritative; values only become document terms after validation. */
    public static List<ExtraColumnSnapshot> resolveForSave(BusinessColumnService service, String scope,
            List<ExtraColumnInput> requested, List<ExtraColumnSnapshot> stored, boolean priceMasked) {
        if (requested == null) return stored == null ? List.of() : List.copyOf(stored);
        if (requested.isEmpty() && (stored == null || stored.isEmpty())) return List.of();
        return Objects.requireNonNull(service, "Business-column service must be configured").resolve(scope, requested, stored, priceMasked);
    }

    public List<ExtraColumnSnapshot> resolve(String scope, List<ExtraColumnInput> requested,
                                              List<ExtraColumnSnapshot> stored, boolean priceMasked) {
        requireScope(scope);
        List<ExtraColumnSnapshot> previous = stored == null ? List.of() : stored;
        if (requested == null) return List.copyOf(previous);
        if (requested.size() > 32) throw invalid("最多添加 32 个扩展列");
        Set<UUID> seen = new HashSet<>();
        for (ExtraColumnInput input : requested) {
            if (input == null || input.columnId() == null || !seen.add(input.columnId())) {
                throw invalid("扩展列编号为空或重复");
            }
        }
        Map<UUID, ExtraColumnSnapshot> old = new HashMap<>();
        previous.forEach(v -> old.put(v.columnId(), v));
        Map<UUID, Definition> definitions = new HashMap<>();
        if (!seen.isEmpty()) {
            @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                    SELECT id, scope, name, value_type, operation, usage_count
                    FROM business_column_definitions WHERE id IN (:ids)
                    """).setParameter("ids", seen).getResultList();
            rows.stream().map(BusinessColumnService::definition).forEach(d -> definitions.put(d.id(), d));
        }
        List<ExtraColumnSnapshot> out = new ArrayList<>();
        for (ExtraColumnInput input : requested) {
            Definition d = definitions.get(input.columnId());
            // Quotation terms keep their identity when converted into an order.
            boolean quoteTerm = "sales_order".equals(scope) && d != null && "sales_quote".equals(d.scope());
            if (d == null || (!scope.equals(d.scope()) && !quoteTerm)) throw invalid("扩展列不存在或不属于此单据类型");
            ExtraColumnSnapshot prior = old.get(input.columnId());
            ExtraColumnSnapshot snapshot = prior == null
                    ? new ExtraColumnSnapshot(d.id(), d.name(), d.type(), d.operation(), null) : prior;
            String value = input.value() == null || input.value().isBlank() ? null : input.value().strip();
            if (value != null && value.length() > 2000) throw invalid(d.name() + "不能超过 2000 字符");
            if (priceMasked && snapshot.financial()) {
                if (prior == null || value != null) throw forbidden("没有价格权限，不能添加或修改费用列");
                out.add(prior);
                continue;
            }
            if (!"TEXT".equals(snapshot.type()) && value != null) {
                value = ExtraColumnCalculator.decimal(value, d.name()).toPlainString();
                if ("DIVIDE".equals(snapshot.operation()) && new java.math.BigDecimal(value).signum() == 0)
                    throw invalid(d.name() + "不能除以 0");
            }
            out.add(new ExtraColumnSnapshot(snapshot.columnId(), snapshot.name(), snapshot.type(), snapshot.operation(), value));
        }
        if (priceMasked) {
            List<UUID> oldFinancial = previous.stream().filter(ExtraColumnSnapshot::financial).map(ExtraColumnSnapshot::columnId).toList();
            List<UUID> newFinancial = out.stream().filter(ExtraColumnSnapshot::financial).map(ExtraColumnSnapshot::columnId).toList();
            if (!oldFinancial.equals(newFinancial)) throw forbidden("没有价格权限，不能删除或调整费用列顺序");
        }
        if (!seen.isEmpty()) em.createNativeQuery("""
                UPDATE business_column_definitions SET usage_count=usage_count+1, last_used_at=now() WHERE id IN (:ids)
                """).setParameter("ids", seen).executeUpdate();
        return List.copyOf(out);
    }

    public static List<ExtraColumnSnapshot> visible(List<ExtraColumnSnapshot> columns, boolean masked) {
        if (columns == null) return List.of();
        return masked ? columns.stream().map(ExtraColumnSnapshot::masked).toList() : List.copyOf(columns);
    }

    public List<ExtraColumnSnapshot> parse(Object json) {
        if (json == null) return List.of();
        try { return mapper.readValue(json.toString(), new TypeReference<List<ExtraColumnSnapshot>>() { }); }
        catch (JsonProcessingException e) { throw new IllegalStateException("Invalid stored business columns", e); }
    }

    public static boolean arithmetic(String scope) { return SCOPES.contains(scope); }
    public static String normalize(String name) {
        return Normalizer.normalize(name, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).replaceAll("[\\s\\p{Punct}]+", "");
    }
    private static Definition definition(Object[] r) {
        return new Definition((UUID) r[0], (String) r[1], (String) r[2], (String) r[3], (String) r[4], ((Number) r[5]).longValue());
    }
    private static void requireScope(String scope) {
        if (scope == null || !SCOPES.contains(scope)) throw invalid("不支持此单据类型");
    }
    private void requirePermission(String scope, boolean write) {
        boolean permitted = currentUser.get().map(user -> user.isSuperAdmin() || user.getPermissions().contains(scope + ":" + (write ? "edit" : "view"))
                || (write && user.getPermissions().contains(scope + ":create"))
                || (!write && (user.getPermissions().contains(scope + ":create")
                        || user.getPermissions().contains(scope + ":edit")
                        || user.getPermissions().contains("finance:view:all")))).orElse(false);
        if (!permitted) throw forbidden("没有此单据的" + (write ? "编辑" : "查看") + "权限");
    }
    private void requirePricePermission(String scope) {
        String priceScope = "sales_quote".equals(scope) ? "sales_order" : scope;
        boolean permitted = currentUser.get().map(user -> user.isSuperAdmin() || user.getPermissions().contains(priceScope + ":price:view")
                || ("sales_quote".equals(scope) && user.getPermissions().contains("sales_quote_finance:view"))
                || user.getPermissions().contains("finance:view:all")).orElse(false);
        if (!permitted) throw forbidden("没有此单据的价格权限");
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
    private static ApiException forbidden(String message) { return new ApiException(ErrorCode.FORBIDDEN, message); }
}
