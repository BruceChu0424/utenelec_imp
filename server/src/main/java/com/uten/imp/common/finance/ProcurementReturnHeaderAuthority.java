package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Derives a purchase/subcontract return header exclusively from approved receipt-item UUIDs. */
public final class ProcurementReturnHeaderAuthority {
    private ProcurementReturnHeaderAuthority() {
    }

    public static Header derive(
            EntityManager em, String rawReceiptType, List<UUID> rawReceiptItemIds) {
        String type = rawReceiptType == null ? "" : rawReceiptType.strip().toUpperCase();
        String itemTable;
        String receiptTable;
        if ("PURCHASE".equals(type)) {
            itemTable = "purchase_receipt_items";
            receiptTable = "purchase_receipts";
        } else if ("SUBCONTRACT".equals(type)) {
            itemTable = "subcontract_receipt_items";
            receiptTable = "subcontract_receipts";
        } else {
            throw new IllegalArgumentException("unsupported procurement return type: " + rawReceiptType);
        }
        List<UUID> ids = rawReceiptItemIds == null ? List.of()
                : rawReceiptItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty() || ids.size() != rawReceiptItemIds.size()) {
            throw validation("退货每一行必须唯一关联来源收货明细");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT receipt_item.id,receipt.supplier_id,receipt.currency_id,
                               receipt.exchange_rate,receipt.tax_rate,
                               receipt.settlement_method_id,receipt.settlement_style_legacy
                        FROM %s receipt_item
                        JOIN %s receipt ON receipt.id=receipt_item.receipt_id
                        WHERE receipt_item.id IN (:ids)
                          AND receipt.status=1
                          AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                          AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                        ORDER BY receipt_item.id
                        FOR SHARE OF receipt_item,receipt
                        """.formatted(itemTable, receiptTable))
                .setParameter("ids", ids)
                .getResultList();
        if (rows.size() != ids.size()) {
            throw conflict("部分退货来源收货明细不存在、未审核或已失效");
        }
        Object[] first = rows.getFirst();
        Header header = new Header(
                uuid(first[1]), uuid(first[2]), decimal(first[3]), decimal(first[4]),
                uuid(first[5]), integer(first[6]));
        if (header.supplierId() == null || header.currencyId() == null
                || header.exchangeRate() == null || header.exchangeRate().signum() <= 0
                || header.taxRate() == null || header.taxRate().signum() < 0
                || header.taxRate().compareTo(new BigDecimal("100")) > 0
                || header.settlementMethodId() == null) {
            throw conflict("来源收货商业快照不完整，禁止创建退货贷项");
        }
        for (Object[] row : rows) {
            if (!Objects.equals(header.supplierId(), uuid(row[1]))
                    || !Objects.equals(header.currencyId(), uuid(row[2]))
                    || !same(header.exchangeRate(), decimal(row[3]))
                    || !same(header.taxRate(), decimal(row[4]))
                    || !Objects.equals(header.settlementMethodId(), uuid(row[5]))) {
                throw conflict("一张退货单的来源必须具有相同供应商、币种、汇率、税率和结算方式");
            }
        }
        return header;
    }

    private static boolean same(BigDecimal left, BigDecimal right) {
        return left != null && right != null && left.compareTo(right) == 0;
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID id ? id : value == null ? null : UUID.fromString(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal valueDecimal
                ? valueDecimal : new BigDecimal(value.toString());
    }

    private static Integer integer(Object value) {
        return value instanceof Number number ? number.intValue()
                : value == null ? null : Integer.valueOf(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record Header(
            UUID supplierId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate,
            UUID settlementMethodId,
            Integer settlementStyleLegacy) {
    }
}
