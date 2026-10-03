package com.uten.imp.features.purchase;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

/** Fixed resource registrations; actual detail loaders enforce each domain's row visibility. */
@Configuration
@RequiredArgsConstructor
public class PurchasePlatformColumnAdapters {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final PurchaseDocumentAccessPolicy access;
    private final com.uten.imp.features.purchase.request.PurchaseRequestService requestService;
    private final com.uten.imp.features.purchase.order.PurchaseOrderService orderService;
    private final com.uten.imp.features.purchase.receipt.PurchaseReceiptService receiptService;
    private final com.uten.imp.features.purchase.ret.PurchaseReturnService retService;
    private static final List<FactDefinition> HEADER=List.of(new FactDefinition("totalOriginal","原币合计",true),new FactDefinition("totalLocal","本币合计",true));
    private static final List<FactDefinition> LINE=List.of(new FactDefinition("qty","数量",false),new FactDefinition("weight","重量",false),new FactDefinition("price","单价",true),new FactDefinition("amountOriginal","原币金额",true),new FactDefinition("amountLocal","本币金额",true));

    @Bean
    public PlatformColumnResourceAdapter purchaserequestHeaderPlatformColumns() {
        // Plan-created requests have no generic edit/create authority (V328/V455).
        // V477's separately guarded quantity adjustment does not grant field editing.
        return new DocumentPlatformColumnAdapter("purchase_request","采购申请",current,em,json,
                Set.of("purchase_request:view"),Set.of(),Set.of("finance:view:all"),
                com.uten.imp.features.purchase.request.PurchaseRequest.class,
                null,
                requestService::detail,(id,header)->false,HEADER).history(requestService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter purchaserequestItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_request_item","采购申请明细",current,em,json,
                Set.of("purchase_request:view"),Set.of(),Set.of("finance:view:all"),
                com.uten.imp.features.purchase.request.PurchaseRequest.class,
                "SELECT id,request_id FROM purchase_request_items WHERE id IN (:ids) AND NOT is_deleted",
                requestService::detail,(id,header)->false,LINE).history(requestService::detailHistory,"SELECT live.id,live.request_id FROM purchase_request_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='purchase_request_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='purchase_request_items' AND parent_table='purchase_requests' AND CAST(CASE WHEN source_table='purchase_request_items' AND parent_table='purchase_requests' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM purchase_request_items WHERE request_id=:document AND NOT is_deleted");
    }

    @Bean
    public PlatformColumnResourceAdapter purchaseorderHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_order","采购订货",current,em,json,
                Set.of("purchase_order:view"),Set.of("purchase_order:edit"),Set.of("purchase_order:price:view","finance:view:all"),
                com.uten.imp.features.purchase.order.PurchaseOrder.class,
                null,
                orderService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("canEdit").asBoolean(false) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(orderService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereceiptHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_receipt","采购收货",current,em,json,
                Set.of("purchase_receipt:view"),Set.of("purchase_receipt:edit"),Set.of("purchase_receipt:price:view","finance:view:all"),
                com.uten.imp.features.purchase.receipt.PurchaseReceipt.class,
                null,
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(receiptService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereceiptItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_receipt_item","采购收货明细",current,em,json,
                Set.of("purchase_receipt:view"),Set.of("purchase_receipt:edit"),Set.of("purchase_receipt:price:view","finance:view:all"),
                com.uten.imp.features.purchase.receipt.PurchaseReceipt.class,
                "SELECT id,receipt_id FROM purchase_receipt_items WHERE id IN (:ids) AND NOT is_deleted",
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(receiptService::detailHistory,"SELECT live.id,live.receipt_id FROM purchase_receipt_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='purchase_receipt_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='purchase_receipt_items' AND parent_table='purchase_receipts' AND CAST(CASE WHEN source_table='purchase_receipt_items' AND parent_table='purchase_receipts' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM purchase_receipt_items WHERE receipt_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest.class,receiptService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of("purchase_receipt:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereturnHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_return","采购退货",current,em,json,
                Set.of("purchase_return:view"),Set.of("purchase_return:edit"),Set.of("purchase_return:price:view","finance:view:all"),
                com.uten.imp.features.purchase.ret.PurchaseReturn.class,
                null,
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(retService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereturnItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_return_item","采购退货明细",current,em,json,
                Set.of("purchase_return:view"),Set.of("purchase_return:edit"),Set.of("purchase_return:price:view","finance:view:all"),
                com.uten.imp.features.purchase.ret.PurchaseReturn.class,
                "SELECT id,return_id FROM purchase_return_items WHERE id IN (:ids) AND NOT is_deleted",
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(retService::detailHistory,"SELECT live.id,live.return_id FROM purchase_return_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='purchase_return_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='purchase_return_items' AND parent_table='purchase_returns' AND CAST(CASE WHEN source_table='purchase_return_items' AND parent_table='purchase_returns' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM purchase_return_items WHERE return_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest.class,retService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of("purchase_return:create"));
    }
}
