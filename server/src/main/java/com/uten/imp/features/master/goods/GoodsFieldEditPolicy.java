package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.security.CurrentAuthorityGuard;
import java.math.BigDecimal;
import java.util.Objects;

/** Shared field authority contract for full saves, imported merges and narrow patches. */
public final class GoodsFieldEditPolicy {
    public static final String PURCHASE = "goods:purchase:edit";
    public static final String SALES = "goods:sales:edit";
    private GoodsFieldEditPolicy() {}

    /** Authorize reviewed import cells before materializing referenced master data. */
    public static void requireFields(java.util.Collection<String> fields) {
        for (String field : fields) {
            switch (field) {
                case "sourceType", "minOrderQty", "orderMultipleQty", "defaultSupplierId", "secondarySupplierId",
                        "subcontractAllowedLossPct", "purchaseAllowedOverReceiptPct" -> CurrentAuthorityGuard.requireAll(PURCHASE);
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
        validateStatus(req);
        if (req.hasStatus() && different(old.getStatus(),req.getStatus())) CurrentAuthorityGuard.requireAll("goods:status");
        requirePriceIfTouched(old,req,hasAny("goods:price:view","goods:price:edit"),hasAny("goods:discount:view"));
        if (req.hasSourceType() && different(old.getSourceType(), req.getSourceType())
                || req.hasMinOrderQty() && different(old.getMinOrderQty(), req.getMinOrderQty())
                || req.hasOrderMultipleQty() && different(old.getOrderMultipleQty(), zeroToNull(req.getOrderMultipleQty()))
                || req.hasSubcontractAllowedLossPct() && different(old.getSubcontractAllowedLossPct(), req.getSubcontractAllowedLossPct())
                || req.hasDefaultSupplierReference() && referenceChanged(old.getDefaultSupplier(), old.getVendLegacyId(), req.getDefaultSupplierId(), req.getVendLegacyId())
                || req.hasSecondarySupplierReference() && referenceChanged(old.getSecondarySupplier(), old.getVend2LegacyId(), req.getSecondarySupplierId(), req.getVend2LegacyId())) {
            CurrentAuthorityGuard.requireAll(PURCHASE);
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

    private static boolean mayWriteCosts() {
        var auth = org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        return auth != null && (auth.getPrincipal() instanceof com.uten.imp.security.AuthUser u && u.isSuperAdmin()
                || auth.getAuthorities().stream().anyMatch(a -> a.getAuthority().equals("goods:cost:view")));
    }
    public static void validateStatus(GoodsSaveRequest req) {
        if(req.hasStatus() && !java.util.Set.of("使用","禁用").contains(req.getStatus()==null?"":req.getStatus())) {
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"状态必须为使用或禁用，不能清空");
        }
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
