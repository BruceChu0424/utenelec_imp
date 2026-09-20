package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.ImportedDocumentLifecycleCapabilities;
import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.UUID;

/** Shared origin boundary for receipt actions and actionable IQC/warehouse task projections. */
public final class ProcurementReceiptOriginPolicy {
    private ProcurementReceiptOriginPolicy() { }

    public static void requireNative(EntityManager em,String type,Collection<UUID> ids) {
        if(ids.isEmpty())return;
        if(!em.createNativeQuery(historySql(type)).setParameter("ids",ids).getResultList().isEmpty())reject();
    }
    public static boolean isNative(EntityManager em,String type,UUID id) {
        return ((Number)em.createNativeQuery("SELECT count(*) FROM "+table(type)
                +" WHERE id=:id AND legacy_id IS NULL AND is_deleted=FALSE").setParameter("id",id).getSingleResult()).longValue()==1;
    }
    private static String historySql(String type){return "SELECT id FROM "+table(type)+" WHERE id IN(:ids) AND legacy_id IS NOT NULL";}
    public static String currentInspectionReceipt(String inspectionAlias) {
        if(!inspectionAlias.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("Invalid internal inspection alias");
        return "(("+inspectionAlias+".receipt_type='PURCHASE' AND EXISTS(SELECT 1 FROM purchase_receipts current_receipt WHERE current_receipt.id="
                +inspectionAlias+".receipt_id AND current_receipt.legacy_id IS NULL AND current_receipt.is_deleted=FALSE)) OR ("
                +inspectionAlias+".receipt_type='SUBCONTRACT' AND EXISTS(SELECT 1 FROM subcontract_receipts current_receipt WHERE current_receipt.id="
                +inspectionAlias+".receipt_id AND current_receipt.legacy_id IS NULL AND current_receipt.is_deleted=FALSE)))";
    }
    private static String table(String type) {
        return switch(type){case "PURCHASE"->"purchase_receipts";case "SUBCONTRACT"->"subcontract_receipts";
            default->throw new ApiException(ErrorCode.VALIDATION_FAILED,"未知收货类型");};
    }
    private static void reject(){throw new ApiException(ErrorCode.BUSINESS,ImportedDocumentLifecycleCapabilities.READ_ONLY_REASON);}
}
