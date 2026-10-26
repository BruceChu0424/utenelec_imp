package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.security.CurrentAuthorityGuard;
import java.math.BigDecimal;
import java.util.Objects;
import java.util.Set;
import java.util.LinkedHashSet;

/** Shared field authority contract for full saves, imported merges and narrow patches. */
public final class GoodsFieldEditPolicy {
    public static final String PURCHASE = "goods:purchase:edit";
    public static final String SALES = "goods:sales:edit";
    public static final Set<String> BASE_SNAPSHOT_FIELDS=Set.of(
            "code","code_managed","code_sequence","code_prefix_category_id","category_id","name","short_name",
            "model","spec","series","stock_place","material","thickness","m_weight","pack","pieces","paper",
            "rear_insert_code","color_id","unit_id","mould_id","thickness_unit_id","m_weight_unit_id",
            "owning_warehouse_id","color_legacy_id","unit_legacy_id","mould_legacy_id",
            "thickness_unit_legacy_id","m_weight_unit_legacy_id");
    public static final Set<String> PURCHASE_SNAPSHOT_FIELDS=Set.of(
            "source_type","min_order_qty","order_multiple_qty","default_supplier_id","secondary_supplier_id",
            "vend_legacy_id","vend2_legacy_id","subcontract_allowed_loss_pct","purchase_allowed_over_receipt_pct");
    public static final Set<String> SALES_SNAPSHOT_FIELDS=Set.of("c_number","client_goods_name","client_id","client_legacy_id");
    public static final Set<String> ENGLISH_SNAPSHOT_FIELDS=Set.of("name_en","name_en_source");
    public static final Set<String> COST_SNAPSHOT_FIELDS=Set.of("source_e","machining_e","incidental_e","lacquer_e","plating_e",
            "casing_e","polish_e","total","work_rate","work_e","lost_rate","lost_e","rent_rate","rent_e","make_rate","make_e","c_total","g_total");
    /** Deletion/restoration is authorized by its owning command, not as an ordinary field edit. */
    public static final Set<String> LIFECYCLE_SNAPSHOT_FIELDS=Set.of("is_deleted");
    private GoodsFieldEditPolicy() {}

    /** Authorize reviewed import cells before materializing referenced master data. */
    public static void requireFields(java.util.Collection<String> fields) {
        for (String field : fields) {
            switch (field) {
                case "sourceType", "minOrderQty", "orderMultipleQty", "defaultSupplierId", "secondarySupplierId",
                        "purchaseAllowedOverReceiptPct" -> CurrentAuthorityGuard.requireAll(PURCHASE);
                case "subcontractAllowedLossPct" -> CurrentAuthorityGuard.requireAll(PURCHASE,"goods:cost:view");
                case "clientGoodsName", "cNumber", "clientId" -> CurrentAuthorityGuard.requireAll(SALES);
                case "nameEn" -> requireEnglishName();
                case "price" -> CurrentAuthorityGuard.requireAll("goods:price:edit");
                case "discount" -> CurrentAuthorityGuard.requireAll("goods:price:edit", "goods:discount:view");
                case "status" -> CurrentAuthorityGuard.requireAll("goods:status");
                default -> CurrentAuthorityGuard.requireAll("goods:edit");
            }
        }
    }

