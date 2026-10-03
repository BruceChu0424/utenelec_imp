package com.uten.imp.features.ai.chat;

import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.application.port.InvoicePrefillPort;
import com.uten.imp.common.files.document.DocumentImageGuard;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.PdfTextReader;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.stereotype.Component;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Quarantined local parsing. Produces suggestions for an actual form, never saves any business document. */
@Component
public class AiDocumentRouteHandler implements AiJobHandler {
    public static final String KIND = "ERP_DOCUMENT_ROUTE";
    private final AiChatAccessPolicy access;
    private final AiChatEvidence evidence;
    private final AiDocumentWorkflows workflows;
    private final InvoicePrefillPort invoices;
    public AiDocumentRouteHandler(AiChatAccessPolicy access, AiChatEvidence evidence,
                                  AiDocumentWorkflows workflows, InvoicePrefillPort invoices) {
        this.access = access; this.evidence = evidence; this.workflows = workflows; this.invoices = invoices;
    }
    @Override public String kind() { return KIND; }
    @Override public long maxInputBytes() { return 15L * 1024 * 1024; }
    @Override public Set<String> acceptedKinds() { return Set.of("XLSX", "XLS", "CSV", "DOCX", "PDF", "PNG", "JPEG", "WEBP"); }
    @Override public void authorizeSubmit(Map<String, String> params) {
        access.requireChat();
        if (!Set.of("message").containsAll(params.keySet()) || params.getOrDefault("message", "").length() > 512)
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        if (workflows.available().isEmpty()) throw new ApiException(ErrorCode.FORBIDDEN, "当前账号没有可辅助填写的业务权限");
    }
    @Override public void authorizeRead(Map<String, String> params) { authorizeSubmit(params); }
    @Override public void validateInput(Map<String, String> params, AiJobInput input) {
        if (!acceptedKinds().contains(input.kind()) || input.size() > maxInputBytes())
            throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
        DocumentKind kind = DocumentKind.valueOf(input.kind());
        if (kind.isImage()) DocumentImageGuard.requireSafe(input.bytes(), kind);
    }
    @Override public Map<String, Object> filterResultForReader(Map<String, Object> result) {
        access.requireChat();
        evidence.requireStamp(result.get("_access"));
        String workflow = String.valueOf(result.getOrDefault("workflow", "NONE"));
        if (!workflow.equals("NONE")) workflows.require(workflow);
        if (result.get("fields") instanceof Map<?, ?> fields && !fields.isEmpty()) workflows.require("EXPENSE_CLAIM");
        Map<String, Object> safe = new LinkedHashMap<>(result);
        safe.remove("_access");
        // Even a source result retained through a later permission change cannot keep old choices.
        Set<String> permitted = workflows.available().stream().map(value -> value.get("workflow")).collect(java.util.stream.Collectors.toSet());
        if (safe.get("choices") instanceof List<?> choices)
            safe.put("choices", choices.stream().filter(value -> value instanceof Map<?, ?> choice && permitted.contains(choice.get("workflow"))).toList());
        return safe;
    }
    @Override public Map<String, Object> process(AiJobContext ctx) {
        authorizeSubmit(ctx.params());
        validateInput(ctx.params(), ctx.input());
        Map<String, Object> stamp = evidence.stamp();
        ctx.progress("READING", 10);
        if (ctx.cancelled()) return Map.of();
        DocumentKind kind = DocumentKind.valueOf(ctx.input().kind());
        List<String> lines = new ArrayList<>();
        List<List<String>> sections = new ArrayList<>();
        boolean analysisOnly = analysisOnly(ctx.params().getOrDefault("message", ""));
        Map<String, Object> invoiceFields = Map.of();
        boolean truncated = false;
        boolean multiplePdfPages = false;
        String limitation = "";
        if (kind.isSpreadsheet()) {
            var grid = SpreadsheetGridReader.read(ctx.input().bytes(), kind);
            for (var sheet : grid.sheets()) {
                List<String> section = new ArrayList<>();
                section.add(sheet.name());
                for (var row : sheet.rows()) section.add(row.joinedText());
                sections.add(section);
                lines.addAll(section);
                truncated |= sheet.truncated();
            }
        } else if (kind == DocumentKind.DOCX) {
            lines.addAll(com.uten.imp.common.files.document.DocxTextReader.read(ctx.input().bytes()));
        } else if (kind == DocumentKind.PDF) {
            var pdf = PdfTextReader.read(ctx.input().bytes());
            pdf.pages().forEach(page -> { sections.add(page.lines()); lines.addAll(page.lines()); });
            truncated = pdf.truncated();
            multiplePdfPages = pdf.pageCount() > 1;
            if (pdf.scanned()) {
                if (pdf.pageCount() == 1 && canExpense() && !analysisOnly) {
                    ctx.progress("PARSING", 30);
                    var rendered = PdfTextReader.renderPages(ctx.input().bytes(), 1);
                    if (!rendered.isEmpty()) {
                        try { invoiceFields = invoices.fromImage(rendered.getFirst(), "image/jpeg"); }
                        catch (ApiException exception) { limitation = localOcrFailure(exception); }
                    }
                } else limitation = "这个 PDF 没有可读取的文字层。请提供清晰的单张票据或带文字层的文件，多张票据须分别核对。";
            }
        } else if (kind.isImage()) {
            if (canExpense() && !analysisOnly) {
                ctx.progress("PARSING", 30);
                try { invoiceFields = invoices.fromImage(ctx.input().bytes(), kind.imageMediaType()); }
                catch (ApiException exception) { limitation = localOcrFailure(exception); }
            } else limitation = "这张图片暂时无法在本地识别业务类型。请选择有权限的业务页面，再核对文件内容。";
        }
        if (ctx.cancelled()) return Map.of();
        ctx.progress("CLASSIFYING", 55);
        Classification classification = classify(lines);
        if (mixedSections(sections)) classification = new Classification("MIXED_DOCUMENT", false);
        if (!invoiceFields.isEmpty()) classification = new Classification("INVOICE", false);
        String requested = requestedWorkflow(ctx.params().getOrDefault("message", ""));
        String workflow = switch (classification.type()) {
            case "INVOICE" -> "EXPENSE_CLAIM";
            case "SALES_QUOTATION", "SALES_ORDER", "SALES_TABLE" -> requested.equals("SALES_QUOTE") ? "SALES_QUOTE" : "SALES_ORDER";
            case "COMMERCIAL_INVOICE" -> requested;
            default -> "NONE";
        };
        boolean incompatibleRequest = !requested.equals("NONE") && !requested.equals(workflow);
        boolean multiInvoice = classification.multipleInvoices() || (multiplePdfPages && classification.type().equals("INVOICE"));
        boolean unsafeSource = multiInvoice || truncated || classification.type().equals("MIXED_DOCUMENT");
        if (classification.type().equals("INVOICE") && invoiceFields.isEmpty() && !unsafeSource && !analysisOnly && canExpense())
            invoiceFields = invoices.fromText(lines);
        if (unsafeSource || analysisOnly) invoiceFields = Map.of();
        boolean permitted = !workflow.equals("NONE") && workflows.available().stream().anyMatch(value -> value.get("workflow").equals(workflow));
        boolean unsupportedSalesFormat = kind == DocumentKind.DOCX && workflow.startsWith("SALES_");
        boolean needsChoice = !permitted || incompatibleRequest || unsafeSource || analysisOnly || unsupportedSalesFormat;
        String selected = permitted && !needsChoice ? workflow : "NONE";
        // Do not return invoice fields on a non-expense destination or without the corresponding access.
        if (!canExpense()) invoiceFields = Map.of();
        List<Map<String, String>> choices = unsupportedSalesFormat || unsafeSource || analysisOnly ? List.of() : choices(classification.type()).stream()
                .filter(choice -> kind != DocumentKind.DOCX || !choice.get("workflow").startsWith("SALES_")).toList();
        String summary;
        if (analysisOnly) summary = "这是" + label(classification.type()) + "，已只做分析。";
        else if (classification.type().equals("MIXED_DOCUMENT")) summary = "文件里有不同业务的资料，请分开上传。";
        else if (unsupportedSalesFormat) summary = "这是销售资料，请另存为 Excel 或 PDF 再上传。";
        else if (multiInvoice) summary = "文件里有多张发票，请分开上传，不能合并成一笔金额。";
        else if (truncated) summary = "文件内容太多，未能完整读取，请拆分后再上传。";
        else if (incompatibleRequest) summary = "文件与要做的单据不一致，请重新选择用途。";
        else if (!permitted && !workflow.equals("NONE")) summary = "暂时不能填写这种单据，请联系管理员。";
        else if (!limitation.isBlank()) summary = limitation;
        else if (selected.equals("NONE")) summary = "暂时没看出文件用途，请选要做的单据。";
        else summary = "已识别为" + label(classification.type()) + "，正在打开填写页面。";
        var result = new LinkedHashMap<String, Object>();
        result.put("documentType", classification.type()); result.put("workflow", selected);
        result.put("title", label(classification.type())); result.put("summary", summary);
        result.put("needsChoice", selected.equals("NONE")); result.put("choices", choices);
        result.put("steps", analysisOnly || unsafeSource ? List.of("读取文件并识别用途", "确认用途并按需拆分文件")
                : List.of("读取文件并识别用途", "打开对应业务页面", "核对匹配并填写字段", "由你检查、保存和提交"));
        result.put("fields", invoiceFields);
        var confidence = new LinkedHashMap<String, String>();
        invoiceFields.forEach((key, value) -> { if (value != null && !value.toString().isBlank()) confidence.put(key, "HIGH"); });
        result.put("fieldConfidence", confidence); result.put("requiresReview", true);
        result.put("missingFields", classification.type().equals("INVOICE")
                ? List.of("invoiceNo", "issueDate", "totalAmount").stream().filter(key -> !confidence.containsKey(key)).toList() : List.of());
        result.put("source", Map.of("fileName", ctx.input().fileName(), "sha256", ctx.input().sha256()));
        result.put("_access", stamp);
        evidence.requireStamp(stamp);
        if (ctx.cancelled()) return Map.of();
        ctx.progress("READY_TO_FILL", 100);
        return result;
    }
    private boolean canExpense() { return workflows.available().stream().anyMatch(value -> value.get("workflow").equals("EXPENSE_CLAIM")); }
    private List<Map<String, String>> choices(String type) {
        return workflows.available().stream().filter(value -> switch (type) {
            case "INVOICE" -> value.get("workflow").equals("EXPENSE_CLAIM");
            case "SALES_QUOTATION", "SALES_ORDER", "SALES_TABLE" -> value.get("workflow").startsWith("SALES_");
            case "UNKNOWN" -> true;
            case "COMMERCIAL_INVOICE" -> true;
            default -> false;
        }).toList();
    }
    private static String localOcrFailure(ApiException exception) {
        if (exception.getCode() == ErrorCode.FORBIDDEN || exception.getCode() == ErrorCode.UNAUTHORIZED) throw exception;
        if (exception.getCode() == ErrorCode.BUSINESS) return "暂时没认出图片内容，请换清晰图片或文字版 PDF。";
        throw exception;
    }
    static Classification classify(List<String> lines) {
        String text = Normalizer.normalize(String.join("\n", lines), Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        boolean chineseInvoice = contains(text, "发票号码", "价税合计", "增值税专用发票", "增值税普通发票", "电子发票");
        boolean invoice = chineseInvoice || contains(text, "tax invoice");
        boolean proforma = contains(text, "proforma invoice", "pro forma invoice", "pro-forma invoice", "形式发票");
        boolean commercial = !invoice && !proforma && contains(text, "commercial invoice", "商业发票", "invoice no", "invoice number");
        var explicitFamilies = new java.util.HashSet<String>();
        if (invoice) explicitFamilies.add("INVOICE");
        if (commercial) explicitFamilies.add("COMMERCIAL_INVOICE");
        if (contains(text, "工资表", "工资明细", "薪酬", "员工档案", "入职登记", "离职申请", "payroll")) explicitFamilies.add("HR");
        if (contains(text, "库存盘点", "盘点表", "inventory count", "入库单", "出库单")) explicitFamilies.add("WAREHOUSE");
        if (contains(text, "生产任务单", "生产日报", "工序日报", "生产计划")) explicitFamilies.add("PRODUCTION");
        if (contains(text, "采购订单", "采购订货单")) explicitFamilies.add("PURCHASE");
        if (contains(text, "报价单", "quotation", "报价日期", "订货单", "销售订单", "sales order", "purchase order", "order confirmation",
                "proforma invoice", "pro forma invoice", "pro-forma invoice", "形式发票")) explicitFamilies.add("SALES");
        if (Pattern.compile("(?m)^\\s*(?:(?:销售|采购|劳动|服务)?合同|(?:sales |purchase |employment )?(?:contract|agreement))\\s*$")
                .matcher(text).find()) explicitFamilies.add("CONTRACT");
        if (explicitFamilies.size() > 1) return new Classification("MIXED_DOCUMENT", false);
        if (!invoice && proforma)
            return new Classification("SALES_ORDER", false);
        if (commercial)
            return new Classification("COMMERCIAL_INVOICE", com.uten.imp.common.files.document.InvoiceMultiplicity.multiple(lines));
        if (invoice) {
            return new Classification("INVOICE", com.uten.imp.common.files.document.InvoiceMultiplicity.multiple(lines));
        }
        // Sensitive/non-sales document families take priority over incidental product/quantity words.
        if (contains(text, "工资表", "工资明细", "薪酬", "员工档案", "入职登记", "离职申请", "payroll")) return new Classification("HR_DOCUMENT", false);
        if (contains(text, "库存盘点", "盘点表", "inventory count", "入库单", "出库单")) return new Classification("WAREHOUSE_DOCUMENT", false);
        if (contains(text, "生产任务单", "生产日报", "工序日报", "生产计划")) return new Classification("PRODUCTION_DOCUMENT", false);
        if (contains(text, "采购订单", "采购订货单")) return new Classification("PURCHASE_DOCUMENT", false);
        if (contains(text, "报价单", "quotation", "price quotation", "报价日期")) return new Classification("SALES_QUOTATION", false);
        if (contains(text, "订货单", "销售订单", "sales order", "purchase order", "order confirmation")) return new Classification("SALES_ORDER", false);
        if (contains(text, "品名", "产品名称", "货品名称", "item no", "item code", "description")
                && contains(text, "数量", "qty", "quantity") && contains(text, "单价", "unit price", "价格")) return new Classification("SALES_TABLE", false);
        if (contains(text, "合同", "agreement", "contract")) return new Classification("CONTRACT", false);
        return new Classification("UNKNOWN", false);
    }
    static String requestedWorkflow(String message) {
        String text = Normalizer.normalize(message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        // Only the user's explicit purpose, never instructions embedded in a document.
        if (contains(text, "报销", "expense claim", "reimbursement")) return "EXPENSE_CLAIM";
        if (Pattern.compile("(?:生成|新建|创建|填写|做|开).{0,8}(?:订货|销售订单)|(?:create|fill).{0,12}sales order").matcher(text).find()) return "SALES_ORDER";
        if (Pattern.compile("(?:生成|新建|创建|填写|做|开).{0,8}报价|(?:create|fill).{0,12}quotation").matcher(text).find()) return "SALES_QUOTE";
        return "NONE";
    }
    /** An explicit refusal takes precedence over positive words inside the same sentence. */
    static boolean analysisOnly(String message) {
        String text = Normalizer.normalize(message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        return Pattern.compile("(?:不要|不需要|无需|禁止|别|勿|不用|不能).{0,20}(?:生成|新建|创建|填写|开单|保存|报销|订货|报价|单据)"
                + "|(?:只|仅|单纯).{0,8}(?:分析|识别|查看|看看|了解|检查|看一下|读一下)"
                + "|(?:do not|don't|don’t|never|no need to).{0,20}(?:create|fill|generate|save|submit)"
                + "|(?:only|just)\\s+(?:analy[sz]e|identify|inspect|read|view)"
                + "|(?:analy[sz]e|identify|inspect|read|view)\\s+only").matcher(text).find();
    }
    /** Preserve sheet/page boundaries: a payroll, contract or invoice cannot borrow sales rows from another section. */
    private static boolean mixedSections(List<List<String>> sections) {
        var families = new java.util.HashSet<String>();
        for (List<String> section : sections) {
            String type = classify(section).type();
            if (type.equals("MIXED_DOCUMENT")) return true;
            if (type.equals("UNKNOWN")) continue;
            families.add(type.startsWith("SALES_") ? "SALES" : type);
        }
        return families.size() > 1;
    }
    private static boolean contains(String text, String... words) { return java.util.Arrays.stream(words).anyMatch(text::contains); }
    private static String label(String type) { return switch (type) {
        case "INVOICE" -> "发票"; case "SALES_QUOTATION" -> "报价文件"; case "SALES_ORDER" -> "客户订货文件";
        case "SALES_TABLE" -> "货品报价明细"; case "HR_DOCUMENT" -> "人事资料"; case "WAREHOUSE_DOCUMENT" -> "仓库资料";
        case "COMMERCIAL_INVOICE" -> "商业发票";
        case "MIXED_DOCUMENT" -> "包含多种业务资料的文件";
        case "PRODUCTION_DOCUMENT" -> "生产资料"; case "PURCHASE_DOCUMENT" -> "采购资料"; case "CONTRACT" -> "合同资料";
        default -> "待确认用途的文件";
    }; }
    record Classification(String type, boolean multipleInvoices) {}
}
