package com.uten.imp.common.web;

import com.uten.imp.common.util.FinancialExactAmount;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Fixed header controls. The client never supplies a JPA property or SQL expression. */
public record HeaderColumnFilter(Map<String, String> values) {
    public static final HeaderColumnFilter EMPTY = new HeaderColumnFilter(Map.of());
    private static final Set<String> KEYS = Set.of("amountMin", "amountMax", "amountNull", "deliverFrom", "deliverTo",
            "apPosted", "weightMin", "weightMax", "weightNull", "recordOrigin");
    private static final Set<String> SEARCH_KEYS = Set.of("billNo", "supplier", "client", "warehouse",
            "billDate", "deliver", "total", "amount", "amountLocal", "weight", "department", "toWarehouse");
    private static final Set<String> TYPED_SEARCH_KEYS = Set.of("search.billDate", "search.deliver", "search.total", "search.amount", "search.amountLocal", "search.weight");

    public HeaderColumnFilter(Map<String, String> values) {
        Map<String, String> safe = new LinkedHashMap<>();
        if (values != null) values.forEach((key, value) -> {
            if (!(key.startsWith("search.") ? SEARCH_KEYS.contains(key.substring(7)) : KEYS.contains(key)))
                throw invalid("不支持的表头筛选字段: " + key);
            if (value != null && !value.isBlank()) {
                if (value.length() > (TYPED_SEARCH_KEYS.contains(key) ? 128 : 100)) throw invalid("表头筛选值过长");
                safe.put(key, value.strip());
            }
        });
        this.values = Map.copyOf(safe);
    }

    @Override
    public Map<String, String> values() {
        return java.util.Collections.unmodifiableMap(new LinkedHashMap<>(values));
    }

    public static HeaderColumnFilter from(Map<String, String> query) {
        Map<String, String> values = new LinkedHashMap<>();
        if (query != null) query.forEach((key, value) -> {
            if (key.startsWith("hf.")) values.put(key.substring(3), value);
            else if (key.startsWith("search.")) values.put(key, value);
        });
        return values.isEmpty() ? EMPTY : new HeaderColumnFilter(values);
    }

    public boolean hasAmount() { return has("amountMin", "amountMax", "amountNull", "search.total", "search.amount", "search.amountLocal"); }
    public boolean hasAmountRange() { return has("amountMin", "amountMax", "search.total", "search.amount", "search.amountLocal"); }
    private boolean has(String... keys) { for (String key : keys) { if (values.containsKey(key)) { return true; } } return false; }

    /** Reject before parsing/probing values or constructing a protected predicate. */
    public void requireAmountVisible(boolean visible) {
        if (hasAmount() && !visible) throw new ApiException(ErrorCode.FORBIDDEN, "无权按隐藏的商业金额筛选或探测空值");
    }
    public static void requireAmountSortVisible(String sort,boolean visible) {
        if(sort!=null&&Set.of("total","amount").contains(sort.strip())&&!visible)
            throw new ApiException(ErrorCode.FORBIDDEN,"无权按隐藏的商业金额排序");
    }

    /** A feature supplies its own fixed property/reference contract, never a client property path. */
    public record SearchField(String property, Class<?> referenceType, String referenceName, String parentProperty,
            com.uten.imp.common.util.JpaColumnSearch.Kind kind, Integer displayScale) {
        public SearchField(String property, Class<?> referenceType, String referenceName, String parentProperty) {
            this(property,referenceType,referenceName,parentProperty,com.uten.imp.common.util.JpaColumnSearch.Kind.TEXT,null);
        }
        public static SearchField text(String property) { return new SearchField(property, null, null, null); }
        public static SearchField reference(String property, Class<?> type) { return new SearchField(property, type, "name", null); }
        public static SearchField decimal(String property) { return new SearchField(property,null,null,null,com.uten.imp.common.util.JpaColumnSearch.Kind.DECIMAL,null); }
        public static SearchField calendarDate(String property) { return new SearchField(property,null,null,null,com.uten.imp.common.util.JpaColumnSearch.Kind.DATE,null); }
        public static SearchField instant(String property) { return new SearchField(property,null,null,null,com.uten.imp.common.util.JpaColumnSearch.Kind.INSTANT,null); }
        public static SearchField decimalDisplay(String property,int scale) {
            if(scale<0||scale>12)throw new IllegalArgumentException("Invalid server-owned decimal display scale");
            return new SearchField(property,null,null,null,com.uten.imp.common.util.JpaColumnSearch.Kind.DECIMAL,scale);
        }
        public SearchField withParent(String parentProperty) { return new SearchField(property, referenceType, referenceName, parentProperty,kind,displayScale); }

        private Predicate matches(Root<?> root, CriteriaQuery<?> query, CriteriaBuilder cb, String pattern) {
            if (referenceType == null) return com.uten.imp.common.util.NameRefKeyword.text(cb, root.get(property), pattern);
            var reference = query.subquery(java.util.UUID.class);
            Root<?> master = reference.from(referenceType);
            Predicate match = com.uten.imp.common.util.NameRefKeyword.text(cb, master.get(referenceName), pattern);
            if (parentProperty != null) {
                var parent = query.subquery(java.util.UUID.class);
                Root<?> parentRoot = parent.from(referenceType);
                parent.select(parentRoot.get("id")).where(cb.isFalse(parentRoot.get("deleted")),
                        com.uten.imp.common.util.NameRefKeyword.text(cb, parentRoot.get(referenceName), pattern));
                match = cb.or(match, master.get(parentProperty).in(parent));
            }
            reference.select(master.get("id")).where(cb.isFalse(master.get("deleted")), match);
            return root.get(property).in(reference);
        }
    }

