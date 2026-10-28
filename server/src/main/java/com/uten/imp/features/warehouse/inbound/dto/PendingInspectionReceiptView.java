package com.uten.imp.features.warehouse.inbound.dto;

import com.uten.imp.common.util.NativeValueConverters;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

public record PendingInspectionReceiptView(String receiptType,UUID receiptId,String billNo,LocalDate billDate,
        UUID supplierId,String supplierName,UUID warehouseId,long itemCount,BigDecimal pendingBaseQty,
        OffsetDateTime firstReceivedAt,OffsetDateTime lastReceivedAt,long preStockedItemCount,
        String preStockedWarehouseNames,String preStockedPlaces,String goodsSummary,String pendingQtyText,
        String goodsCodeSummary,String colorNameSummary) {
    public static PendingInspectionReceiptView from(Object[] row) {
        return new PendingInspectionReceiptView((String)row[0],(UUID)row[1],(String)row[7],NativeValueConverters.toLocalDate(row[8]),
                (UUID)row[9],(String)row[10],(UUID)row[6],((Number)row[2]).longValue(),
                row[3]==null?BigDecimal.ZERO:new BigDecimal(row[3].toString()),NativeValueConverters.toOffsetDateTime(row[4]),
                NativeValueConverters.toOffsetDateTime(row[5]),((Number)row[11]).longValue(),(String)row[12],(String)row[13],
                (String)row[14],(String)row[15],(String)row[16],(String)row[17]);
    }
}
