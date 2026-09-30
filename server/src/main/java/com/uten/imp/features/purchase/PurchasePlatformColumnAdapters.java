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
        return new DocumentPlatformColumnAdapter("purchase_request","采购申请",current,em,json,
                Set.of("purchase_request:view"),Set.of("purchase_request:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.purchase.request.PurchaseRequest.class,
                null,
                requestService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("canEdit").asBoolean(false),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter purchaserequestItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_request_item","采购申请明细",current,em,json,
                Set.of("purchase_request:view"),Set.of("purchase_request:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.purchase.request.PurchaseRequest.class,
                "SELECT id,request_id FROM purchase_request_items WHERE id IN (:ids) AND NOT is_deleted",
                requestService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("canEdit").asBoolean(false),LINE)
                .documentRows("SELECT id FROM purchase_request_items WHERE request_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("purchase_request:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter purchaseorderHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_order","采购订货",current,em,json,
                Set.of("purchase_order:view"),Set.of("purchase_order:edit"),Set.of("purchase_order:price:view","finance:view:all"),
                com.uten.imp.features.purchase.order.PurchaseOrder.class,
                null,
                orderService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("canEdit").asBoolean(false) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereceiptHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_receipt","采购收货",current,em,json,
                Set.of("purchase_receipt:view"),Set.of("purchase_receipt:edit"),Set.of("purchase_receipt:price:view","finance:view:all"),
                com.uten.imp.features.purchase.receipt.PurchaseReceipt.class,
                null,
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereceiptItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_receipt_item","采购收货明细",current,em,json,
                Set.of("purchase_receipt:view"),Set.of("purchase_receipt:edit"),Set.of("purchase_receipt:price:view","finance:view:all"),
                com.uten.imp.features.purchase.receipt.PurchaseReceipt.class,
                "SELECT id,receipt_id FROM purchase_receipt_items WHERE id IN (:ids) AND NOT is_deleted",
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE)
                .documentRows("SELECT id FROM purchase_receipt_items WHERE receipt_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("purchase_receipt:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereturnHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_return","采购退货",current,em,json,
                Set.of("purchase_return:view"),Set.of("purchase_return:edit"),Set.of("purchase_return:price:view","finance:view:all"),
                com.uten.imp.features.purchase.ret.PurchaseReturn.class,
                null,
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter purchasereturnItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("purchase_return_item","采购退货明细",current,em,json,
                Set.of("purchase_return:view"),Set.of("purchase_return:edit"),Set.of("purchase_return:price:view","finance:view:all"),
                com.uten.imp.features.purchase.ret.PurchaseReturn.class,
                "SELECT id,return_id FROM purchase_return_items WHERE id IN (:ids) AND NOT is_deleted",
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE)
                .documentRows("SELECT id FROM purchase_return_items WHERE return_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("purchase_return:create"));
    }
}