    /** Column searches AND together, as do words within each column, before count and pagination. */
    public void applySearch(Root<?> root, CriteriaQuery<?> query, CriteriaBuilder cb, List<Predicate> predicates,
                            Map<String, SearchField> supported) {
        values.forEach((key, value) -> {
            if (!key.startsWith("search.")) return;
            SearchField field = supported.get(key.substring(7));
            if (field == null) throw invalid("本单据没有可搜索的表头列: " + key.substring(7));
            if(field.kind()!=com.uten.imp.common.util.JpaColumnSearch.Kind.TEXT) {
                var typed=new com.uten.imp.common.util.JpaColumnSearch.Field(field.kind(),(owner,selection,builder)->
                        field.displayScale()==null?owner.get(field.property())
                        :builder.function("round",BigDecimal.class,owner.get(field.property()),builder.literal(field.displayScale())));
                predicates.add(com.uten.imp.common.util.JpaColumnSearch.predicate(root,query,cb,
                        Map.of(key.substring(7),value),Map.of(key.substring(7),typed)));
                return;
            }
            for (String term : com.uten.imp.common.util.KeywordSearch.terms(value)) {
                predicates.add(field.matches(root, query, cb, com.uten.imp.common.util.NameRefKeyword.like(term)));
            }
        });
    }

    /** Field names are constants selected by each owning feature, never request values. */
    public void apply(Root<?> root, CriteriaBuilder cb, List<Predicate> predicates,
            String amountProperty, boolean amountVisible, String deliveryProperty,
            boolean apPostedSupported, String weightProperty, boolean originSupported) {
        requireAmountVisible(amountVisible);
        if (hasAmount() && amountProperty == null) throw invalid("本单据没有可筛选的商业金额列");
        if (has("deliverFrom", "deliverTo") && deliveryProperty == null) throw invalid("本单据没有交货日期列");
        if (has("apPosted") && !apPostedSupported) throw invalid("本单据没有应付反向列");
        if (has("weightMin", "weightMax", "weightNull", "search.weight") && weightProperty == null) throw invalid("本单据没有实物总重列");
        if (has("recordOrigin") && !originSupported) throw invalid("本单据没有当前/历史来源列");
        if (hasAmount()) decimalRange(root.get(amountProperty), cb, predicates, "amountMin", "amountMax", "amountNull", "金额");
        if (has("weightMin", "weightMax", "weightNull")) decimalRange(root.get(weightProperty), cb, predicates,
                "weightMin", "weightMax", "weightNull", "实物总重");
        if (has("deliverFrom", "deliverTo")) {
            LocalDate from = date("deliverFrom"), to = date("deliverTo");
            if (from != null && to != null && from.isAfter(to)) throw invalid("交货日期范围无效");
            Expression<LocalDate> field = root.get(deliveryProperty);
            if (from != null) predicates.add(cb.greaterThanOrEqualTo(field, from));
            if (to != null) predicates.add(cb.lessThanOrEqualTo(field, to));
        }
        if (has("apPosted")) predicates.add(cb.equal(root.get("apPosted"), bool("apPosted")));
        if (has("recordOrigin")) {
            String origin = values.get("recordOrigin").toUpperCase(java.util.Locale.ROOT);
            switch (origin) {
                case "CURRENT" -> predicates.add(com.uten.imp.common.history.ImportedBusinessDocumentScope.predicate(
                        root,cb,com.uten.imp.common.history.ImportedBusinessDocumentScope.Origin.CURRENT));
                case "LEGACY" -> predicates.add(com.uten.imp.common.history.ImportedBusinessDocumentScope.predicate(
                        root,cb,com.uten.imp.common.history.ImportedBusinessDocumentScope.Origin.LEGACY));
                default -> throw invalid("来源仅支持 CURRENT 或 LEGACY");
            }
        }
    }

    private void decimalRange(Expression<BigDecimal> field, CriteriaBuilder cb, List<Predicate> predicates,
            String minKey, String maxKey, String nullKey, String label) {
        BigDecimal min = decimal(minKey, label), max = decimal(maxKey, label);
        Boolean nullOnly = bool(nullKey);
        if (min != null && max != null && min.compareTo(max) > 0) throw invalid(label + "范围无效");
        if (Boolean.TRUE.equals(nullOnly) && (min != null || max != null)) throw invalid(label + "未知值不能同时设数字范围");
        if (nullOnly != null) predicates.add(nullOnly ? cb.isNull(field) : cb.isNotNull(field));
        if (min != null) predicates.add(cb.greaterThanOrEqualTo(field, min));
        if (max != null) predicates.add(cb.lessThanOrEqualTo(field, max));
    }

    private BigDecimal decimal(String key, String label) {
        if (!values.containsKey(key)) return null;
        try { return FinancialExactAmount.book(new BigDecimal(values.get(key)), label + "筛选边界"); }
        catch (NumberFormatException failure) { throw invalid(label + "筛选边界必须是有限十进制数"); }
    }
    private LocalDate date(String key) {
        if (!values.containsKey(key)) return null;
        try { return LocalDate.parse(values.get(key)); }
        catch (java.time.format.DateTimeParseException failure) { throw invalid("交货日期格式无效"); }
    }
    private Boolean bool(String key) {
        if (!values.containsKey(key)) return null;
        return switch (values.get(key)) { case "true" -> true; case "false" -> false; default -> throw invalid("布尔筛选仅支持 true/false"); };
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