    public static void requireChanged(Goods old, GoodsSaveRequest req) {
        requireChanged(old,req,mayWriteCosts());
    }
    public static void requireChanged(Goods old, GoodsSaveRequest req, boolean writeCosts) {
        // Baseline copies may contain a historical unknown status. Preserve an
        // unchanged raw value; every actual change still validates and rechecks authority.
        if (req.hasStatus() && !Objects.equals(old.getStatus(),req.getStatus())) {
            validateStatus(req);
            CurrentAuthorityGuard.requireAll("goods:status");
        }
        requirePriceIfTouched(old,req,hasAny("goods:price:view","goods:price:edit"),hasAny("goods:discount:view"));
        if (req.hasSourceType() && different(old.getSourceType(), req.getSourceType())
                || req.hasMinOrderQty() && different(old.getMinOrderQty(), req.getMinOrderQty())
                || req.hasOrderMultipleQty() && different(old.getOrderMultipleQty(), zeroToNull(req.getOrderMultipleQty()))
                || req.hasSubcontractAllowedLossPct() && different(old.getSubcontractAllowedLossPct(), req.getSubcontractAllowedLossPct())
                || req.hasDefaultSupplierReference() && referenceChanged(old.getDefaultSupplier(), old.getVendLegacyId(), req.getDefaultSupplierId(), req.getVendLegacyId())
                || req.hasSecondarySupplierReference() && referenceChanged(old.getSecondarySupplier(), old.getVend2LegacyId(), req.getSecondarySupplierId(), req.getVend2LegacyId())) {
            CurrentAuthorityGuard.requireAll(PURCHASE);
        }
        if(req.hasSubcontractAllowedLossPct() && different(old.getSubcontractAllowedLossPct(),req.getSubcontractAllowedLossPct())) {
            CurrentAuthorityGuard.requireAll("goods:cost:view");
        }
        if (req.hasCNumber() && different(old.getCNumber(), req.getCNumber())
                || req.hasClientGoodsName() && different(old.getClientGoodsName(), req.getClientGoodsName())
                || req.hasClientReference() && referenceChanged(old.getClient(), old.getClientLegacyId(), req.getClientId(), req.getClientLegacyId())) {
            CurrentAuthorityGuard.requireAll(SALES);
        }
        if (req.hasNameEn() && !Objects.equals(old.getNameEn(),req.getNameEn()) && different(old.getNameEn(), GoodsNameEn.normalizeForWrite(req.getNameEn()))) {
            // The established narrow English-name authority remains usable.
            requireEnglishName();
        }
        if (different(old.getCode(), req.getCode())
                || different(old.getCategory() == null ? null : old.getCategory().getId(), req.getCategoryId())
                || different(old.getName(), req.getName()) || different(old.getShortName(), req.getShortName())
                || different(old.getModel(), req.getModel()) || different(old.getSpec(), req.getSpec())
                || different(old.getSeries(), req.getSeries()) || different(old.getStockPlace(), req.getStockPlace())
                || different(old.getMaterial(), req.getMaterial()) || different(old.getThickness(), req.getThickness())
                || different(old.getMWeight(), req.getMWeight()) || different(old.getPack(), req.getPack())
                || different(old.getPieces(), req.getPieces()) || different(old.getPaper(), req.getPaper())
                || different(old.getRearInsertCode(), req.getRearInsertCode())
                || req.hasColorReference() && referenceChanged(old.getColor(), old.getColorLegacyId(), req.getColorId(), req.getColorLegacyId())
                || req.hasUnitReference() && referenceChanged(old.getUnit(), old.getUnitLegacyId(), req.getUnitId(), req.getUnitLegacyId())
                || req.hasMouldReference() && referenceChanged(old.getMould(), old.getMouldLegacyId(), req.getMouldId(), req.getMouldLegacyId())
                || req.hasThicknessUnitReference() && referenceChanged(old.getThicknessUnit(), old.getThicknessUnitLegacyId(), req.getThicknessUnitId(), req.getThicknessUnitLegacyId())
                || req.hasMWeightUnitReference() && referenceChanged(old.getMWeightUnit(), old.getMWeightUnitLegacyId(), req.getMWeightUnitId(), req.getMWeightUnitLegacyId())
                || req.hasOwningWarehouseReference() && different(old.getOwningWarehouse() == null ? null : old.getOwningWarehouse().getId(), req.getOwningWarehouseId())
) {
            CurrentAuthorityGuard.requireAll("goods:edit");
        }
        if (writeCosts && (different(old.getSourceE(), req.getSourceE())
                || different(old.getMachiningE(), req.getMachiningE())
                || different(old.getIncidentalE(), req.getIncidentalE())
                || different(old.getLacquerE(), req.getLacquerE())
                || different(old.getPlatingE(), req.getPlatingE())
                || different(old.getCasingE(), req.getCasingE())
                || different(old.getPolishE(), req.getPolishE())
                || different(old.getTotal(), req.getTotal())
                || different(old.getWorkRate(), req.getWorkRate())
                || different(old.getWorkE(), req.getWorkE())
                || different(old.getLostRate(), req.getLostRate())
                || different(old.getLostE(), req.getLostE())
                || different(old.getRentRate(), req.getRentRate())
                || different(old.getRentE(), req.getRentE())
                || different(old.getMakeRate(), req.getMakeRate())
                || different(old.getMakeE(), req.getMakeE())
                || different(old.getCTotal(), req.getCTotal())
                || different(old.getGTotal(), req.getGTotal()))) {
            CurrentAuthorityGuard.requireAll("goods:edit","goods:cost:view");
        }
    }

