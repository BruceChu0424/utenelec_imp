package com.uten.imp.features.subcontract;

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
public class SubcontractPlatformColumnAdapters {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.application.SubcontractApplicationService applicationService;
    private final com.uten.imp.features.subcontract.inquiry.SubcontractInquiryService inquiryService;
    private final com.uten.imp.features.subcontract.order.SubcontractOrderService orderService;
    private final com.uten.imp.features.subcontract.receipt.SubcontractReceiptService receiptService;
    private final com.uten.imp.features.subcontract.ret.SubcontractReturnService retService;
    private final com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService materialissueService;
    private final com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService materialreturnService;
    private final com.uten.imp.features.subcontract.waste.SubcontractWasteService wasteService;
    private static final List<FactDefinition> HEADER=List.of(new FactDefinition("totalOriginal","原币合计",true),new FactDefinition("totalLocal","本币合计",true));
    private static final List<FactDefinition> LINE=List.of(new FactDefinition("qty","数量",false),new FactDefinition("weight","重量",false),new FactDefinition("price","单价",true),new FactDefinition("amountOriginal","原币金额",true),new FactDefinition("amountLocal","本币金额",true));

    @Bean
    public PlatformColumnResourceAdapter subcontractapplicationHeaderPlatformColumns() {
        // Plan-created applications remain read-only, even for administrators (V328/V455).
        return new DocumentPlatformColumnAdapter("subcontract_application","委外申请",current,em,json,
                Set.of("subcontract_application:view"),Set.of(),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.application.SubcontractApplication.class,
                null,
                applicationService::detail,(id,header)->false,HEADER).history(applicationService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractapplicationItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_application_item","委外申请明细",current,em,json,
                Set.of("subcontract_application:view"),Set.of(),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.application.SubcontractApplication.class,
                "SELECT id,application_id FROM subcontract_application_items WHERE id IN (:ids) AND NOT is_deleted",
                applicationService::detail,(id,header)->false,LINE).history(applicationService::detailHistory,"SELECT live.id,live.application_id FROM subcontract_application_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_application_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_application_items' AND parent_table='subcontract_applications' AND CAST(CASE WHEN source_table='subcontract_application_items' AND parent_table='subcontract_applications' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_application_items WHERE application_id=:document AND NOT is_deleted");
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractinquiryHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_inquiry","委外询价",current,em,json,
                Set.of("subcontract_inquiry:view"),Set.of("subcontract_inquiry:edit"),Set.of("subcontract_inquiry:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.inquiry.SubcontractInquiry.class,
                null,
                inquiryService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(inquiryService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractinquiryItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_inquiry_item","委外询价明细",current,em,json,
                Set.of("subcontract_inquiry:view"),Set.of("subcontract_inquiry:edit"),Set.of("subcontract_inquiry:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.inquiry.SubcontractInquiry.class,
                "SELECT id,inquiry_id FROM subcontract_inquiry_items WHERE id IN (:ids) AND NOT is_deleted",
                inquiryService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(inquiryService::detailHistory,"SELECT live.id,live.inquiry_id FROM subcontract_inquiry_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_inquiry_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_inquiry_items' AND parent_table='subcontract_inquiries' AND CAST(CASE WHEN source_table='subcontract_inquiry_items' AND parent_table='subcontract_inquiries' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_inquiry_items WHERE inquiry_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("subcontract_inquiry:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractorderHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_order","委外订货",current,em,json,
                Set.of("subcontract_order:view"),Set.of("subcontract_order:edit"),Set.of("subcontract_order:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.order.SubcontractOrder.class,
                null,
                orderService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("canEdit").asBoolean(false) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(orderService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractreceiptHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_receipt","委外收货",current,em,json,
                Set.of("subcontract_receipt:view"),Set.of("subcontract_receipt:edit"),Set.of("subcontract_receipt:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.receipt.SubcontractReceipt.class,
                null,
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(receiptService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractreceiptItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_receipt_item","委外收货明细",current,em,json,
                Set.of("subcontract_receipt:view"),Set.of("subcontract_receipt:edit"),Set.of("subcontract_receipt:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.receipt.SubcontractReceipt.class,
                "SELECT id,receipt_id FROM subcontract_receipt_items WHERE id IN (:ids) AND NOT is_deleted",
                receiptService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(receiptService::detailHistory,"SELECT live.id,live.receipt_id FROM subcontract_receipt_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_receipt_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_receipt_items' AND parent_table='subcontract_receipts' AND CAST(CASE WHEN source_table='subcontract_receipt_items' AND parent_table='subcontract_receipts' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_receipt_items WHERE receipt_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest.class,receiptService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of("subcontract_receipt:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractreturnHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_return","委外退货",current,em,json,
                Set.of("subcontract_return:view"),Set.of("subcontract_return:edit"),Set.of("subcontract_return:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.ret.SubcontractReturn.class,
                null,
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(retService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractreturnItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_return_item","委外退货明细",current,em,json,
                Set.of("subcontract_return:view"),Set.of("subcontract_return:edit"),Set.of("subcontract_return:price:view","finance:view:all"),
                com.uten.imp.features.subcontract.ret.SubcontractReturn.class,
                "SELECT id,return_id FROM subcontract_return_items WHERE id IN (:ids) AND NOT is_deleted",
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(retService::detailHistory,"SELECT live.id,live.return_id FROM subcontract_return_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_return_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_return_items' AND parent_table='subcontract_returns' AND CAST(CASE WHEN source_table='subcontract_return_items' AND parent_table='subcontract_returns' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_return_items WHERE return_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest.class,retService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of("subcontract_return:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractmaterialissueHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_material_issue","委外发料",current,em,json,
                Set.of("subcontract_material_issue:view","subcontract_outbound:view"),Set.of("subcontract_material_issue:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue.class,
                null,
                materialissueService::detail,(id,header)->materialissueService.platformFieldsWritable(id),HEADER).history(materialissueService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractmaterialissueItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_material_issue_item","委外发料明细",current,em,json,
                Set.of("subcontract_material_issue:view","subcontract_outbound:view"),Set.of("subcontract_material_issue:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue.class,
                "SELECT id,issue_id FROM subcontract_material_issue_items WHERE id IN (:ids) AND NOT is_deleted",
                materialissueService::detail,(id,header)->materialissueService.platformFieldsWritable(id),LINE).history(materialissueService::detailHistory,"SELECT live.id,live.issue_id FROM subcontract_material_issue_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_material_issue_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_material_issue_items' AND parent_table='subcontract_material_issues' AND CAST(CASE WHEN source_table='subcontract_material_issue_items' AND parent_table='subcontract_material_issues' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_material_issue_items WHERE issue_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest.class,materialissueService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of());
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractmaterialreturnHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_material_return","委外退料",current,em,json,
                Set.of("subcontract_material_return:view"),Set.of("subcontract_material_return:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturn.class,
                null,
                materialreturnService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(materialreturnService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractmaterialreturnItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_material_return_item","委外退料明细",current,em,json,
                Set.of("subcontract_material_return:view"),Set.of("subcontract_material_return:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturn.class,
                "SELECT id,material_return_id FROM subcontract_material_return_items WHERE id IN (:ids) AND NOT is_deleted",
                materialreturnService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(materialreturnService::detailHistory,"SELECT live.id,live.material_return_id FROM subcontract_material_return_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_material_return_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_material_return_items' AND parent_table='subcontract_material_returns' AND CAST(CASE WHEN source_table='subcontract_material_return_items' AND parent_table='subcontract_material_returns' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_material_return_items WHERE material_return_id=:document AND NOT is_deleted")
                .documentSaveLocks(com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest.class,materialreturnService::lockPlatformColumnSave)
                .documentCreateAuthorities(Set.of("subcontract_material_return:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractwasteHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_waste","委外损耗",current,em,json,
                Set.of("subcontract_waste:view"),Set.of("subcontract_waste:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.waste.SubcontractWaste.class,
                null,
                wasteService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),HEADER).history(wasteService::detailHistory,null);
    }

    @Bean
    public PlatformColumnResourceAdapter subcontractwasteItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("subcontract_waste_item","委外损耗明细",current,em,json,
                Set.of("subcontract_waste:view"),Set.of("subcontract_waste:edit"),Set.of("finance:view:all"),
                com.uten.imp.features.subcontract.waste.SubcontractWaste.class,
                "SELECT id,waste_id FROM subcontract_waste_items WHERE id IN (:ids) AND NOT is_deleted",
                wasteService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && access.canWrite(DocumentPlatformColumnAdapter.uuid(header,"makerId")),LINE).history(wasteService::detailHistory,"SELECT live.id,live.waste_id FROM subcontract_waste_items live WHERE live.id IN (:ids) AND NOT EXISTS (SELECT 1 FROM business_record_identities retained WHERE retained.source_table='subcontract_waste_items' AND retained.source_id=CAST(live.id AS text)) UNION ALL SELECT CAST(source_id AS uuid),CAST(parent_id AS uuid) FROM business_record_identities WHERE source_table='subcontract_waste_items' AND parent_table='subcontract_wastes' AND CAST(CASE WHEN source_table='subcontract_waste_items' AND parent_table='subcontract_wastes' THEN source_id END AS uuid) IN (:ids)")
                .documentRows("SELECT id FROM subcontract_waste_items WHERE waste_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("subcontract_waste:create"));
    }
}
