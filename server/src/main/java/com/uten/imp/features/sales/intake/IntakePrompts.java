package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.AiCompletionPort.AiCompletionRequest;
import com.uten.imp.application.port.AiCompletionPort.AiContentPart;
import com.uten.imp.application.port.AiCompletionPort.AiImage;
import com.uten.imp.application.port.AiCompletionPort.AiText;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 客户文件识别的 AI 提示词与 JSON Schema(纯函数; SPEC §5.3)。
 *
 * <p>提示词一律英文、只要 JSON; 客户文件内容一律作为不可信文本({@code AiText(..., true)})传入, 由网关加隔离标记。
 * 共同约束: 不编造(没有就 null)、照抄客户原文(不翻译)、数字用 JSON 数字、我司(卖方)是
 * ZHONGSHAN UTEN ELECTRIC CO.,LTD, 绝不能当成买方。表头模式从不发送单价与金额。
 */
final class IntakePrompts {

    static final String SELLER = "ZHONGSHAN UTEN ELECTRIC CO.,LTD";
    static final String PURPOSE_COLUMNS = "SALES_INTAKE_COLUMNS";
    static final String PURPOSE_HEADER = "SALES_INTAKE_HEADER";
    static final String PURPOSE_DOCUMENT = "SALES_INTAKE_DOCUMENT";
    static final String PURPOSE_MATCH = "SALES_INTAKE_MATCH";
    static final int MAX_OUTPUT_CAP = 8000;

    private static final String COMMON_RULES = """
            Rules:
            - Never invent values. Use null when a value is absent.
            - Copy the customer's text verbatim (no translation, no spelling fixes).
            - Numbers must be JSON numbers without currency symbols or thousands separators.
            - Our company (the seller) is %s. Never report it as the buyer or customer.
            - Respond with a single JSON object only.""".formatted(SELLER);

    private IntakePrompts() {
    }

    // ------------------------------------------------------------------ column mapping

    static final List<String> ROLE_NAMES = List.of("LINE_NO", "PART_NO", "DESCRIPTION", "SERIES", "COLOR", "QTY", "UNIT",
            "UNIT_PRICE", "AMOUNT", "PCS_PER_CTN", "CTN", "REMARK", "IGNORED");

    static AiCompletionRequest columns(String table, UUID jobId) {
        String system = """
                You map the columns of a customer's quotation, proforma invoice or purchase order spreadsheet for an ERP import.
                Each input line is one spreadsheet row: "R<row number> | <column letter>:<cell text> | ...".
                Find the header row of the goods table and the role of each column of that table.
                Roles: LINE_NO (sequence number), PART_NO (customer's item/model/part number), DESCRIPTION (goods description, any language),
                SERIES, COLOR, QTY (ordered quantity), UNIT, UNIT_PRICE, AMOUNT (line total), PCS_PER_CTN, CTN (number of cartons),
                REMARK, IGNORED (weights, volume, size, pictures, packing).
                Placeholders such as ⟨PHONE_1⟩ or ⟨SELLER_1⟩ stand for hidden text.
                Only use column letters that appear in the rows. If there is no goods table, return {"headerRow": null, "columns": []}.
                Output: {"headerRow": <row number or null>, "columns": [{"column": "<column letter>", "role": "<ROLE>"}]}.
                """ + COMMON_RULES;
        Map<String, Object> column = objectSchema(Map.of(
                "column", Map.of("type", "string"),
                "role", Map.of("type", "string", "enum", ROLE_NAMES)), List.of("column", "role"));
        Map<String, Object> schema = objectSchema(Map.of(
                "headerRow", Map.of("type", List.of("integer", "null")),
                "columns", Map.of("type", "array", "items", column)),
                List.of("headerRow", "columns"));
        return new AiCompletionRequest(PURPOSE_COLUMNS, system, List.of(new AiText(table, true)), "intake_columns", schema,
                600, jobId);
    }

