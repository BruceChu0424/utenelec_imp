package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Base64;
import java.util.Map;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.HashSet;
import java.util.UUID;

/** Compatibility algorithms for Main's saved plain-policy format. Production
 * saves and reviews use ProcurementReferencePricePolicyService and its complete
 * owning-row verifier; these helpers do not persist or retag a saved policy. */
public final class ProcurementReferencePrice {
    private static final ObjectMapper JSON = new ObjectMapper();

    private ProcurementReferencePrice() { }

    public record Adoption(BigDecimal price, Map<String, Object> policy) { }

    public interface Owner {
        UUID getId();
        BigDecimal getTotalAmountInput();
        void setReferencePricePrecisionPolicy(Map<String, Object> policy);
    }

    /** A single authoritative read also supports historical schemas where the proof column did not exist. */
    public static void loadPolicies(EntityManager em, String kind, Collection<? extends Owner> items) {
        var expected = new LinkedHashMap<UUID, Owner>();
        for (Owner item : items) {
            if (item.getTotalAmountInput() == null) continue;
            if (item.getId() == null || expected.put(item.getId(), item) != null) {
                throw new ApiException(ErrorCode.CONFLICT, "订单明细的原精度证明身份不完整，请刷新后核对");
            }
        }
        if (expected.isEmpty()) return;
        String sql = switch (kind) {
            case "PURCHASE" -> "SELECT item.id,NULLIF((to_jsonb(item)->'reference_price_precision_policy')::text,'null') FROM purchase_order_items item WHERE item.id IN(:ids) AND NOT item.is_deleted";
            case "SUBCONTRACT" -> "SELECT item.id,NULLIF((to_jsonb(item)->'reference_price_precision_policy')::text,'null') FROM subcontract_order_items item WHERE item.id IN(:ids) AND NOT item.is_deleted";
            default -> throw new IllegalArgumentException("Unsupported reference-price owner");
        };
        em.flush();
        var seen = new HashSet<UUID>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("ids", expected.keySet()))) {
            if (row.length != 2 || !(row[0] instanceof UUID id) || !expected.containsKey(id) || !seen.add(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "订单明细的原精度证明不一致，请刷新后核对");
            }
            Map<String, Object> policy = null;
            if (row[1] != null) {
                try { policy = JSON.readValue(row[1].toString(), new TypeReference<>() { }); }
                catch (java.io.IOException failure) { throw new ApiException(ErrorCode.CONFLICT, "订单明细的原精度证明无法读取，请核对原单据"); }
            }
            expected.get(id).setReferencePricePrecisionPolicy(policy);
        }
        if (seen.size() != expected.size()) throw new ApiException(ErrorCode.CONFLICT, "订单明细的原精度证明未读取完整，请刷新后核对");
    }

    public static Adoption adopt(BigDecimal total, BigDecimal quantity) {
        BigDecimal price = MoneyPolicy.referenceUnitPrice(total, quantity);
        try {
            Map<String, Object> policy = JSON.readValue(BusinessPrecisionContext.json(), new TypeReference<>() { });
            return new Adoption(price, policy);
        } catch (java.io.IOException failure) {
            throw new IllegalStateException("Reference-price policy cannot be frozen", failure);
        }
    }

    @SuppressWarnings("try")
    public static BigDecimal proofPrice(BigDecimal total, BigDecimal quantity, Map<String, Object> policy) {
        BigDecimal original = MoneyPolicy.totalAmountInput(total);
        if (original == null || quantity == null || quantity.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "按总金额计价时数量必须大于 0");
        }
        FinancialExactAmount.quantity(quantity, "数量");
        if (policy == null) {
            // V760's historical contract is a proof of an existing value, never a new user default.
            return FinancialExactAmount.unitPrice(original.divide(quantity, 10, RoundingMode.DOWN), "参考单价")
                    .stripTrailingZeros();
        }
        try {
            var choices = BusinessPrecisionContext.parse(Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(JSON.writeValueAsBytes(policy)));
            try (var ignored = BusinessPrecisionContext.use(choices)) {
                return MoneyPolicy.referenceUnitPrice(original, quantity);
            }
        } catch (RuntimeException failure) {
            throw new ApiException(ErrorCode.CONFLICT, "参考单价的原精度证明无法核验，请核对原单据");
        } catch (Exception failure) {
            throw new IllegalStateException("Reference-price proof cannot be read", failure);
        }
    }

    public static BigDecimal baseAmount(BigDecimal quantity, BigDecimal price, BigDecimal total,
            Map<String, Object> policy) {
        if (total == null) {
            if (policy != null) throw new ApiException(ErrorCode.CONFLICT, "单价计价明细不能带总金额参考价证明");
            return price == null ? null : MoneyPolicy.exactProduct(quantity, price);
        }
        if (price == null || price.compareTo(proofPrice(total, quantity, policy)) != 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "参考单价与总金额、数量不一致");
        }
        return MoneyPolicy.totalAmountInput(total);
    }
}
