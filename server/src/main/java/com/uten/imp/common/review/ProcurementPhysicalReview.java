package com.uten.imp.common.review;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Physical receipt/return review never changes commercial, custody or source identities. */
public final class ProcurementPhysicalReview {
    private ProcurementPhysicalReview() { }
    private static final List<String> HEADER = List.of("bill_no", "bill_date", "supplier_id", "warehouse_id",
            "currency_id", "exchange_rate", "tax_rate", "settlement_method_id", "settlement_style_legacy",
            "sender_id", "receiver_id", "receiver_legacy_id", "receiver_name", "purchaser_id", "maker_legacy_id", "maker_name",
            "approver_legacy_id", "approver_name", "last_date");
    private static final List<String> LINE = List.of("goods_id", "color_id", "unit_id", "unit_rate",
            "order_item_id", "receipt_item_id", "price", "replacement_intent", "gift_replacement_intent", "source_doc_no", "order_no",
            "return_no", "receipt_no", "check_qty", "order_qty", "girth_qty", "step_legacy_id");

    public static void constrain(EntityManager em, ObjectMapper json, DocumentDraftReview.Kind kind,
                                 java.util.UUID id, Object request) {
        if (!Set.of(DocumentDraftReview.Kind.PURCHASE_RECEIPT, DocumentDraftReview.Kind.PURCHASE_RETURN,
                DocumentDraftReview.Kind.SUBCONTRACT_RECEIPT, DocumentDraftReview.Kind.SUBCONTRACT_RETURN).contains(kind))
            throw new IllegalArgumentException("Unsupported physical review registration");
        try {
            constrain(json, json.readTree(DocumentDraftReview.storedInputs(em, kind, id)), request);
        } catch (com.fasterxml.jackson.core.JsonProcessingException failure) {
            throw new IllegalStateException("Cannot read the retained review inputs", failure);
        }
    }

    static void constrain(ObjectMapper json, JsonNode before, Object request) {
        ObjectNode incoming = json.valueToTree(request);
        JsonNode header = before.path("header");
        if (!header.path("legacy_id").isMissingNode() && !header.path("legacy_id").isNull())
            throw new ApiException(ErrorCode.CONFLICT, "历史原始单据不能修改后审核");
        if (incoming.path("confirmGiftSemantics").asBoolean(false))
            throw new ApiException(ErrorCode.CONFLICT, "赠品口径变更请由制单人在草稿中重新确认");
        freeze(incoming, header, HEADER);
        JsonNode items = incoming.path("items");
        if (!items.isArray() || items.isEmpty() || items.size() != before.path("items").size())
            throw changed("明细行");
        Map<String, JsonNode> original = new HashMap<>();
        for (JsonNode row : before.path("items")) original.put(row.path("id").asText(), row);
        Set<String> seen = new HashSet<>();
        for (JsonNode row : items) {
            String source = row.path("sourceItemId").asText(null);
            String fieldsSource = row.path("platformFields").path("sourceRecordId").asText(null);
            if (source == null) source = fieldsSource;
            if (source == null || !original.containsKey(source) || !seen.add(source)
                    || (fieldsSource != null && !source.equals(fieldsSource))) throw changed("明细来源");
            freeze((ObjectNode) row, original.get(source), LINE);
        }
        try {
            json.readerForUpdating(request).readValue(incoming);
        } catch (java.io.IOException failure) {
            throw new IllegalStateException("Cannot retain frozen review inputs", failure);
        }
    }

    private static void freeze(ObjectNode request, JsonNode stored, List<String> columns) {
        for (String column : columns) {
            String name = camel(column);
            if (!request.has(name) || !stored.has(column)) continue;
            JsonNode proposed = request.get(name), original = stored.get(column);
            if (proposed != null && !proposed.isNull() && !same(proposed, original)) throw changed(name);
            request.set(name, original);
        }
    }

    private static boolean same(JsonNode left, JsonNode right) {
        if (left.isNumber() && right.isNumber()) return left.decimalValue().compareTo(right.decimalValue()) == 0;
        return left.equals(right);
    }
    private static String camel(String column) {
        StringBuilder result = new StringBuilder(); boolean upper = false;
        for (char character : column.toCharArray()) {
            if (character == '_') upper = true;
            else { result.append(upper ? Character.toUpperCase(character) : character); upper = false; }
        }
        return result.toString();
    }
    private static ApiException changed(String label) {
        return new ApiException(ErrorCode.CONFLICT, "审核不能更换原单据的" + label + "；请制单人重新核对草稿");
    }
}