    // ------------------------------------------------------------------ header

    static final List<String> HEADER_FIELDS = List.of("buyerName", "buyerAddress", "contactName", "docNo", "docDate",
            "incoterm", "port", "paymentTerms", "country");

    static AiCompletionRequest header(String minimizedHeader, UUID jobId) {
        String system = """
                Extract the buyer (customer) information from the top part of a customer's quotation, proforma invoice or purchase order.
                Each input line is one spreadsheet row: "R<row number> | <column letter>:<cell text> | ...".
                Placeholders such as ⟨EMAIL_1⟩, ⟨PHONE_1⟩ and ⟨TAXID_1⟩ stand for hidden contact details; return them unchanged when they are the value.
                Fields: buyerName (company name of the buyer), buyerAddress, contactName (person), docNo (document number of the file),
                docDate (YYYY-MM-DD), incoterm (EXW/FOB/CIF/CFR/DDP/DAP/FCA/CPT/CIP), port, paymentTerms, country (English country name of the buyer).
                Output: {"buyerName": ..., "buyerAddress": ..., "contactName": ..., "docNo": ..., "docDate": ..., "incoterm": ..., "port": ...,
                "paymentTerms": ..., "country": ...} with null for anything absent.
                """ + COMMON_RULES;
        Map<String, Object> props = new LinkedHashMap<>();
        for (String f : HEADER_FIELDS) {
            props.put(f, Map.of("type", List.of("string", "null")));
        }
        return new AiCompletionRequest(PURPOSE_HEADER, system, List.of(new AiText(minimizedHeader, true)), "intake_header",
                objectSchema(props, HEADER_FIELDS), 800, jobId);
    }

    // ------------------------------------------------------------------ whole document (PDF text / image)

    static final List<String> LINE_FIELDS = List.of("lineNo", "partNo", "description", "series", "color", "qty", "unit",
            "unitPrice", "amount");

    private static final String DOCUMENT_SYSTEM = """
            Extract the header and every goods line from a customer's quotation, proforma invoice or purchase order.
            Header fields: buyerName, buyerAddress, contactName, docNo, docDate (YYYY-MM-DD), incoterm, port, paymentTerms,
            country (English country name of the buyer), currency (ISO code such as USD or CNY when written, else null).
            Line fields: lineNo, partNo (customer's item/model number), description (verbatim, keep every language exactly as written),
            series, color, qty (number), unit, unitPrice (number), amount (number).
            Include only goods lines. Skip totals, deposits, balances, bank details, remarks and the seller's own details.
            Placeholders such as ⟨EMAIL_1⟩ and ⟨PHONE_1⟩ stand for hidden contact details; ⟨SELLER_1⟩ stands for our own brand name.
            Copy placeholders unchanged.
            Output: {"header": {...}, "currency": ..., "lines": [{...}]}.
            """ + COMMON_RULES;

    static AiCompletionRequest documentText(String minimizedText, int expectedLines, UUID jobId) {
        return new AiCompletionRequest(PURPOSE_DOCUMENT, DOCUMENT_SYSTEM, List.of(new AiText(minimizedText, true)),
                "intake_document", documentSchema(), outputTokens(expectedLines), jobId);
    }

    static AiCompletionRequest documentImages(List<byte[]> images, String mediaType, UUID jobId) {
        List<AiContentPart> parts = new ArrayList<>();
        parts.add(new AiText("The following images are pages of one customer document.", false));
        for (byte[] image : images) {
            parts.add(new AiImage(image, mediaType));
        }
        return new AiCompletionRequest(PURPOSE_DOCUMENT, DOCUMENT_SYSTEM, parts, "intake_document", documentSchema(),
                MAX_OUTPUT_CAP, jobId);
    }

    static int outputTokens(int lines) {
        return Math.max(1000, Math.min(MAX_OUTPUT_CAP, 400 + lines * 120));
    }

