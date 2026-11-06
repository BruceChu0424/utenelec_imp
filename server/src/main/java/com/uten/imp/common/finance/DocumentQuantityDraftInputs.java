package com.uten.imp.common.finance;

import java.util.Map;

/** New draft quantities use this action's exact policy; old adoption evidence is never copied. */
public final class DocumentQuantityDraftInputs {
    private DocumentQuantityDraftInputs() { }
    public static Map<String,String> chargedAndGift() {
        String charged="fn_document_quantity_to_base(source.qty,source.unit_rate,fn_business_precision_snapshot(),true)";
        String physical="fn_document_quantity_to_base(source.qty+CASE WHEN source.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN source.gift_qty ELSE 0 END,source.unit_rate,fn_business_precision_snapshot(),true)";
        return Map.of("charged_base_qty",charged,"gift_base_qty","("+physical+"-"+charged+")");
    }
}
