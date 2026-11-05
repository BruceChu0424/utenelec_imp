package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

/** Real workflow assertions for saved input/adoption owners, not a new source-allocation policy. */
final class FrozenUnapprovalInputs {
    private FrozenUnapprovalInputs() { }
    private record Owner(String table,String parent) { }
    private static Owner owner(String family) {return switch(family){
        case "purchaseOrder"->new Owner("purchase_order_items","order_id");
        case "purchaseReceipt"->new Owner("purchase_receipt_items","receipt_id");
        case "purchaseReturn"->new Owner("purchase_return_items","return_id");
        case "subcontractOrder"->new Owner("subcontract_order_items","order_id");
        case "subcontractReceipt"->new Owner("subcontract_receipt_items","receipt_id");
        case "subcontractMaterialReturn"->new Owner("subcontract_material_return_items","material_return_id");
        case "subcontractReturn"->new Owner("subcontract_return_items","return_id");
        default->throw new IllegalArgumentException("This owner has a different receipt/settlement lifecycle");
    };}
    private static String projection(){
        List<String> fields=List.of("qty","unit_id","unit_rate","quantity_semantics","gift_qty","charged_base_qty","gift_base_qty",
                "adopted_base_qty","quantity_adoption_version","quantity_precision_policy","quantity_source_proof",
                "total_amount_input","reference_price_precision_policy","price","amount_original","amount_local","weight",
                "goods_id","color_id","order_item_id","receipt_item_id","material_issue_item_id","request_item_id","application_item_id");
        return "jsonb_build_object("+String.join(",",fields.stream().map(f->"'"+f+"',to_jsonb(item)->'"+f+"'").toList())+")";
    }
    static Object unapprove(JdbcTemplate db,DocumentUnapprovalService service,String family,UUID original,
                            DocumentUnapprovalService.UnapproveRequest request) {
        Owner owner=owner(family);
        String before=db.queryForObject("SELECT COALESCE(jsonb_agg("+projection()+" ORDER BY item.id),'[]'::jsonb)::text FROM "+owner.table()+" item WHERE item."+owner.parent()+"=?",String.class,original);
        var other=new HashMap<>(BusinessPrecisionContext.choices());
        other.put("quantity.to-base",new BusinessPrecisionContext.Choice(0,"DOWN"));
        other.put("money.reference-unit-price",new BusinessPrecisionContext.Choice(0,"DOWN"));
        Object result;
        try(var ignored=BusinessPrecisionContext.use(other)){result=service.unapprove(family,original,request);}
        catch(RuntimeException failure){throw failure;}
        catch(Exception failure){throw new IllegalStateException(failure);}
        UUID draft=db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,original);
        String inherited=db.queryForObject("SELECT COALESCE(jsonb_agg("+projection()+" ORDER BY source.key::uuid),'[]'::jsonb)::text FROM document_unapprovals lineage CROSS JOIN LATERAL jsonb_each_text(lineage.line_id_map) source JOIN "+owner.table()+" item ON item.id=CAST(source.value AS uuid) AND item."+owner.parent()+"=lineage.draft_id WHERE lineage.family=? AND lineage.original_id=? AND lineage.draft_id=?",String.class,family,original,draft);
        assertThat(inherited).as("A successor retains its original facts under the reversing actor's different choice").isEqualTo(before);
        return result;
    }
}