    private static Map<String, Object> documentSchema() {
        Map<String, Object> header = new LinkedHashMap<>();
        for (String f : HEADER_FIELDS) {
            header.put(f, Map.of("type", List.of("string", "null")));
        }
        Map<String, Object> line = new LinkedHashMap<>();
        for (String f : LINE_FIELDS) {
            boolean number = f.equals("qty") || f.equals("unitPrice") || f.equals("amount");
            line.put(f, Map.of("type", number ? List.of("number", "null") : List.of("string", "null")));
        }
        return objectSchema(Map.of(
                "header", objectSchema(header, HEADER_FIELDS),
                "currency", Map.of("type", List.of("string", "null")),
                "lines", Map.of("type", "array", "items", objectSchema(line, LINE_FIELDS))),
                List.of("header", "currency", "lines"));
    }

    // ------------------------------------------------------------------ goods disambiguation

    /** 一行待选: 客户文字 + 候选编号列表(编号是本次提示里的临时引用, 如 g3)。 */
    record MatchLine(String lineKey, String customerText, List<String> candidateRefs) {
    }

    /**
     * @param catalog 引用 → 「编号 | 名称 | 型号 | 系列 | 颜色」(我司货品资料, 不是客户数据)
     * @param history 客户买过的货品引用(也在 catalog 里)
     */
    static AiCompletionRequest match(List<MatchLine> lines, Map<String, String> catalog, List<String> history, UUID jobId) {
        String system = """
                You help match lines of a customer's order to OUR goods catalog.
                For each customer line you get the customer's text and the refs of candidate goods from our catalog.
                The catalog lists each ref as "ref | code | name | model | series | colour"; the customer's purchase history is a list of refs.
                Choose the single ref that is the same product as the customer line, or null when none clearly matches.
                Only choose a ref listed for that line or in the purchase history. Never invent refs.
                Output: {"choices": [{"lineKey": "<key>", "choice": "<ref or null>", "confidence": "high|medium|low",
                "reason": "<short reason in simple Chinese, at most 20 characters>"}]}.
                """ + COMMON_RULES;
        StringBuilder customer = new StringBuilder();
        for (MatchLine l : lines) {
            customer.append(l.lineKey()).append(" | ").append(l.customerText()).append('\n');
        }
        StringBuilder ours = new StringBuilder("Catalog:\n");
        for (Map.Entry<String, String> e : catalog.entrySet()) {
            ours.append(e.getKey()).append(" | ").append(e.getValue()).append('\n');
        }
        ours.append("\nCandidates per line:\n");
        for (MatchLine l : lines) {
            ours.append(l.lineKey()).append(": ").append(String.join(", ", l.candidateRefs())).append('\n');
        }
        if (!history.isEmpty()) {
            ours.append("\nCustomer purchase history refs: ").append(String.join(", ", history)).append('\n');
        }
        Map<String, Object> choice = objectSchema(Map.of(
                "lineKey", Map.of("type", "string"),
                "choice", Map.of("type", List.of("string", "null")),
                "confidence", Map.of("type", "string", "enum", List.of("high", "medium", "low")),
                "reason", Map.of("type", "string")), List.of("lineKey", "choice", "confidence", "reason"));
        Map<String, Object> schema = objectSchema(Map.of("choices", Map.of("type", "array", "items", choice)),
                List.of("choices"));
        return new AiCompletionRequest(PURPOSE_MATCH, system,
                List.of(new AiText("Customer lines:\n" + customer.toString().stripTrailing(), true),
                        new AiText(ours.toString().stripTrailing(), false)),
                "intake_match", schema, outputTokens(lines.size()), jobId);
    }

    private static Map<String, Object> objectSchema(Map<String, Object> properties, List<String> required) {
        Map<String, Object> schema = new LinkedHashMap<>();
        schema.put("type", "object");
        schema.put("properties", properties);
        schema.put("required", required);
        schema.put("additionalProperties", false);
        return schema;
    }
}
