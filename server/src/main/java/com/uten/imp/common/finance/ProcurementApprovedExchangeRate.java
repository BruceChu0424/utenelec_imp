package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** The contract rate and a financial approval decision remain distinct facts. */
public final class ProcurementApprovedExchangeRate {
    private ProcurementApprovedExchangeRate() {}

    public record Terms(UUID caseId, BigDecimal rate, boolean financeDetermined) {
        public BigDecimal local(BigDecimal original, BigDecimal historicalLocal) {
            return financeDetermined ? MoneyPolicy.local(original, rate) : historicalLocal;
        }
    }

    /** Callers already hold the order mutation lock when using these values for a write. */
    public static Terms read(EntityManager em, String kind, UUID orderId, BigDecimal contractRate) {
        kind = kind(kind);
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT id,finance_exchange_rate,finance_total_local
                FROM procurement_order_approval_cases
                WHERE order_type=:kind AND order_id=:orderId AND status='APPROVED' AND request_type='ORDER'
                ORDER BY attempt DESC LIMIT 1
                """).setParameter("kind", kind).setParameter("orderId", orderId).getResultList();
        return terms(rows, contractRate);
    }

    public static Terms read(JdbcTemplate jdbc, String kind, UUID orderId, BigDecimal contractRate) {
        List<Object[]> rows = jdbc.query("""
                SELECT id,finance_exchange_rate,finance_total_local
                FROM procurement_order_approval_cases
                WHERE order_type=? AND order_id=? AND status='APPROVED' AND request_type='ORDER'
                ORDER BY attempt DESC LIMIT 1
                """, (rs,n) -> new Object[]{rs.getObject(1,UUID.class),rs.getBigDecimal(2),rs.getBigDecimal(3)},kind(kind),orderId);
        return terms(rows, contractRate);
    }

    private static Terms terms(List<Object[]> rows, BigDecimal contractRate) {
        if (rows.isEmpty()) return fromApprovedFacts(null, null, null, contractRate);
        Object[] row=rows.getFirst();
        return fromApprovedFacts((UUID)row[0],(BigDecimal)row[1],(BigDecimal)row[2],contractRate);
    }

    /** Resolves the same authority from an approval row already read in the caller's snapshot. */
    public static Terms fromApprovedFacts(UUID caseId, BigDecimal financeRate,
            BigDecimal financeTotalLocal, BigDecimal contractRate) {
        if (financeRate == null) {
            if (financeTotalLocal != null)
                throw conflict("历史财审汇率和本币金额事实不完整，请先专项核对");
            return new Terms(caseId,positive(contractRate),false);
        }
        if (caseId == null || financeTotalLocal == null) throw conflict("财审本币金额事实缺失，请先专项核对");
        FinancialExactAmount.book(financeTotalLocal,"财审本币金额");
        return new Terms(caseId,positive(financeRate),true);
    }

    /** A receipt has one currency and rate; every source must agree before saving. */
    public static BigDecimal receiptRate(EntityManager em,String kind,List<UUID> orderItemIds,UUID currencyId,BigDecimal fallback) {
        List<UUID> ids=orderItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if(ids.isEmpty()) return fallback;
        String prefix=prefix(kind);
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery(
                "SELECT DISTINCT h.id,h.currency_id,h.exchange_rate FROM "+prefix+"_order_items i "
                +"JOIN "+prefix+"_orders h ON h.id=i.order_id WHERE i.id IN (:ids) AND NOT i.is_deleted AND NOT h.is_deleted ORDER BY h.id")
                .setParameter("ids",ids).getResultList();
        if(rows.isEmpty()) throw conflict("收货来源订货单不存在");
        BigDecimal rate=null;
        for(Object[] row:rows){
            if(!Objects.equals(currencyId,row[1])) throw conflict("收货币种与来源订货单不一致");
            BigDecimal source=read(em,kind,(UUID)row[0],(BigDecimal)row[2]).rate();
            if(rate!=null && rate.compareTo(source)!=0) throw conflict("收货来源财审汇率不同，请按商业条款分单");
            rate=source;
        }
        return rate;
    }

    /** A quantity review cannot revalue any previously posted receipt. */
    public static void requireReviewedRate(JdbcTemplate jdbc,String kind,UUID orderId,UUID currencyId,BigDecimal rate) {
        List<Boolean> base=jdbc.query("SELECT is_base_currency FROM currencies WHERE id=? AND NOT is_deleted AND status='使用'",
                (rs,n)->rs.getBoolean(1),currencyId);
        if(base.size()!=1) throw conflict("财审币种不存在或已停用");
        if(base.getFirst() && rate.compareTo(BigDecimal.ONE)!=0)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"本位币采购或委外财审汇率必须为 1");
        String prefix=prefix(kind);
        Long mismatches=jdbc.queryForObject("SELECT COUNT(*) FROM "+prefix+"_receipt_items i JOIN "+prefix
                +"_receipts r ON r.id=i.receipt_id JOIN "+prefix+"_order_items source ON source.id=i.order_item_id "
                +"WHERE source.order_id=? AND r.status=1 AND NOT r.is_deleted AND NOT i.is_deleted "
                +"AND (r.exchange_rate IS NULL OR r.exchange_rate<>?)",Long.class,orderId,rate);
        if(mismatches!=null && mismatches>0) throw conflict("该订货单已有收货过账，财审汇率须保持原过账汇率；历史本币事实不能重新估值");
    }

    public static void requireHistoricalReceiptRate(EntityManager em,String kind,UUID sourceItem,UUID currentReceipt,BigDecimal rate) {
        String prefix=prefix(kind);
        long count=((Number)em.createNativeQuery("SELECT COUNT(*) FROM "+prefix+"_receipt_items i JOIN "+prefix
                +"_receipts r ON r.id=i.receipt_id WHERE i.order_item_id=:source AND r.id<>:receipt "
                +"AND r.status=1 AND NOT r.is_deleted AND NOT i.is_deleted "
                +"AND (r.exchange_rate IS NULL OR r.exchange_rate<>:rate)")
                .setParameter("source",sourceItem).setParameter("receipt",currentReceipt).setParameter("rate",rate).getSingleResult()).longValue();
        if(count>0) throw conflict("历史有效收货与当前财审汇率不一致，请先专项核对；本次不重估历史金额");
    }

    public static void pinReceiptCase(EntityManager em,String kind,UUID receiptItem,UUID caseId) {
        em.createNativeQuery("UPDATE "+prefix(kind)+"_receipt_items SET finance_approval_case_id=CAST(:caseId AS uuid) WHERE id=:id")
                .setParameter("caseId",caseId).setParameter("id",receiptItem).executeUpdate();
    }

    private static BigDecimal positive(BigDecimal rate) {
        if(rate==null || rate.signum()<=0) throw conflict("来源订货汇率不完整");
        return FinancialExactAmount.rate(rate,"来源财审汇率");
    }
    private static String kind(String value) {
        if(!"PURCHASE".equals(value)&&!"SUBCONTRACT".equals(value)) throw new IllegalArgumentException("Unknown procurement kind");
        return value;
    }
    private static String prefix(String value) { return "PURCHASE".equals(kind(value))?"purchase":"subcontract"; }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
