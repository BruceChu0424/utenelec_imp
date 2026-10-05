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

/**
 * Quarantined local parsing. Produces suggestions for an actual form, never saves any business document.
 * ADR-150: a recognized destination becomes a one-time OPEN_GUIDED_FORM confirmation card; the form is
 * opened and filled only after the user confirms it, never automatically.
 */
@Component
public class AiDocumentRouteHandler implements AiJobHandler {
    public static final String KIND = "ERP_DOCUMENT_ROUTE";
    private final AiChatAccessPolicy access;
    private final AiChatEvidence evidence;
    private final AiDocumentWorkflows workflows;
    private final InvoicePrefillPort invoices;
    private final AiChatPageGuideCatalog pages;
    private final AiChatActionProposalService proposals;
    public AiDocumentRouteHandler(AiChatAccessPolicy access, AiChatEvidence evidence,
                                  AiDocumentWorkflows workflows, InvoicePrefillPort invoices, AiChatPageGuideCatalog pages,
                                  AiChatActionProposalService proposals) {
        this.access = access; this.evidence = evidence; this.workflows = workflows; this.invoices = invoices; this.pages = pages;
        this.proposals = proposals;
    }
    @Override public String kind() { return KIND; }
    @Override public long maxInputBytes() { return 15L * 1024 * 1024; }
    @Override public Set<String> acceptedKinds() { return Set.of("XLSX", "XLS", "CSV", "DOCX", "PDF", "PNG", "JPEG", "WEBP"); }
    @Override public void authorizeSubmit(Map<String, String> params) {
        access.requireChat();
        if (params == null || params.values().stream().anyMatch(java.util.Objects::isNull)
                || !Set.of("message", "pageRoute").containsAll(params.keySet()) || params.getOrDefault("message", "").length() > 512)
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        String route = params.getOrDefault("pageRoute", "");
        if (route.length() > 240 || (!route.isEmpty() && !route.matches("/[A-Za-z0-9/_-]*")))
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        if (!route.isEmpty()) pages.resolve(route, null);
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
        requireRouting(result.get("_routing"));
        String workflow = String.valueOf(result.getOrDefault("workflow", "NONE"));
        if (!workflow.equals("NONE")) workflows.require(workflow);
        if (result.get("fields") instanceof Map<?, ?> fields && !fields.isEmpty()) workflows.require("EXPENSE_CLAIM");
        Map<String, Object> safe = new LinkedHashMap<>(result);
        safe.remove("_access");
        safe.remove("_routing");
        // Even a source result retained through a later permission change cannot keep old choices.
        Set<String> permitted = workflows.available().stream().map(value -> value.get("workflow")).collect(java.util.stream.Collectors.toSet());
        if (safe.get("choices") instanceof List<?> choices)
            safe.put("choices", choices.stream().filter(value -> value instanceof Map<?, ?> choice && permitted.contains(choice.get("workflow"))).toList());
        safe.put("actions", proposals.refreshCards(result.get("actions")).stream()
                .filter(card -> card.get("args") instanceof Map<?, ?> args && permitted.contains(args.get("workflow"))).toList());
        return safe;
    }
    @Override public Map<String, Object> process(AiJobContext ctx) {
        authorizeSubmit(ctx.params());
        validateInput(ctx.params(), ctx.input());
        Map<String, Object> stamp = evidence.stamp();
        Map<String, Object> routing = routingContext(ctx.params().getOrDefault("pageRoute", ""));
        String requested = requestedWorkflow(ctx.params().getOrDefault("message", ""));
        String preferred = preferredWorkflow(routing);
        ctx.progress("READING", 10);
        if (ctx.cancelled()) return Map.of();
        DocumentKind kind = DocumentKind.valueOf(ctx.input().kind());
        List<String> lines = new ArrayList<>();
        List<List<String>> sections = new ArrayList<>();
        boolean analysisOnly = analysisOnly(ctx.params().getOrDefault("message", ""));
        boolean explicitExpense = requested.equals("EXPENSE_CLAIM");
        boolean allowExpenseImage = !analysisOnly && !requested.startsWith("SALES_")
                && (explicitExpense || !preferred.startsWith("SALES_"));
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
                if (pdf.pageCount() == 1 && canExpense() && allowExpenseImage) {
                    ctx.progress("PARSING", 30);
                    var rendered = PdfTextReader.renderPages(ctx.input().bytes(), 1);
                    if (!rendered.isEmpty()) {
                        try { invoiceFields = invoices.fromImage(rendered.getFirst(), "image/jpeg"); }
                        catch (ApiException exception) { limitation = localOcrFailure(exception); }
                    }
                } else limitation = "这个 PDF 没有可读取的文字层。请提供清晰的单张票据或带文字层的文件，多张票据须分别核对。";
            }
        } else if (kind.isImage()) {
            if (canExpense() && allowExpenseImage) {
                ctx.progress("PARSING", 30);
                try { invoiceFields = invoices.fromImage(ctx.input().bytes(), kind.imageMediaType()); }
                catch (ApiException exception) { limitation = localOcrFailure(exception); }
            } else limitation = "这张图片暂时无法在本地识别业务类型。请选择有权限的业务页面，再核对文件内容。";
        }
        if (ctx.cancelled()) return Map.of();
        ctx.progress("CLASSIFYING", 55);
        var parsed = sections.isEmpty() ? AiDocumentClassifier.classify(lines) : AiDocumentClassifier.classifySections(sections);
        boolean goodsTable = sections.isEmpty() ? AiDocumentClassifier.hasGoodsTable(lines)
                : sections.stream().anyMatch(AiDocumentClassifier::hasGoodsTable);
        Classification classification = new Classification(parsed.type(), parsed.multipleInvoices());
        // A local OCR amount alone does not prove that a trade image is a tax invoice.
        // OCR also cannot erase an already recognized payroll, contract or mixed source.
        if (classification.type().equals("UNKNOWN") && credibleInvoiceFields(invoiceFields))
            classification = new Classification("INVOICE", false);
        boolean partialExpense = classification.type().equals("UNKNOWN") && explicitExpense && !invoiceFields.isEmpty();
        if (classification.type().equals("UNKNOWN") && !explicitExpense) invoiceFields = Map.of();
        String workflow = partialExpense ? "EXPENSE_CLAIM" : switch (classification.type()) {
            case "INVOICE" -> "EXPENSE_CLAIM";
            case "SALES_QUOTATION", "SALES_ORDER" -> requested.startsWith("SALES_") ? requested
                    : preferred.startsWith("SALES_") ? preferred : "SALES_ORDER";
            case "SALES_TABLE" -> requested.startsWith("SALES_") ? requested : preferred.startsWith("SALES_") ? preferred : "NONE";
            case "COMMERCIAL_INVOICE" -> !requested.equals("NONE") ? requested
                    : goodsTable && preferred.startsWith("SALES_") ? preferred : "NONE";
            default -> "NONE";
        };
        boolean incompatibleRequest = !requested.equals("NONE") && !requested.equals(workflow);
        boolean multiInvoice = classification.multipleInvoices() || (multiplePdfPages && classification.type().equals("INVOICE"));
        boolean unsafeSource = multiInvoice || truncated || classification.type().equals("MIXED_DOCUMENT");
        if (classification.type().equals("INVOICE") && invoiceFields.isEmpty() && !unsafeSource && !analysisOnly
                && !incompatibleRequest && canExpense())
            invoiceFields = invoices.fromText(lines);
        if (unsafeSource || analysisOnly || incompatibleRequest) invoiceFields = Map.of();
        boolean permitted = !workflow.equals("NONE") && workflows.available().stream().anyMatch(value -> value.get("workflow").equals(workflow));
        boolean unsupportedSalesFormat = kind == DocumentKind.DOCX && workflow.startsWith("SALES_");
        boolean needsChoice = !permitted || incompatibleRequest || unsafeSource || analysisOnly || unsupportedSalesFormat;
        String selected = permitted && !needsChoice ? workflow : "NONE";
        // Do not return invoice fields on a non-expense destination or without the corresponding access.
        if (!canExpense() || !selected.equals("EXPENSE_CLAIM")) invoiceFields = Map.of();
        List<Map<String, String>> choices = unsupportedSalesFormat || unsafeSource || analysisOnly ? List.of() : choices(classification.type(), requested.equals("NONE") ? preferred : requested).stream()
                .filter(choice -> kind != DocumentKind.DOCX || !choice.get("workflow").startsWith("SALES_")).toList();
        String summary;
        if (analysisOnly) summary = "这是" + label(classification.type()) + "，已只做分析。";
        else if (classification.type().equals("MIXED_DOCUMENT")) summary = "文件里有不同业务的资料，请分开上传。";
        else if (unsupportedSalesFormat) summary = "这是销售资料，请另存为 Excel 或 PDF 再上传。";
        else if (multiInvoice) summary = "文件里有多张发票，请分开上传，不能合并成一笔金额。";
        else if (truncated) summary = "文件内容太多，未能完整读取，请拆分后再上传。";
        else if (incompatibleRequest) summary = "文件与要做的单据不一致，请重新选择用途。";
        else if (!permitted && !workflow.equals("NONE")) summary = "暂时不能填写这种单据，请联系管理员。";
        else if (partialExpense && selected.equals("EXPENSE_CLAIM")) summary = "已读到部分信息，请核对后填写报销单。";
        else if (!limitation.isBlank()) summary = limitation;
        else if (selected.equals("NONE")) summary = "暂时没看出文件用途，请选要做的单据。";
        else summary = "已识别为" + label(classification.type()) + "。请在下面的确认卡里确认后，我再打开" + formName(selected)
                + "并填入识别结果。";
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
        result.put("missingFields", workflow.equals("EXPENSE_CLAIM")
                ? List.of("invoiceNo", "issueDate", "totalAmount").stream().filter(key -> !confidence.containsKey(key)).toList() : List.of());
        result.put("source", Map.of("fileName", ctx.input().fileName(), "sha256", ctx.input().sha256()));
        evidence.requireStamp(stamp);
        String pageRoute = ctx.params().getOrDefault("pageRoute", "");
        List<Map<String, Object>> actions = new ArrayList<>();
        if (!selected.equals("NONE")) {
            actions.add(guidedCard(ctx, selected, classification.type(), pageRoute, invoiceFields.size()));
        } else {
            for (var choice : choices.stream().limit(3).toList())
                actions.add(guidedCard(ctx, choice.get("workflow"), classification.type(), pageRoute, invoiceFields.size()));
        }
        result.put("actions", List.copyOf(actions));
        result.put("_access", stamp);
        result.put("_routing", routing);
        evidence.requireStamp(stamp);
        requireRouting(routing);
        if (ctx.cancelled()) return Map.of();
        ctx.progress("READY_TO_FILL", 100);
        return result;
    }
    /** One-time card: opening the form and filling it happens only after the user confirms. */
    private Map<String, Object> guidedCard(AiJobContext ctx, String workflow, String type, String pageRoute, int fieldCount) {
        List<String> lines = new ArrayList<>();
        lines.add("文件: " + truncate(ctx.input().fileName(), 120));
        lines.add("识别为: " + label(type));
        lines.add("将打开: " + formName(workflow));
        lines.add(workflow.startsWith("SALES_")
                ? "打开后由页面逐行识别并填入货品，黄框是需要你核对的值。"
                : fieldCount > 0 ? "会填入识别出的 " + fieldCount + " 项发票信息，黄框是需要你核对的值。"
                : "会打开空白申请，由你补填内容。");
        lines.add("保存和提交仍由你在页面上操作。");
        return proposals.propose(new com.uten.imp.application.port.AiChatActionProposalPort.Draft(
                com.uten.imp.application.port.AiChatActionProposalPort.OPEN_GUIDED_FORM,
                com.uten.imp.application.port.AiChatActionProposalPort.OPEN_GUIDED_FORM, "CLIENT",
                "打开" + formName(workflow) + "并填入识别结果", List.copyOf(lines), "LOW", null, false,
                pageRoute.isBlank() ? null : pageRoute, "AI_JOB", ctx.jobId().toString(), null,
                Map.of("workflow", workflow, "sourceJobId", ctx.jobId().toString()), ctx.jobId()));
    }
    private static String formName(String workflow) {
        return switch (workflow) {
            case "SALES_ORDER" -> "新建销售订货单";
            case "SALES_QUOTE" -> "新建销售报价单";
            case "EXPENSE_CLAIM" -> "新建报销申请";
            default -> "对应的填写页面";
        };
    }
    private static String truncate(String value, int max) { return value.length() <= max ? value : value.substring(0, max); }
    private boolean canExpense() { return workflows.available().stream().anyMatch(value -> value.get("workflow").equals("EXPENSE_CLAIM")); }
    private static boolean credibleInvoiceFields(Map<String, Object> fields) {
        if (!(fields.get("invoiceNo") instanceof String number) || !number.matches("(?:[0-9]{8}|[0-9]{20})")
                || !(fields.get("issueDate") instanceof String date) || !(fields.get("totalAmount") instanceof String amount)) return false;
        try {
            java.time.LocalDate.parse(date);
            return new java.math.BigDecimal(amount).signum() > 0;
        } catch (java.time.DateTimeException | NumberFormatException invalid) { return false; }
    }
    private List<Map<String, String>> choices(String type, String preferred) {
        return workflows.available().stream().filter(value -> switch (type) {
            case "INVOICE" -> value.get("workflow").equals("EXPENSE_CLAIM");
            case "SALES_QUOTATION", "SALES_ORDER", "SALES_TABLE" -> value.get("workflow").startsWith("SALES_");
            case "UNKNOWN" -> true;
            case "COMMERCIAL_INVOICE" -> true;
            default -> false;
        }).sorted(java.util.Comparator.comparingInt(value -> value.get("workflow").equals(preferred) ? 0 : 1)).toList();
    }
    private Map<String, Object> routingContext(String route) {
        var guide = route.isEmpty() ? java.util.Optional.<AiChatPageGuideCatalog.PageGuide>empty() : pages.resolve(route, null);
        List<String> domains = access.contextualDomains().stream().sorted().toList();
        String fingerprint = com.uten.imp.common.util.HashUtil.sha256(String.join("\n", domains) + "\n"
                + java.util.Objects.toString(access.contextualMembershipFingerprint(), ""));
        return Map.of("version", "v2", "domains", domains, "fingerprint", fingerprint, "pageRoute", route,
                "pageKey", guide.map(AiChatPageGuideCatalog.PageGuide::key).orElse(""),
                "pageDomain", guide.map(AiChatPageGuideCatalog.PageGuide::domain).orElse(""));
    }
    private void requireRouting(Object raw) {
        if (!(raw instanceof Map<?, ?> stored) || !"v2".equals(stored.get("version"))
                || !(stored.get("pageRoute") instanceof String route) || route.length() > 240
                || (!route.isEmpty() && !route.matches("/[A-Za-z0-9/_-]*")) || !routingContext(route).equals(stored))
            throw new ApiException(ErrorCode.FORBIDDEN, "文件识别方式已更新，请重新上传。");
    }
    private static String preferredWorkflow(Map<String, Object> context) {
        String key = context.get("pageKey").toString(), domain = context.get("pageDomain").toString();
        String route = context.get("pageRoute").toString();
        if (key.equals("sales_quote")) return "SALES_QUOTE";
        if (key.equals("sales_order")) return "SALES_ORDER";
        if (!key.isEmpty() && domain.equals("SALES") && (route.equals("/sales") || route.startsWith("/sales/"))) return "SALES_ORDER";
        if (!key.isEmpty() && (key.startsWith("expense") || route.equals("/expense") || route.startsWith("/expense/"))) return "EXPENSE_CLAIM";
        if (!key.isEmpty() && !domain.equals("SELF") && !domain.equals("SALES")) return "NONE";
        @SuppressWarnings("unchecked") List<String> domains = (List<String>) context.get("domains");
        return domains.contains("SALES") && Set.of("SALES", "SUBCONTRACT", "SELF").containsAll(domains) ? "SALES_ORDER" : "NONE";
    }
    private static String localOcrFailure(ApiException exception) {
        if (exception.getCode() == ErrorCode.FORBIDDEN || exception.getCode() == ErrorCode.UNAUTHORIZED) throw exception;
        if (exception.getCode() == ErrorCode.BUSINESS) return "暂时没认出图片内容，请换清晰图片或文字版 PDF。";
        throw exception;
    }
    static Classification classify(List<String> lines) {
        var value = AiDocumentClassifier.classify(lines);
        return new Classification(value.type(), value.multipleInvoices());
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
    private static boolean contains(String text, String... words) { return java.util.Arrays.stream(words).anyMatch(text::contains); }
    private static String label(String type) { return switch (type) {
        case "INVOICE" -> "发票"; case "SALES_QUOTATION" -> "报价文件"; case "SALES_ORDER" -> "客户订货文件";
        case "SALES_TABLE" -> "货品明细"; case "HR_DOCUMENT" -> "人事资料"; case "WAREHOUSE_DOCUMENT" -> "仓库资料";
        case "COMMERCIAL_INVOICE" -> "商业发票";
        case "MIXED_DOCUMENT" -> "包含多种业务资料的文件";
        case "PRODUCTION_DOCUMENT" -> "生产资料"; case "PURCHASE_DOCUMENT" -> "采购资料"; case "CONTRACT" -> "合同资料";
        default -> "待确认用途的文件";
    }; }
    record Classification(String type, boolean multipleInvoices) {}
}
