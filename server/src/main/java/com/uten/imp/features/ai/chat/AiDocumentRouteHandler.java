package com.uten.imp.features.ai.chat;

import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.application.port.InvoicePrefillPort;
import com.uten.imp.common.files.document.DocumentImageGuard;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.PdfTextReader;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.chat.AiDocumentIntent.Intent;
import com.uten.imp.features.ai.chat.AiDocumentProfiler.Profile;
import com.uten.imp.features.ai.chat.AiDocumentProfiler.Semantic;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Quarantined local parsing. Produces suggestions for an actual form, never saves any business document.
 * ADR-150: one answer per file. Only a single selected form becomes a one-time OPEN_GUIDED_FORM confirmation
 * card, opened and filled only after the user confirms it; an unknown or ambiguous purpose gets zero cards and
 * the permitted forms as choices (re-submitting the file with {@code workflow}). Recognizing a file needs only
 * chat access; every page and form offered is filtered by the reader's current permissions on every read.
 */
@Component
public class AiDocumentRouteHandler implements AiJobHandler {
    public static final String KIND = "ERP_DOCUMENT_ROUTE";
    private static final Set<String> PARAMS = Set.of("message", "pageRoute", "workflow");
    private static final String ROUTING_VERSION = "v3";
    private static final String STALE = "文件识别方式已更新，请重新上传。";
    private static final int SUMMARY_MAX = 1200;
    /** Types a form can be filled from; the others are answered with pages and plain advice. */
    private static final Set<String> FORM_TYPES = Set.of("INVOICE", "SALES_QUOTATION", "SALES_ORDER", "SALES_TABLE", "COMMERCIAL_INVOICE");
    private static final Set<String> PERSON_TYPES = Set.of("EMPLOYEE_ROSTER", "PAYROLL", "ATTENDANCE");
    private final AiChatAccessPolicy access;
    private final AiChatEvidence evidence;
    private final AiDocumentWorkflows workflows;
    private final InvoicePrefillPort invoices;
    private final AiChatPageGuideCatalog pages;
    private final AiChatActionProposalService proposals;
    private final AiDocumentDestinations destinations;
    public AiDocumentRouteHandler(AiChatAccessPolicy access, AiChatEvidence evidence,
                                  AiDocumentWorkflows workflows, InvoicePrefillPort invoices, AiChatPageGuideCatalog pages,
                                  AiChatActionProposalService proposals, AiDocumentDestinations destinations) {
        this.access = access; this.evidence = evidence; this.workflows = workflows; this.invoices = invoices; this.pages = pages;
        this.proposals = proposals; this.destinations = destinations;
    }
    @Override public String kind() { return KIND; }
    @Override public long maxInputBytes() { return 15L * 1024 * 1024; }
    @Override public Set<String> acceptedKinds() { return Set.of("XLSX", "XLS", "CSV", "DOCX", "PDF", "PNG", "JPEG", "WEBP"); }
    /** Any chat user may have a file recognized; an explicit {@code workflow} must be one the caller may use. */
    @Override public void authorizeSubmit(Map<String, String> params) {
        access.requireChat();
        if (params == null || params.values().stream().anyMatch(java.util.Objects::isNull)
                || !PARAMS.containsAll(params.keySet()) || params.getOrDefault("message", "").length() > 512)
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        String route = params.getOrDefault("pageRoute", "");
        if (route.length() > 240 || (!route.isEmpty() && !route.matches("/[A-Za-z0-9/_-]*")))
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        if (!route.isEmpty()) pages.resolve(route, null);
        if (params.containsKey("workflow")) {
            if (!params.get("workflow").matches("[A-Z_]{1,32}")) throw new ApiException(ErrorCode.VALIDATION_FAILED);
            workflows.require(params.get("workflow"));
        }
    }
    @Override public void authorizeRead(Map<String, String> params) { authorizeSubmit(params); }
    @Override public void validateInput(Map<String, String> params, AiJobInput input) {
        if (!acceptedKinds().contains(input.kind()) || input.size() > maxInputBytes())
            throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
        DocumentKind kind = DocumentKind.valueOf(input.kind());
        if (kind.isImage()) DocumentImageGuard.requireSafe(input.bytes(), kind);
    }
    /** Choices, pages, blocked items and the advice part of the summary are rebuilt for the reader every time. */
    @Override public Map<String, Object> filterResultForReader(Map<String, Object> result) {
        access.requireChat();
        evidence.requireStamp(result.get("_access"));
        requireRouting(result.get("_routing"));
        Offer offer = offer(result.get("_offer"));
        String workflow = String.valueOf(result.getOrDefault("workflow", "NONE"));
        if (!workflow.equals("NONE")) workflows.require(workflow);
        if (result.get("fields") instanceof Map<?, ?> fields && !fields.isEmpty()) workflows.require("EXPENSE_CLAIM");
        Map<String, Object> safe = new LinkedHashMap<>(result);
        safe.remove("_access");
        safe.remove("_routing");
        safe.remove("_offer");
        // Even a source result retained through a later permission change cannot keep old choices or pages.
        present(safe, String.valueOf(result.get("documentType")), intent(result.get("intent")), workflow, offer);
        Set<String> permitted = workflows.available().stream().map(value -> value.get("workflow")).collect(java.util.stream.Collectors.toSet());
        safe.put("actions", proposals.refreshCards(result.get("actions")).stream()
                .filter(card -> card.get("args") instanceof Map<?, ?> args && permitted.contains(args.get("workflow"))).limit(1).toList());
        return safe;
    }
    @Override public Map<String, Object> process(AiJobContext ctx) {
        authorizeSubmit(ctx.params());
        validateInput(ctx.params(), ctx.input());
        Map<String, Object> stamp = evidence.stamp();
        Map<String, Object> routing = routingContext(ctx.params().getOrDefault("pageRoute", ""));
        String message = ctx.params().getOrDefault("message", "");
        String explicit = ctx.params().getOrDefault("workflow", "");
        boolean chosen = !explicit.isEmpty();
        // A chip the user tapped is their own choice and overrides what the message seemed to ask.
        // Instructions inside the document are never read as a purpose.
        String requested = chosen ? explicit : AiDocumentIntent.requestedWorkflow(message);
        boolean analysisOnly = !chosen && AiDocumentIntent.analysisOnly(message);
        Intent intent = chosen ? Intent.FILL : AiDocumentIntent.parse(message);
        String preferred = preferredWorkflow(routing);
        ctx.progress("READING", 10);
        if (ctx.cancelled()) return Map.of();
        DocumentKind kind = DocumentKind.valueOf(ctx.input().kind());
        List<String> lines = new ArrayList<>();
        List<List<String>> sections = new ArrayList<>();
        List<Set<Semantic>> columns = new ArrayList<>();
        Profile profile = Profile.empty();
        boolean explicitExpense = requested.equals("EXPENSE_CLAIM");
        boolean allowExpenseImage = !analysisOnly && !requested.startsWith("SALES_")
                && (explicitExpense || !preferred.startsWith("SALES_"));
        Map<String, Object> invoiceFields = Map.of();
        boolean truncated = false;
        boolean multiplePdfPages = false;
        String limitation = "";
        if (kind.isSpreadsheet()) {
            var grid = SpreadsheetGridReader.read(ctx.input().bytes(), kind);
            profile = AiDocumentProfiler.profile(grid);
            for (int index = 0; index < grid.sheets().size(); index++) {
                var sheet = grid.sheets().get(index);
                List<String> section = new ArrayList<>();
                section.add(sheet.name());
                for (var row : sheet.rows()) section.add(row.joinedText());
                sections.add(section);
                columns.add(index < profile.sheets().size() ? profile.sheets().get(index).semantics() : Set.of());
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
        var parsed = sections.isEmpty() ? AiDocumentClassifier.classify(lines) : AiDocumentClassifier.classifySections(sections, columns);
        boolean goodsTable = sections.isEmpty() ? AiDocumentClassifier.hasGoodsTable(lines)
                : sections.stream().anyMatch(AiDocumentClassifier::hasGoodsTable);
        String type = parsed.type();
        boolean multipleInvoices = parsed.multipleInvoices();
        String evidenceKind = parsed.evidence();
        // A local OCR amount alone does not prove that a trade image is a tax invoice.
        // OCR also cannot erase an already recognized payroll, contract or mixed source.
        if (type.equals("UNKNOWN") && credibleInvoiceFields(invoiceFields)) { type = "INVOICE"; multipleInvoices = false; evidenceKind = "IMAGE"; }
        boolean partialExpense = type.equals("UNKNOWN") && explicitExpense && !invoiceFields.isEmpty();
        if (type.equals("UNKNOWN") && !explicitExpense) invoiceFields = Map.of();
        String typeSource = type.equals("UNKNOWN") ? "NONE" : "RULES";
        // Only a file the rules cannot place, and only structure (never a cell value), may be described to the model.
        if (type.equals("UNKNOWN") && !chosen && !partialExpense && !truncated) {
            var guess = AiDocumentModelAssist.guess(ctx, kind.name(), profile, titleLine(kind, lines), message);
            if (guess.isPresent()) {
                type = guess.get().type();
                typeSource = "AI";
                if (intent == Intent.NONE) intent = guess.get().intent();
            }
            if (ctx.cancelled()) return Map.of();
        }
        boolean guessed = typeSource.equals("AI");
        String workflow;
        if (chosen) workflow = compatible(type, explicit) ? explicit : "NONE";
        else if (partialExpense) workflow = "EXPENSE_CLAIM";
        else if (guessed) workflow = "NONE";  // a model guess never selects a form by itself
        else workflow = switch (type) {
            case "INVOICE" -> "EXPENSE_CLAIM";
            case "SALES_QUOTATION", "SALES_ORDER" -> requested.startsWith("SALES_") ? requested
                    : preferred.startsWith("SALES_") ? preferred : "SALES_ORDER";
            case "SALES_TABLE" -> requested.startsWith("SALES_") ? requested : preferred.startsWith("SALES_") ? preferred : "NONE";
            case "COMMERCIAL_INVOICE" -> !requested.equals("NONE") ? requested
                    : goodsTable && preferred.startsWith("SALES_") ? preferred : "NONE";
            default -> "NONE";
        };
        boolean incompatibleRequest = !requested.equals("NONE") && (guessed ? !compatible(type, requested) : !requested.equals(workflow));
        boolean multiInvoice = multipleInvoices || (multiplePdfPages && type.equals("INVOICE"));
        boolean unsafeSource = multiInvoice || truncated || type.equals("MIXED_DOCUMENT");
        if (type.equals("INVOICE") && !guessed && invoiceFields.isEmpty() && !unsafeSource && !analysisOnly
                && !incompatibleRequest && canExpense())
            invoiceFields = invoices.fromText(lines);
        if (unsafeSource || analysisOnly || incompatibleRequest) invoiceFields = Map.of();
        boolean permitted = !workflow.equals("NONE") && workflows.available().stream().anyMatch(value -> value.get("workflow").equals(workflow));
        boolean unsupportedSalesFormat = kind == DocumentKind.DOCX && workflow.startsWith("SALES_");
        boolean needsChoice = !permitted || incompatibleRequest || unsafeSource || analysisOnly || unsupportedSalesFormat;
        String selected = permitted && !needsChoice ? workflow : "NONE";
        // Do not return invoice fields on a non-expense destination or without the corresponding access.
        if (!canExpense() || !selected.equals("EXPENSE_CLAIM")) invoiceFields = Map.of();
        List<String> candidates = unsupportedSalesFormat || unsafeSource || analysisOnly ? List.of()
                : candidates(type, requested.equals("NONE") ? preferred : requested, kind == DocumentKind.DOCX);
        String label = label(type);
        List<String> facts = new ArrayList<>();
        if (analysisOnly) {
            facts.add("这是" + label + "，已只做分析。");
            addIfPresent(facts, profileLine(profile, type));
        }
        else if (type.equals("MIXED_DOCUMENT")) facts.add("文件里有不同业务的资料，请分开上传。");
        else if (unsupportedSalesFormat) facts.add("这是销售资料，请另存为 Excel 或 PDF 再上传。");
        else if (multiInvoice) facts.add("文件里有多张发票，请分开上传，不能合并成一笔金额。");
        else if (truncated) facts.add("文件内容太多，未能完整读取，请拆分后再上传。");
        else {
            if (incompatibleRequest) facts.add(candidates.isEmpty() && !type.equals("UNKNOWN")
                    ? "文件与要做的单据不一致：" + label + "不能用来填写" + AiDocumentWorkflows.formName(requested) + "。"
                    : "文件与要做的单据不一致，请重新选择用途。");
            else if (!permitted && !workflow.equals("NONE")) facts.add("暂时不能填写这种单据，请联系管理员。");
            else if (partialExpense && selected.equals("EXPENSE_CLAIM")) facts.add("已读到部分信息，请核对后填写报销单。");
            else if (!limitation.isBlank()) facts.add(limitation);
            else if (!selected.equals("NONE")) facts.add((type.equals("UNKNOWN") ? "按你选的用途" : "已识别为" + label)
                    + "。请在下面的确认卡里确认后，我再打开" + AiDocumentWorkflows.formName(selected) + "并填入识别结果。");
            if (selected.equals("NONE") && !partialExpense) describe(facts, type, typeSource, evidenceText(evidenceKind, type, profile), profile, intent);
        }
        Offer offer = new Offer(candidates, facts);
        var result = new LinkedHashMap<String, Object>();
        result.put("documentType", type); result.put("typeSource", typeSource); result.put("intent", intent.name());
        result.put("workflow", selected); result.put("title", label);
        present(result, type, intent, selected, offer);
        result.put("needsChoice", selected.equals("NONE"));
        result.put("profile", profile.toJson());
        result.put("steps", !selected.equals("NONE") ? List.of("读取文件并识别用途", "打开对应业务页面", "核对匹配并填写字段", "由你检查、保存和提交")
                : analysisOnly || unsafeSource ? List.of("读取文件并识别用途", "确认用途并按需拆分文件")
                : List.of("读取文件并识别用途", "说明能做什么、去哪里处理"));
        result.put("fields", invoiceFields);
        var confidence = new LinkedHashMap<String, String>();
        invoiceFields.forEach((key, value) -> { if (value != null && !value.toString().isBlank()) confidence.put(key, "HIGH"); });
        result.put("fieldConfidence", confidence); result.put("requiresReview", true);
        result.put("missingFields", workflow.equals("EXPENSE_CLAIM")
                ? List.of("invoiceNo", "issueDate", "totalAmount").stream().filter(key -> !confidence.containsKey(key)).toList() : List.of());
        result.put("source", Map.of("fileName", ctx.input().fileName(), "sha256", ctx.input().sha256()));
        evidence.requireStamp(stamp);
        String pageRoute = ctx.params().getOrDefault("pageRoute", "");
        // One answer, at most one card: only a single selected form is ever proposed.
        result.put("actions", selected.equals("NONE") ? List.of()
                : List.of(guidedCard(ctx, selected, type, pageRoute, invoiceFields.size())));
        result.put("_access", stamp);
        result.put("_routing", routing);
        result.put("_offer", Map.of("version", "v1", "choices", candidates, "facts", List.copyOf(facts)));
        evidence.requireStamp(stamp);
        requireRouting(routing);
        if (ctx.cancelled()) return Map.of();
        ctx.progress("READY_TO_FILL", 100);
        return result;
    }

    /** Internal part of a stored result: forms the file fits before permission filtering, and the fact lines. */
    private record Offer(List<String> choices, List<String> facts) {}

    /** Visible choices, pages, blocked items and summary for the current reader. */
    private void present(Map<String, Object> target, String type, Intent intent, String selected, Offer offer) {
        List<Map<String, String>> available = workflows.available();
        List<Map<String, String>> choices = new ArrayList<>();
        for (String code : offer.choices())
            available.stream().filter(value -> value.get("workflow").equals(code)).findFirst()
                    .ifPresent(value -> choices.add(Map.of("workflow", code, "title", value.get("title"))));
        var advice = destinations.advise(type, intent, offer.choices());
        List<String> lines = new ArrayList<>(offer.facts());
        if (selected.equals("NONE") && !choices.isEmpty() && lines.stream().noneMatch(line -> line.contains("重新选择用途")))
            lines.add("需要填写单据的话，请在下面选要做的单据。");
        lines.addAll(advice.lines());
        target.put("summary", bounded(lines));
        target.put("choices", List.copyOf(choices));
        target.put("pages", advice.pages());
        target.put("blocked", advice.blocked());
    }

    /** What the file is, how that was seen, its columns and what the user appears to want (no cell values). */
    private static void describe(List<String> facts, String type, String typeSource, String evidence, Profile profile, Intent intent) {
        String label = label(type);
        if (type.equals("UNKNOWN")) {
            if (facts.isEmpty()) facts.add("暂时没看出文件用途。");
        } else if (typeSource.equals("AI")) {
            facts.add("按文件的结构(列名、行数)推测，这可能是" + label + "，不一定准确，请你确认。");
            addIfPresent(facts, profileLine(profile, type));
        } else if (FORM_TYPES.contains(type)) {
            if (facts.isEmpty()) facts.add("已识别为" + label + "。");
            return;
        } else {
            facts.add("这是一份" + label + "，是从" + evidence + "看出来的。");
            addIfPresent(facts, profileLine(profile, type));
        }
        addIfPresent(facts, switch (intent) {
            case RECONCILE -> type.equals("EMPLOYEE_ROSTER") ? "你想把它和系统里的员工资料对照，更正不一致的、补充缺少的员工。"
                    : "你想把它和系统里的" + subject(type) + "对照，更正不一致的、补上缺少的。";
            case IMPORT -> "你想把里面的" + subject(type) + "批量录入系统。";
            case ANALYZE -> "你想对文件内容做统计或分析；助手目前只看出文件是什么、有哪些列，不会逐行统计里面的数据。";
            case QUESTION -> type.equals("UNKNOWN") ? null : "你想知道这份文件是什么、能怎么处理。";
            default -> null;
        });
    }

    /** 工作表「花名册」约 86 人，列有：姓名、部门… (labels are masked header words, never values). */
    private static String profileLine(Profile profile, String type) {
        List<String> parts = new ArrayList<>();
        for (var sheet : profile.sheets()) {
            if (sheet.columns().isEmpty() || parts.size() >= 2) continue;
            List<String> labels = sheet.columns().stream().map(AiDocumentProfiler.Column::label).filter(label -> !label.isBlank()).toList();
            String shown = String.join("、", labels.subList(0, Math.min(8, labels.size())))
                    + (labels.size() > 8 ? " 等 " + labels.size() + " 列" : "");
            parts.add("工作表「" + sheet.name() + "」约 " + sheet.dataRows() + (PERSON_TYPES.contains(type) ? " 人" : " 行")
                    + "，列有：" + shown);
        }
        return parts.isEmpty() ? null : String.join("；", parts) + "。";
    }

    private static String evidenceText(String kind, String type, Profile profile) {
        boolean columnsAgree = profile.sheets().stream().anyMatch(sheet -> type.equals(AiDocumentClassifier.columnType(sheet.semantics())));
        return switch (kind) {
            case "TITLE" -> columnsAgree ? "标题和列名" : "标题";
            case "COLUMNS" -> "列名";
            case "FIELDS" -> "票面上的发票号码和金额";
            case "IMAGE" -> "图片里识别出的票面信息";
            default -> "文件内容";
        };
    }

    private static String subject(String type) {
        return switch (type) {
            case "EMPLOYEE_ROSTER", "HR_DOCUMENT" -> "员工资料";
            case "PAYROLL" -> "工资";
            case "ATTENDANCE" -> "考勤";
            case "GOODS_LIST" -> "货品资料";
            case "BOM_LIST" -> "产品组装明细";
            case "CUSTOMER_LIST" -> "客户资料";
            case "SUPPLIER_LIST" -> "供应商资料";
            case "STOCK_LIST" -> "库存数量";
            case "BANK_STATEMENT" -> "收付款记录";
            default -> "资料";
        };
    }

    private static String bounded(List<String> lines) {
        StringBuilder text = new StringBuilder();
        for (String line : lines) {
            if (line == null || line.isBlank()) continue;
            int extra = (text.isEmpty() ? 0 : 1) + line.length();
            if (text.length() + extra > SUMMARY_MAX) {
                if (text.isEmpty()) text.append(line, 0, SUMMARY_MAX);
                break;
            }
            if (!text.isEmpty()) text.append('\n');
            text.append(line);
        }
        return text.toString();
    }

    private static void addIfPresent(List<String> lines, String line) { if (line != null) lines.add(line); }

    /** Only the first text line of a PDF or Word file may be described to the model (and only if it is safe). */
    private static String titleLine(DocumentKind kind, List<String> lines) {
        if (kind != DocumentKind.PDF && kind != DocumentKind.DOCX) return null;
        return lines.stream().filter(line -> line != null && !line.isBlank()).findFirst().orElse(null);
    }

    /** Forms a file of this type may fill; an unknown file may fill any form the user explicitly picks. */
    private static boolean compatible(String type, String workflow) {
        return switch (type) {
            case "INVOICE" -> workflow.equals("EXPENSE_CLAIM");
            case "SALES_QUOTATION", "SALES_ORDER", "SALES_TABLE" -> workflow.startsWith("SALES_");
            case "UNKNOWN", "COMMERCIAL_INVOICE" -> AiDocumentWorkflows.ALL.contains(workflow);
            default -> false;
        };
    }

    private static List<String> candidates(String type, String preferred, boolean docx) {
        return AiDocumentWorkflows.ALL.stream().filter(workflow -> compatible(type, workflow))
                .filter(workflow -> !docx || !workflow.startsWith("SALES_"))
                .sorted(java.util.Comparator.comparingInt(workflow -> workflow.equals(preferred) ? 0 : 1)).toList();
    }

    private static Offer offer(Object raw) {
        if (!(raw instanceof Map<?, ?> stored) || !"v1".equals(stored.get("version"))
                || !(stored.get("choices") instanceof List<?> choices) || !(stored.get("facts") instanceof List<?> facts)
                || choices.stream().anyMatch(value -> !AiDocumentWorkflows.ALL.contains(value))
                || facts.size() > 16 || facts.stream().anyMatch(value -> !(value instanceof String)))
            throw new ApiException(ErrorCode.FORBIDDEN, STALE);
        return new Offer(choices.stream().map(String::valueOf).toList(), facts.stream().map(String::valueOf).toList());
    }

    private static Intent intent(Object raw) {
        try { return raw instanceof String value ? Intent.valueOf(value) : Intent.NONE; }
        catch (IllegalArgumentException unknown) { return Intent.NONE; }
    }

    /** One-time card: opening the form and filling it happens only after the user confirms. */
    private Map<String, Object> guidedCard(AiJobContext ctx, String workflow, String type, String pageRoute, int fieldCount) {
        List<String> lines = new ArrayList<>();
        lines.add("文件: " + truncate(ctx.input().fileName(), 120));
        lines.add("识别为: " + label(type));
        lines.add("将打开: " + AiDocumentWorkflows.formName(workflow));
        lines.add(workflow.startsWith("SALES_")
                ? "打开后由页面逐行识别并填入货品，黄框是需要你核对的值。"
                : fieldCount > 0 ? "会填入识别出的 " + fieldCount + " 项发票信息，黄框是需要你核对的值。"
                : "会打开空白申请，由你补填内容。");
        lines.add("保存和提交仍由你在页面上操作。");
        return proposals.propose(new com.uten.imp.application.port.AiChatActionProposalPort.Draft(
                com.uten.imp.application.port.AiChatActionProposalPort.OPEN_GUIDED_FORM,
                com.uten.imp.application.port.AiChatActionProposalPort.OPEN_GUIDED_FORM, "CLIENT",
                "打开" + AiDocumentWorkflows.formName(workflow) + "并填入识别结果", List.copyOf(lines), "LOW", null, false,
                pageRoute.isBlank() ? null : pageRoute, "AI_JOB", ctx.jobId().toString(), null,
                Map.of("workflow", workflow, "sourceJobId", ctx.jobId().toString()), ctx.jobId()));
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
    private Map<String, Object> routingContext(String route) {
        var guide = route.isEmpty() ? java.util.Optional.<AiChatPageGuideCatalog.PageGuide>empty() : pages.resolve(route, null);
        List<String> domains = access.contextualDomains().stream().sorted().toList();
        String fingerprint = com.uten.imp.common.util.HashUtil.sha256(String.join("\n", domains) + "\n"
                + java.util.Objects.toString(access.contextualMembershipFingerprint(), ""));
        return Map.of("version", ROUTING_VERSION, "domains", domains, "fingerprint", fingerprint, "pageRoute", route,
                "pageKey", guide.map(AiChatPageGuideCatalog.PageGuide::key).orElse(""),
                "pageDomain", guide.map(AiChatPageGuideCatalog.PageGuide::domain).orElse(""));
    }
    private void requireRouting(Object raw) {
        if (!(raw instanceof Map<?, ?> stored) || !ROUTING_VERSION.equals(stored.get("version"))
                || !(stored.get("pageRoute") instanceof String route) || route.length() > 240
                || (!route.isEmpty() && !route.matches("/[A-Za-z0-9/_-]*")) || !routingContext(route).equals(stored))
            throw new ApiException(ErrorCode.FORBIDDEN, STALE);
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
    static String label(String type) { return switch (type) {
        case "INVOICE" -> "发票"; case "SALES_QUOTATION" -> "报价文件"; case "SALES_ORDER" -> "客户订货文件";
        case "SALES_TABLE" -> "货品明细"; case "HR_DOCUMENT" -> "人事资料"; case "WAREHOUSE_DOCUMENT" -> "仓库单据";
        case "COMMERCIAL_INVOICE" -> "商业发票";
        case "MIXED_DOCUMENT" -> "包含多种业务资料的文件";
        case "PRODUCTION_DOCUMENT" -> "生产资料"; case "PURCHASE_DOCUMENT" -> "采购资料"; case "CONTRACT" -> "合同资料";
        case "EMPLOYEE_ROSTER" -> "员工花名册"; case "PAYROLL" -> "工资表"; case "ATTENDANCE" -> "考勤表";
        case "GOODS_LIST" -> "货品清单"; case "BOM_LIST" -> "产品配件清单(BOM)"; case "CUSTOMER_LIST" -> "客户名单";
        case "SUPPLIER_LIST" -> "供应商名单"; case "STOCK_LIST" -> "库存或盘点表"; case "BANK_STATEMENT" -> "银行流水或对账单";
        default -> "待确认用途的文件";
    }; }
}