    /** Shared by operation undo/redo and immutable version restoration. */
    public static Set<String> snapshotPermissions(JsonNode before,JsonNode after,boolean directCosts,Set<String> held) {
        Set<String> required=new LinkedHashSet<>();
        if(before==null || after==null) return Set.of();
        if(snapshotChanged(before,after,BASE_SNAPSHOT_FIELDS)) required.add("goods:edit");
        if(snapshotChanged(before,after,PURCHASE_SNAPSHOT_FIELDS)) required.add(PURCHASE);
        if(snapshotChanged(before,after,SALES_SNAPSHOT_FIELDS)) required.add(SALES);
        if(snapshotChanged(before,after,ENGLISH_SNAPSHOT_FIELDS) && !held.contains("goods:name_en:edit")) required.add(SALES);
        if(snapshotChanged(before,after,Set.of("status"))) required.add("goods:status");
        if(snapshotChanged(before,after,Set.of("price","zk"))) required.add("goods:price:edit");
        if(snapshotChanged(before,after,Set.of("zk"))) required.add("goods:discount:view");
        if(snapshotChanged(before,after,Set.of("subcontract_allowed_loss_pct"))) required.add("goods:cost:view");
        if(directCosts && snapshotChanged(before,after,COST_SNAPSHOT_FIELDS)) {
            required.add("goods:edit");required.add("goods:cost:view");
        }
        return Set.copyOf(required);
    }
    public static Set<String> snapshotClassifiedFields() {
        Set<String> fields=new LinkedHashSet<>();
        for(Set<String> group:java.util.List.of(BASE_SNAPSHOT_FIELDS,PURCHASE_SNAPSHOT_FIELDS,SALES_SNAPSHOT_FIELDS,
                ENGLISH_SNAPSHOT_FIELDS,COST_SNAPSHOT_FIELDS,LIFECYCLE_SNAPSHOT_FIELDS,Set.of("status","price","zk"))) fields.addAll(group);
        return Set.copyOf(fields);
    }
    private static boolean snapshotChanged(JsonNode before,JsonNode after,Set<String> fields) {
        return fields.stream().anyMatch(field->!Objects.equals(before.get(field),after.get(field)));
    }

    private static boolean mayWriteCosts() {
        var auth = org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        return auth != null && (auth.getPrincipal() instanceof com.uten.imp.security.AuthUser u && u.isSuperAdmin()
                || auth.getAuthorities().stream().anyMatch(a -> a.getAuthority().equals("goods:cost:view")));
    }
    public static void validateStatus(GoodsSaveRequest req) {
        if(req.hasStatus()) com.uten.imp.common.domain.MasterStatuses.requireValid(req.getStatus());
    }
    public static void requirePriceIfTouched(Goods old, GoodsSaveRequest req, boolean priceVisible, boolean discountVisible) {
        if(req.hasPrice() && priceVisible && different(old==null?null:old.getPrice(),req.getPrice())) CurrentAuthorityGuard.requireAll("goods:price:edit");
        if(req.hasDiscount() && discountVisible && different(old==null?null:old.getDiscount(),req.getDiscount())) CurrentAuthorityGuard.requireAll("goods:price:edit","goods:discount:view");
    }
    private static boolean hasAny(String... codes) {
        var auth=org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        return auth!=null && (auth.getPrincipal() instanceof com.uten.imp.security.AuthUser user && user.isSuperAdmin()
                || auth.getAuthorities().stream().anyMatch(authority -> java.util.Arrays.asList(codes).contains(authority.getAuthority())));
    }
    private static void requireEnglishName() {
        var auth = org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getAuthorities().stream().anyMatch(a -> a.getAuthority().equals("goods:name_en:edit"))) return;
        CurrentAuthorityGuard.requireAll(SALES);
    }

    private static boolean referenceChanged(com.uten.imp.common.domain.BaseEntity current, Integer oldLegacy,
            java.util.UUID requestedId, Integer requestedLegacy) {
        return different(current == null ? null : current.getId(), requestedId)
                || current == null && different(oldLegacy, requestedLegacy != null && requestedLegacy == 0 ? null : requestedLegacy);
    }
    private static BigDecimal zeroToNull(BigDecimal value) { return value != null && value.signum() == 0 ? null : value; }
    private static boolean different(Object before, Object after) {
        if (before instanceof BigDecimal a && after instanceof BigDecimal b) return a.compareTo(b) != 0;
        // The full editor represents optional empty text as an empty string.
        if (before instanceof String || after instanceof String) {
            return !Objects.equals(text(before), text(after));
        }
        return !Objects.equals(before, after);
    }
    private static Object text(Object value) { return value == null || value.toString().isBlank() ? null : value.toString(); }
}
