package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler.AiJobContext;
import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidate;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientProfile;
import com.uten.imp.application.port.MasterIntakeLookupPort.DuplicateDocLine;
import com.uten.imp.application.port.MasterIntakeLookupPort.DuplicateDocRow;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.common.files.document.DocumentGrid;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.files.document.DocumentImageGuard;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.PdfTextReader;
import com.uten.imp.common.files.document.PdfTextReader.DocumentText;
import com.uten.imp.common.files.document.PromptTable;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.intake.GoodsMatcher.ClientContext;
import com.uten.imp.features.sales.intake.GoodsMatcher.Decision;
import com.uten.imp.features.sales.intake.GoodsMatcher.Evidence;
import com.uten.imp.features.sales.intake.GoodsMatcher.LineInput;
import com.uten.imp.features.sales.intake.GoodsMatcher.Reason;
import com.uten.imp.features.sales.intake.GoodsMatcher.Scored;
import com.uten.imp.features.sales.intake.GoodsMatcher.Scoring;
import com.uten.imp.features.sales.intake.GoodsMatcher.Status;
import com.uten.imp.features.sales.intake.IntakeLayoutDetector.FingerprintProbe;
import com.uten.imp.features.sales.intake.IntakePricing.CandidatePricing;
import com.uten.imp.features.sales.intake.IntakePricing.CurrencyInfo;
import com.uten.imp.features.sales.intake.IntakeReferenceData.CurrencyRow;
import com.uten.imp.features.sales.intake.IntakeReferenceData.LearnedLayout;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/**
 * 客户文件识别流水线(SPEC §5.1-§5.9)。在 AI 任务工作线程上运行, 没有数据库事务; 读主档只经
 * {@link MasterIntakeLookupPort}(提交人的数据范围), 调 AI 只经任务上下文。
 *
 * <p>阶段: 读取(10) → 版式(25) → 抽取(40) → 匹配货品(60) → 匹配客户(75) → 定价(90) → 完成。
 * 货品先不看客户匹配一轮(给「篮子重合度」找客户用), 定了客户再按客户历史与对照重新打分。
 * 结果结构见 SPEC §5.9, 价格只做「文件单价 ÷ 标价」的折扣反推, 从不改价。
 */
final class SalesIntakePipeline {

    static final int MAX_LINES = 500;
    static final int PDF_CHUNK_CHARS = 12_000;
    static final int MAX_VISION_PAGES = 4;
    static final int AI_MATCH_BATCH = 20;
    static final int AI_HISTORY_ROWS = 250;
    static final int DUPLICATE_DAYS = 180;
    static final int HEADER_PROMPT_CHARS = 4000;
    static final int COLUMN_PROMPT_ROWS = 15;
    static final double AI_AGREE_MARGIN = 4;
    static final int SCHEMA_VERSION = 2;
    /** 全局(不分客户)学习版式至少被保存确认几次才直接使用。 */
    static final int GLOBAL_LAYOUT_MIN_CONFIRMS = 2;
    /** AI 抽出的数量/单价/金额上限(超出按看不清的行丢弃)。 */
    static final BigDecimal MAX_AI_NUMBER = new BigDecimal("1000000000");
    static final int MAX_AI_SCALE = 6;

    private final MasterIntakeLookupPort lookup;
    private final IntakeReferenceData data;
    private final ObjectMapper json;
    private final BooleanSupplier visionSupported;
    private final Clock clock;

    SalesIntakePipeline(MasterIntakeLookupPort lookup, IntakeReferenceData data, ObjectMapper json,
                        BooleanSupplier visionSupported, Clock clock) {
        this.lookup = lookup;
        this.data = data;
        this.json = json;
        this.visionSupported = visionSupported;
        this.clock = clock;
    }

    /** 处理一个任务; 用户取消时返回空 Map(任务状态由框架置为已取消)。 */
    Map<String, Object> run(AiJobContext ctx) {
        IntakeParams params = IntakeParams.parse(ctx.params());
        Run run = new Run(ctx, params, new IntakeAi(ctx, json));
        ctx.progress("READING", 10);
        AiJobInput input = ctx.input();
        DocumentKind kind = parseKind(input.kind());
        if (kind.isSpreadsheet()) {
            readSpreadsheet(run, input, kind);
        } else if (kind == DocumentKind.PDF) {
            readPdf(run, input);
        } else if (kind.isImage()) {
            DocumentImageGuard.requireSafe(input.bytes(), kind);
            ctx.progress("EXTRACTING", 40);
            readImages(run, List.of(input.bytes()), kind.imageMediaType());
        } else {
            throw fail(IntakeTexts.FAIL_UNSUPPORTED, "UNSUPPORTED_FILE");
        }
        if (run.lines.isEmpty()) {
            throw fail(IntakeTexts.FAIL_NO_LINES, "NO_LINES");
        }
        if (ctx.cancelled()) {
            return Map.of();
        }
        run.currency = resolveCurrency(run.fileCurrency);
        ctx.progress("MATCHING_GOODS", 60);
        matchGoodsWithoutClient(run);
        if (ctx.cancelled()) {
            return Map.of();
        }
        ctx.progress("MATCHING_CLIENT", 75);
        matchClient(run);
        matchGoodsForClient(run);
        disambiguateWithAi(run);
        markDuplicateGoods(run);
        if (ctx.cancelled()) {
            return Map.of();
        }
        ctx.progress("PRICING", 90);
        price(run);
        run.duplicates = duplicates(run);
        if (!run.ai.allowed() && kind.isSpreadsheet()) {
            run.notices.addFirst(IntakeTexts.NOTICE_AI_OFF);
        } else if (run.ai.lastFailure() != null && kind.isSpreadsheet()) {
            run.notices.add(IntakeTexts.NOTICE_AI_FAILED);
        }
        Map<String, Object> result = assemble(run, input, kind);
        ctx.progress("DONE", 100);
        return result;
    }

    /** 一次运行的中间状态。 */
    static final class Run {
        final AiJobContext ctx;
        final IntakeParams params;
        final IntakeAi ai;
        final List<String> notices = new ArrayList<>();
        final List<LineResult> lines = new ArrayList<>();
        IntakeHeader header = new IntakeHeader();
        String fileCurrency;
        String sheetName;
        List<Map<String, Object>> otherSheets = List.of();
        IntakeLayout layout;
        String layoutSource;
        CurrencyInfo currency;
        GoodsCandidateRetriever.Retrieval retrieval;
        final Map<String, Scoring> freeScoring = new LinkedHashMap<>();
        ClientMatcher.Result clientResult;
        ClientProfile clientProfile;
        final Map<UUID, ClientProfile> profiles = new HashMap<>();
        ClientContext clientContext = ClientContext.NONE;
        GoodsCandidateRetriever.HistoryPool history = GoodsCandidateRetriever.HistoryPool.EMPTY;
        List<Map<String, Object>> duplicates = List.of();
        int droppedAiLines;

        Run(AiJobContext ctx, IntakeParams params, IntakeAi ai) {
            this.ctx = ctx;
            this.params = params;
            this.ai = ai;
        }
    }

    /** 一行的抽取 + 匹配 + 定价结果。 */
    static final class LineResult {
        final ExtractedLine line;
        final LineInput input;
        Scoring scoring;
        Decision decision;
        Status status = Status.UNMATCHED;
        String reasonText;
        UUID selectedGoodsId;
        Map<String, Object> aiSuggestion;
        List<Scored> shown = List.of();
        final List<IntakeWarning> warnings = new ArrayList<>();
        final Map<UUID, CandidatePricing> pricing = new HashMap<>();
        List<Map<String, Object>> bundleParts = List.of();

        LineResult(ExtractedLine line) {
            this.line = line;
            this.input = LineInput.of(line);
            this.warnings.addAll(line.warnings());
        }

        Scored selected() {
            if (selectedGoodsId == null) {
                return null;
            }
            for (Scored s : shown) {
                if (s.goods.id().equals(selectedGoodsId)) {
                    return s;
                }
            }
            return null;
        }
    }

    // ------------------------------------------------------------------ reading

    private void readSpreadsheet(Run run, AiJobInput input, DocumentKind kind) {
        DocumentGrid grid = SpreadsheetGridReader.read(input.bytes(), kind);
        if (grid.sheets().isEmpty()) {
            throw fail(IntakeTexts.FAIL_NO_TABLE, "NO_TABLE");
        }
        run.ctx.progress("LAYOUT", 25);
        List<SheetChoice> choices = new ArrayList<>();
        Map<String, List<LearnedLayout>> learned = learnedLayouts(grid, run.params.clientId());
        for (Sheet sheet : grid.sheets()) {
            SheetChoice choice = null;
            IntakeLayout layout = learnedLayout(sheet, learned);
            if (layout != null) {
                choice = choice(sheet, layout);
            }
            if (choice == null) {
                // 没有学习到的版式, 或按它一行也取不出来: 按规则认。
                layout = IntakeLayoutDetector.detect(sheet);
                choice = layout == null ? null : choice(sheet, layout);
            }
            if (choice != null) {
                choices.add(choice);
            }
        }
        if (choices.isEmpty() && run.ai.usable()) {
            SheetChoice viaAi = layoutWithAi(run, grid);
            if (viaAi != null) {
                choices.add(viaAi);
            }
        }
        if (choices.isEmpty()) {
            throw fail(run.ai.allowed() ? IntakeTexts.FAIL_NO_TABLE : IntakeTexts.FAIL_NO_TABLE_AI_OFF, "NO_TABLE");
        }
        SheetChoice chosen;
        if (run.params.sheetIndex() != null) {
            chosen = choices.stream().filter(c -> c.sheet().index() == run.params.sheetIndex()).findFirst()
                    .orElseThrow(() -> fail("指定的工作表里没找到货品明细表", "NO_TABLE"));
        } else {
            chosen = choices.stream().sorted(Comparator
                    .comparingInt((SheetChoice c) -> c.hasPrice() ? 0 : 1)
                    .thenComparingInt(c -> -c.extraction().lines().size())
                    .thenComparingInt(c -> -c.layout().score())
                    .thenComparingInt(c -> c.sheet().index())).findFirst().orElseThrow();
        }
        List<Map<String, Object>> others = new ArrayList<>();
        for (SheetChoice c : choices) {
            if (c != chosen && c.hasPrice()) {
                Map<String, Object> o = new LinkedHashMap<>();
                o.put("name", c.sheet().name());
                o.put("index", c.sheet().index());
                o.put("lineCount", c.extraction().lines().size());
                others.add(o);
            }
        }
        run.otherSheets = others;
        run.sheetName = chosen.sheet().name();
        run.layout = chosen.layout();
        run.layoutSource = chosen.layout().source();
        run.ctx.progress("EXTRACTING", 40);
        List<ExtractedLine> lines = chosen.extraction().lines();
        if (lines.size() > MAX_LINES) {
            run.notices.add("文件有 " + lines.size() + " 行货品, 一次最多识别 " + MAX_LINES + " 行, 后面的请分开识别");
            lines = lines.subList(0, MAX_LINES);
        }
        for (ExtractedLine l : lines) {
            run.lines.add(new LineResult(l));
        }
        run.fileCurrency = chosen.layout().fileCurrency() != null ? chosen.layout().fileCurrency()
                : chosen.extraction().currencyFromCells();
        run.header = IntakeHeaderRules.extract(chosen.sheet(), chosen.layout().headerRow0());
        if (run.header.buyerName == null && run.ai.usable()) {
            IntakeHeaderRules.MinimizedHeader minimized = IntakeHeaderRules.minimize(chosen.sheet(),
                    chosen.layout().headerRow0(), HEADER_PROMPT_CHARS);
            if (!minimized.text().isBlank()) {
                run.ai.call(IntakePrompts.header(minimized.text(), run.ctx.jobId()))
                        .ifPresent(node -> mergeAiHeader(run.header, node, minimized.text(), minimized.placeholders(),
                                "RULES+AI"));
            }
        }
    }

    private static SheetChoice choice(Sheet sheet, IntakeLayout layout) {
        IntakeLineExtractor.Extraction extraction = IntakeLineExtractor.extract(sheet, layout);
        return extraction.lines().isEmpty() ? null : new SheetChoice(sheet, layout, extraction);
    }

    /** 有版式且抽到货品行的工作表。 */
    record SheetChoice(Sheet sheet, IntakeLayout layout, IntakeLineExtractor.Extraction extraction) {
        boolean hasPrice() {
            return layout.has(ColumnRole.UNIT_PRICE) || layout.has(ColumnRole.AMOUNT);
        }
    }

    private Map<String, List<LearnedLayout>> learnedLayouts(DocumentGrid grid, UUID clientId) {
        Set<String> fingerprints = new LinkedHashSet<>();
        for (Sheet sheet : grid.sheets()) {
            for (FingerprintProbe p : IntakeLayoutDetector.fingerprintProbes(sheet)) {
                fingerprints.add(p.fingerprint());
            }
        }
        Map<String, List<LearnedLayout>> out = new HashMap<>();
        if (fingerprints.isEmpty()) {
            return out;
        }
        for (LearnedLayout l : data.layouts(fingerprints, clientId)) {
            out.computeIfAbsent(l.fingerprint(), k -> new ArrayList<>()).add(l);
        }
        return out;
    }

    private static IntakeLayout learnedLayout(Sheet sheet, Map<String, List<LearnedLayout>> learned) {
        if (learned.isEmpty()) {
            return null;
        }
        for (FingerprintProbe probe : IntakeLayoutDetector.fingerprintProbes(sheet)) {
            List<LearnedLayout> hits = learned.get(probe.fingerprint());
            if (hits == null) {
                continue;
            }
            for (LearnedLayout hit : hits) {
                if (hit.headerRowOffset() + 1 != probe.span() || !trusted(hit)) {
                    continue;
                }
                Map<Integer, ColumnRole> roles = IntakeLayoutDetector.rolesFromLetters(hit.columnRoles());
                if (IntakeLayoutDetector.usable(roles)) {
                    return IntakeLayoutDetector.withRoles(sheet, probe.headerRow0(), probe.span(), roles,
                            IntakeLayout.SOURCE_LEARNED);
                }
            }
        }
        return null;
    }

    /**
     * 学习到的版式能不能直接用: 本客户的版式保存过一次就用; 全局版式要被确认过至少
     * {@link #GLOBAL_LAYOUT_MIN_CONFIRMS} 次 —— 一次保存(可能是认错列后手工改了表格)不会影响所有人。
     */
    static boolean trusted(LearnedLayout layout) {
        return layout.clientId() != null || layout.confirmCount() >= GLOBAL_LAYOUT_MIN_CONFIRMS;
    }

    /** 规则找不到表头时, 把最像表格的 15 行发给 AI 认列(去掉银行行)。 */
    private SheetChoice layoutWithAi(Run run, DocumentGrid grid) {
        Sheet target = null;
        int bestRows = -1;
        for (Sheet s : grid.sheets()) {
            if (run.params.sheetIndex() != null && s.index() != run.params.sheetIndex()) {
                continue;
            }
            if (s.rows().size() > bestRows) {
                bestRows = s.rows().size();
                target = s;
            }
        }
        if (target == null || target.rows().isEmpty()) {
            return null;
        }
        int anchor = target.rows().getFirst().index0();
        int bestCells = -1;
        for (Row row : target.rows()) {
            if (row.index0() > target.rows().getFirst().index0() + 60) {
                break;
            }
            long textCells = row.cells().stream().filter(c -> c.kind() == DocumentGrid.CellKind.TEXT).count();
            if (textCells > bestCells) {
                bestCells = (int) textCells;
                anchor = row.index0();
            }
        }
        int from = Math.max(target.rows().getFirst().index0(), anchor - 3);
        int to = from + COLUMN_PROMPT_ROWS - 1;
        Sheet sanitized = IntakeHeaderRules.sanitizeForColumnPrompt(target, from, to);
        String table = PromptTable.render(sanitized, from, to, 6000, Set.of());
        if (table.isBlank()) {
            return null;
        }
        Optional<JsonNode> node = run.ai.call(IntakePrompts.columns(table, run.ctx.jobId()));
        if (node.isEmpty() || !node.get().path("headerRow").canConvertToInt()) {
            return null;
        }
        int headerRow0 = node.get().path("headerRow").asInt() - 1;
        if (headerRow0 < from || headerRow0 > to) {
            return null;
        }
        Map<String, Object> byLetter = new LinkedHashMap<>();
        for (JsonNode c : node.get().path("columns")) {
            String letter = IntakeAi.text(c, "column");
            String role = IntakeAi.text(c, "role");
            if (letter != null && role != null) {
                byLetter.put(letter.toUpperCase(Locale.ROOT), role);
            }
        }
        Map<Integer, ColumnRole> roles = IntakeLayoutDetector.rolesFromLetters(byLetter);
        final int maxColumn = Math.max(target.maxColumn(), 0);
        roles.keySet().removeIf(col -> col > maxColumn);
        if (!IntakeLayoutDetector.usable(roles)) {
            return null;
        }
        IntakeLayout layout = IntakeLayoutDetector.withRoles(target, headerRow0, 1, roles, IntakeLayout.SOURCE_AI);
        IntakeLineExtractor.Extraction extraction = IntakeLineExtractor.extract(target, layout);
        return extraction.lines().isEmpty() ? null : new SheetChoice(target, layout, extraction);
    }

    private void readPdf(Run run, AiJobInput input) {
        DocumentText text = PdfTextReader.read(input.bytes());
        run.ctx.progress("LAYOUT", 25);
        if (text.scanned()) {
            if (!run.ai.allowed()) {
                throw fail(IntakeTexts.FAIL_AI_REQUIRED, "AI_REQUIRED");
            }
            if (!visionSupported.getAsBoolean()) {
                throw fail(IntakeTexts.FAIL_VISION, "AI_VISION_UNAVAILABLE");
            }
            run.ctx.progress("EXTRACTING", 40);
            readImages(run, PdfTextReader.renderPages(input.bytes(), MAX_VISION_PAGES), "image/jpeg");
            if (text.pageCount() > MAX_VISION_PAGES) {
                run.notices.add("扫描件只识别了前 " + MAX_VISION_PAGES + " 页");
            }
            return;
        }
        if (!run.ai.allowed()) {
            throw fail(IntakeTexts.FAIL_AI_REQUIRED, "AI_REQUIRED");
        }
        run.ctx.progress("EXTRACTING", 40);
        if (text.truncated()) {
            run.notices.add("PDF 只识别了前 " + PdfTextReader.MAX_PAGES + " 页");
        }
        List<String> allLines = new ArrayList<>();
        text.pages().forEach(p -> allLines.addAll(p.lines()));
        IntakeHeaderRules.contactsFromText(allLines, run.header);
        Map<String, String> placeholders = new LinkedHashMap<>();
        List<List<String>> chunks = new ArrayList<>();
        List<Set<Integer>> chunkPageStarts = new ArrayList<>();
        List<String> current = new ArrayList<>();
        Set<Integer> currentStarts = new HashSet<>();
        int size = 0;
        for (DocumentText.Page page : text.pages()) {
            boolean firstOfPage = true;
            for (String line : page.lines()) {
                if (size + line.length() + 1 > PDF_CHUNK_CHARS && !current.isEmpty()) {
                    chunks.add(current);
                    chunkPageStarts.add(currentStarts);
                    current = new ArrayList<>();
                    currentStarts = new HashSet<>();
                    size = 0;
                }
                if (firstOfPage) {
                    currentStarts.add(current.size());
                    firstOfPage = false;
                }
                current.add(line);
                size += line.length() + 1;
            }
        }
        if (!current.isEmpty()) {
            chunks.add(current);
            chunkPageStarts.add(currentStarts);
        }
        StringBuilder sentText = new StringBuilder();
        int sequence = 0;
        for (int i = 0; i < chunks.size(); i++) {
            if (!run.ai.usable()) {
                run.notices.add("文件太长, 只识别了前面的部分");
                break;
            }
            String minimized = IntakeHeaderRules.minimizeText(chunks.get(i), chunkPageStarts.get(i), placeholders);
            sentText.append(minimized).append('\n');
            Optional<JsonNode> node = run.ai.call(IntakePrompts.documentText(minimized, chunks.get(i).size(),
                    run.ctx.jobId()));
            if (node.isEmpty()) {
                if (i == 0) {
                    throw aiFailed(run);
                }
                run.notices.add("文件后面的部分没识别出来, 请核对行数");
                break;
            }
            sequence = absorbDocument(run, node.get(), "P", sequence, sentText.toString(), placeholders, true);
        }
        run.layoutSource = IntakeLayout.SOURCE_AI;
        run.header.source = run.header.emails.isEmpty() && run.header.phones.isEmpty() ? "AI" : "RULES+AI";
    }

    private void readImages(Run run, List<byte[]> images, String mediaType) {
        if (!run.ai.allowed()) {
            throw fail(IntakeTexts.FAIL_AI_REQUIRED, "AI_REQUIRED");
        }
        if (!visionSupported.getAsBoolean()) {
            throw fail(IntakeTexts.FAIL_VISION, "AI_VISION_UNAVAILABLE");
        }
        Optional<JsonNode> node = run.ai.call(IntakePrompts.documentImages(images, mediaType, run.ctx.jobId()));
        if (node.isEmpty()) {
            throw aiFailed(run);
        }
        absorbDocument(run, node.get(), "I", 0, null, Map.of(), false);
        run.layoutSource = IntakeLayout.SOURCE_AI;
        run.header.source = "AI";
    }

    /**
     * 把 AI 抽出的表头与行并入结果; 行按规则后处理。丢弃(计入「有 N 行看不清」): 数量不是正数、既无型号又无品名、
     * 数量/单价/金额超出合理范围或为负、以及(PDF 文字模式)型号和品名都在发给 AI 的原文里找不到的行。
     */
    private int absorbDocument(Run run, JsonNode node, String keyPrefix, int sequence, String sourceText,
                               Map<String, String> placeholders, boolean verifyAgainstText) {
        JsonNode header = node.path("header");
        if (header.isObject()) {
            mergeAiHeader(run.header, header, verifyAgainstText ? sourceText : null, placeholders, "AI");
        }
        if (run.fileCurrency == null) {
            String currency = IntakeAi.text(node, "currency");
            if (currency != null) {
                run.fileCurrency = IntakeLayoutDetector.currencyOf(currency);
            }
        }
        boolean hasColor = false;
        for (JsonNode l : node.path("lines")) {
            hasColor |= IntakeAi.text(l, "color") != null;
        }
        String sentLoose = verifyAgainstText && sourceText != null ? loose(sourceText) : null;
        for (JsonNode l : node.path("lines")) {
            BigDecimal qty = IntakeAi.number(l, "qty");
            BigDecimal unitPrice = IntakeAi.number(l, "unitPrice");
            BigDecimal amount = IntakeAi.number(l, "amount");
            String maskedPart = IntakeAi.text(l, "partNo");
            String maskedDescription = IntakeAi.text(l, "description");
            if (!IntakeNumbers.positive(qty) || (maskedPart == null && maskedDescription == null)
                    || !plausibleNumber(qty) || (unitPrice != null && (unitPrice.signum() < 0 || !plausibleNumber(unitPrice)))
                    || (amount != null && (amount.signum() < 0 || !plausibleNumber(amount)))
                    || (sentLoose != null && !appearsIn(maskedPart, maskedDescription, sentLoose))) {
                run.droppedAiLines++;
                continue;
            }
            if (run.lines.size() >= MAX_LINES) {
                break;
            }
            sequence++;
            String key = keyPrefix + "1R" + sequence;
            IntakeLineExtractor.RawLine raw = new IntakeLineExtractor.RawLine(key, null, sequence,
                    IntakeAi.text(l, "lineNo"), IntakeHeaderRules.unmask(maskedPart, placeholders),
                    IntakeHeaderRules.unmask(maskedDescription, placeholders), null, IntakeAi.text(l, "series"),
                    IntakeAi.text(l, "color"), null, qty, IntakeAi.text(l, "unit"), null, unitPrice, amount, hasColor);
            run.lines.add(new LineResult(IntakeLineExtractor.build(raw)));
        }
        if (run.droppedAiLines > 0) {
            run.notices.removeIf(n -> n.startsWith("有 ") && n.endsWith("行看不清, 已跳过"));
            run.notices.add("有 " + run.droppedAiLines + " 行看不清, 已跳过");
        }
        return sequence;
    }

    /**
     * AI 表头只补规则没取到的项; 名称/地址/单号等必须在发给 AI 的原文里出现过(防编造), 日期、贸易条款、国家按白名单解析。
     */
    static void mergeAiHeader(IntakeHeader h, JsonNode node, String sourceText, Map<String, String> placeholders,
                              String source) {
        boolean used = false;
        String haystack = sourceText == null ? null : squash(sourceText);
        if (h.buyerName == null) {
            h.buyerName = verified(IntakeAi.text(node, "buyerName"), haystack, placeholders);
            used |= h.buyerName != null;
        }
        if (h.buyerAddress == null) {
            h.buyerAddress = verified(IntakeAi.text(node, "buyerAddress"), haystack, placeholders);
            used |= h.buyerAddress != null;
        }
        if (h.contactName == null) {
            h.contactName = verified(IntakeAi.text(node, "contactName"), haystack, placeholders);
            used |= h.contactName != null;
        }
        if (h.docNo == null) {
            h.docNo = verified(IntakeAi.text(node, "docNo"), haystack, placeholders);
            used |= h.docNo != null;
        }
        if (h.paymentTerms == null) {
            h.paymentTerms = verified(IntakeAi.text(node, "paymentTerms"), haystack, placeholders);
            used |= h.paymentTerms != null;
        }
        if (h.port == null) {
            h.port = verified(IntakeAi.text(node, "port"), haystack, placeholders);
            used |= h.port != null;
        }
        if (h.docDate == null) {
            h.docDate = IntakeHeaderRules.parseDate(IntakeAi.text(node, "docDate"));
            used |= h.docDate != null;
        }
        if (h.incoterm == null) {
            String term = IntakeAi.text(node, "incoterm");
            if (term != null && term.toUpperCase(Locale.ROOT).matches("EXW|FOB|CIF|CFR|DDP|DAP|FCA|CPT|CIP|DDU")) {
                h.incoterm = term.toUpperCase(Locale.ROOT);
                used = true;
            }
        }
        if (h.country == null) {
            h.country = IntakeCountries.normalize(IntakeAi.text(node, "country"));
            used |= h.country != null;
        }
        if (used) {
            h.source = source;
        }
        for (String value : placeholders.values()) {
            if (value.contains("@")) {
                h.addEmail(value);
            }
        }
    }

    private static String verified(String value, String haystack, Map<String, String> placeholders) {
        if (value == null) {
            return null;
        }
        if (haystack != null && !haystack.contains(squash(value))) {
            return null;
        }
        String unmasked = IntakeHeaderRules.unmask(value, placeholders);
        return IntakeHeaderRules.cleanValue(unmasked);
    }

    private static String squash(String s) {
        return IntakeTextNormalizer.nfkc(s).toLowerCase(Locale.ROOT).replaceAll("\\s+", "");
    }

    /** 只留字母和数字(比对「AI 抄的行在原文里有没有」时不计较空格、标点和换行)。 */
    static String loose(String s) {
        return IntakeTextNormalizer.nfkc(s).toLowerCase(Locale.ROOT).replaceAll("[^\\p{L}\\p{N}]", "");
    }

    /**
     * AI 抽出的货品行必须能在发给它的原文里找到(防编造/被文件里的指令带偏): 型号出现在原文里, 或描述某一行的开头
     * (最多 12 个字母数字)出现在原文里。比较前两边都只留字母和数字。
     */
    static boolean appearsIn(String partNo, String description, String sentLoose) {
        String part = partNo == null ? "" : loose(partNo);
        if (!part.isEmpty() && sentLoose.contains(part)) {
            return true;
        }
        if (description != null) {
            for (String piece : description.split("\\R")) {
                String d = loose(piece);
                if (d.length() >= 3 && sentLoose.contains(d.length() > 12 ? d.substring(0, 12) : d)) {
                    return true;
                }
            }
        }
        return false;
    }

    /** AI 给的数量/单价/金额是否在合理范围: 不超过 10 亿、小数不超过 6 位(去掉末尾的 0 后)。 */
    static boolean plausibleNumber(BigDecimal value) {
        if (value == null) {
            return true;
        }
        return value.abs().compareTo(MAX_AI_NUMBER) <= 0 && value.stripTrailingZeros().scale() <= MAX_AI_SCALE;
    }

    // ------------------------------------------------------------------ currency

    CurrencyInfo resolveCurrency(String fileCurrency) {
        List<CurrencyRow> rows = data.currencies();
        CurrencyRow base = rows.stream().filter(CurrencyRow::base).findFirst().orElse(null);
        UUID baseId = base == null ? null : base.id();
        String baseName = base == null ? "人民币" : Objects.requireNonNullElse(base.name(), "人民币");
        if (fileCurrency == null) {
            return new CurrencyInfo(null, baseId, baseName, false, null, null);
        }
        String label = IntakeReferenceData.CURRENCY_LABELS.getOrDefault(fileCurrency, fileCurrency);
        if (base != null && matchesCurrency(base, fileCurrency)) {
            return new CurrencyInfo(fileCurrency, baseId, baseName, false, null, label);
        }
        if (base == null && "CNY".equals(fileCurrency)) {
            return new CurrencyInfo(fileCurrency, null, baseName, false, null, label);
        }
        CurrencyRow match = rows.stream().filter(r -> !r.base() && matchesCurrency(r, fileCurrency)).findFirst().orElse(null);
        BigDecimal rate = match == null || match.exchangeRate() == null || match.exchangeRate().signum() <= 0
                ? null : match.exchangeRate();
        return new CurrencyInfo(fileCurrency, baseId, baseName, true, rate, label);
    }

    private static boolean matchesCurrency(CurrencyRow row, String iso) {
        Set<String> aliases = IntakeReferenceData.CURRENCY_ALIASES.getOrDefault(iso, Set.of(iso));
        String code = row.code() == null ? "" : row.code().strip().toUpperCase(Locale.ROOT);
        String name = row.name() == null ? "" : row.name().strip().toUpperCase(Locale.ROOT);
        for (String alias : aliases) {
            String a = alias.toUpperCase(Locale.ROOT);
            if (code.equals(a) || name.contains(a)) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------ goods matching

    private void matchGoodsWithoutClient(Run run) {
        GoodsCandidateRetriever retriever = new GoodsCandidateRetriever(lookup);
        List<ExtractedLine> lines = run.lines.stream().map(l -> l.line).toList();
        run.retrieval = retriever.retrieve(lines, run.params.clientId());
        if (run.params.clientId() != null) {
            return;
        }
        Collection<GoodsRow> pool = run.retrieval.rows().values();
        for (LineResult l : run.lines) {
            run.freeScoring.put(l.line.key(), GoodsMatcher.score(l.input, pool, ClientContext.NONE,
                    aliasesFor(l, run.retrieval.aliases(), null), run.currency.priceContext()));
        }
    }

    private void matchClient(Run run) {
        int visible = lookup.visibleActiveClientCount();
        List<ClientCandidate> candidates = visible > 0 ? lookup.clientCandidates(ClientMatcher.query(run.header)) : List.of();
        Map<String, List<Scored>> freeRanked = new LinkedHashMap<>();
        run.freeScoring.forEach((k, v) -> freeRanked.put(k, v.ranked()));
        List<Set<UUID>> lineGoods = ClientMatcher.lineGoodsSets(freeRanked);
        Map<UUID, Set<UUID>> basket = new HashMap<>();
        Set<UUID> goodsIds = ClientMatcher.allGoods(lineGoods);
        if (visible > 0 && !goodsIds.isEmpty()) {
            List<UUID> candidateIds = candidates.stream().map(ClientCandidate::clientId).distinct().toList();
            // 有买方线索(名称/邮箱/电话/国家等)时, 篮子重合度只在线索找到的候选客户之间比较(不让别的老客户
            // 仅凭买过同样的货品把强线索客户压成待核对); 文件上一条线索都没有时, 才在用户看得到的全部启用客户里
            // 比较(端口按买过的货品数只返回前若干个)。只靠篮子的客户只预选待核对, 从不自动选定;
            // 用户已经选好客户时不做这次全量比较。
            if (!candidateIds.isEmpty() || run.params.clientId() == null) {
                mergeBasket(basket, lookup.historyContains(candidateIds, goodsIds));
            }
        }
        run.clientResult = ClientMatcher.match(candidates, basket, lineGoods, run.params.clientId(), visible,
                run.header.country);
        if ("NO_VISIBLE_CLIENTS".equals(run.clientResult.status())) {
            run.notices.add(IntakeTexts.NOTICE_NO_VISIBLE_CLIENTS);
        }
        UUID selected = run.clientResult.selectedClientId();
        if (selected != null) {
            run.clientProfile = profile(run, selected);
            if (run.clientProfile == null && run.params.clientId() != null) {
                throw new ApiException(ErrorCode.FORBIDDEN, "你没有这个客户的权限");
            }
        }
    }

    private static void mergeBasket(Map<UUID, Set<UUID>> basket, Map<UUID, Set<UUID>> found) {
        if (found == null) {
            return;
        }
        found.forEach((client, goods) -> basket.computeIfAbsent(client, k -> new HashSet<>()).addAll(goods));
    }

    private ClientProfile profile(Run run, UUID clientId) {
        if (clientId == null) {
            return null;
        }
        return run.profiles.computeIfAbsent(clientId, lookup::clientProfile);
    }

    private void matchGoodsForClient(Run run) {
        UUID clientId = run.clientResult.selectedClientId();
        GoodsCandidateRetriever retriever = new GoodsCandidateRetriever(lookup);
        GoodsCandidateRetriever.Retrieval retrieval = run.retrieval;
        if (clientId != null && run.params.clientId() == null) {
            List<ExtractedLine> lines = run.lines.stream().map(l -> l.line).toList();
            retrieval = retriever.withAliases(retrieval, lines, clientId);
        }
        Map<UUID, GoodsRow> pool = new LinkedHashMap<>(retrieval.rows());
        if (clientId != null && run.clientProfile != null) {
            run.history = retriever.history(clientId);
            for (GoodsRow g : run.history.rows()) {
                pool.putIfAbsent(g.id(), g);
            }
            LocalDate today = LocalDate.now(clock);
            run.clientContext = new ClientContext(clientId, run.clientProfile.name(), run.clientProfile.placeId(),
                    run.history.history(), today.minusMonths(GoodsMatcher.RECENT_MONTHS_FOR_SERIES));
        }
        run.retrieval = new GoodsCandidateRetriever.Retrieval(pool, retrieval.aliases());
        // 客户只是推测(待核对)时, 它的历史与对照照常参与排序, 但不能单凭它们自动对应: 不看客户也能对上同一个货品才算。
        boolean clientUnconfirmed = clientId != null && "REVIEW".equals(run.clientResult.status());
        for (LineResult l : run.lines) {
            l.scoring = GoodsMatcher.score(l.input, pool.values(), run.clientContext,
                    aliasesFor(l, retrieval.aliases(), clientId), run.currency.priceContext());
            l.decision = GoodsMatcher.decide(l.input, l.scoring, run.clientContext);
            if (clientUnconfirmed && l.decision.status() == Status.MATCHED && !matchedWithoutClient(run, l)) {
                l.decision = new Decision(Status.REVIEW, Reason.CLIENT_UNCONFIRMED, l.decision.top());
            }
            applyDecision(l);
            if (l.line.bundle()) {
                l.bundleParts = bundleParts(l, pool.values(), run.clientContext, run.currency);
            }
        }
    }

    /** 不看客户的那一轮也自动对应到同一个货品。 */
    private static boolean matchedWithoutClient(Run run, LineResult l) {
        Scoring free = run.freeScoring.get(l.line.key());
        if (free == null) {
            return false;
        }
        Decision d = GoodsMatcher.decide(l.input, free, ClientContext.NONE);
        return d.status() == Status.MATCHED && d.top() != null
                && d.top().goods.id().equals(l.decision.top().goods.id());
    }

    private static List<MasterIntakeLookupPort.AliasRow> aliasesFor(LineResult l, List<MasterIntakeLookupPort.AliasRow> all,
                                                                    UUID clientId) {
        List<MasterIntakeLookupPort.AliasRow> out = new ArrayList<>();
        for (MasterIntakeLookupPort.AliasRow a : all) {
            if (a.scope() == MasterIntakeLookupPort.AliasScope.CLIENT && (clientId == null || !clientId.equals(a.clientId()))) {
                continue;
            }
            if (a.norm().equals(l.input.fullPartNorm()) || a.norm().equals(l.input.descriptionNorm())
                    || a.norm().equals(l.input.descriptionAltNorm())) {
                out.add(a);
            }
        }
        return out;
    }

    private static void applyDecision(LineResult l) {
        Decision d = l.decision;
        l.status = d.status();
        List<Scored> ranked = l.scoring.ranked();
        l.shown = new ArrayList<>(GoodsMatcher.top(ranked, GoodsMatcher.TOP_K));
        l.selectedGoodsId = d.status() == Status.UNMATCHED || d.top() == null ? null : d.top().goods.id();
        l.reasonText = IntakeTexts.reasonText(d.reason(), ranked.size());
    }

    private static List<Map<String, Object>> bundleParts(LineResult l, Collection<GoodsRow> pool, ClientContext client,
                                                         CurrencyInfo currency) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (String part : l.line.bundleParts()) {
            String norm = IntakeTextNormalizer.normalizePart(part);
            LineInput input = new LineInput(l.line.key() + "#" + part, part, norm, norm, l.input.seriesNorm(),
                    l.input.colors(), null, "", "", "", l.input.contextNorm(), Double.NaN, false, false);
            Scoring scoring = GoodsMatcher.score(input, pool, client, List.of(), currency.priceContext());
            List<Map<String, Object>> candidates = new ArrayList<>();
            for (Scored s : GoodsMatcher.top(scoring.ranked(), 3)) {
                if (s.hasModelEvidence()) {
                    candidates.add(candidateMap(s, IntakePricing.price(null, s.goods.price(), currency)));
                }
            }
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("partNo", part);
            m.put("candidates", candidates);
            out.add(m);
        }
        return out;
    }

    /** AI 只帮忙挑待核对/没找到的行: 同意规则第一名且分差 ≥ 4、无冲突才自动对应; 选了别的只作预选建议。 */
    private void disambiguateWithAi(Run run) {
        if (!run.ai.usable()) {
            return;
        }
        List<LineResult> pending = run.lines.stream()
                .filter(l -> l.status != Status.MATCHED && !l.line.bundle())
                .filter(l -> !l.shown.isEmpty() || !run.history.rows().isEmpty())
                .toList();
        if (pending.isEmpty()) {
            return;
        }
        Map<String, GoodsRow> refs = new LinkedHashMap<>();
        Map<UUID, String> refOf = new HashMap<>();
        List<String> historyRefs = new ArrayList<>();
        List<GoodsRow> historyRows = new ArrayList<>(run.history.rows());
        historyRows.sort(Comparator.comparingInt((GoodsRow g) -> -run.clientContext.orderCount(g.id())));
        for (GoodsRow g : historyRows.subList(0, Math.min(AI_HISTORY_ROWS, historyRows.size()))) {
            historyRefs.add(ref(g, refs, refOf));
        }
        for (int start = 0; start < pending.size() && run.ai.usable(); start += AI_MATCH_BATCH) {
            List<LineResult> batch = pending.subList(start, Math.min(pending.size(), start + AI_MATCH_BATCH));
            List<IntakePrompts.MatchLine> matchLines = new ArrayList<>();
            Map<String, Set<String>> allowed = new HashMap<>();
            // 每批只发: 客户历史 + 这一批各行的候选(引用编号全任务统一, 不重复发前几批的候选)。
            Set<String> batchRefs = new LinkedHashSet<>(historyRefs);
            for (LineResult l : batch) {
                List<String> candidateRefs = new ArrayList<>();
                for (Scored s : l.shown) {
                    candidateRefs.add(ref(s.goods, refs, refOf));
                }
                batchRefs.addAll(candidateRefs);
                Set<String> ok = new HashSet<>(candidateRefs);
                ok.addAll(historyRefs);
                allowed.put(l.line.key(), ok);
                matchLines.add(new IntakePrompts.MatchLine(l.line.key(), customerText(l.line), candidateRefs));
            }
            Map<String, String> catalog = new LinkedHashMap<>();
            for (String r : batchRefs) {
                catalog.put(r, compact(refs.get(r)));
            }
            Optional<JsonNode> node = run.ai.call(IntakePrompts.match(matchLines, catalog, historyRefs, run.ctx.jobId()));
            if (node.isEmpty()) {
                return;
            }
            Map<String, LineResult> byKey = new HashMap<>();
            batch.forEach(l -> byKey.put(l.line.key(), l));
            for (JsonNode choice : node.get().path("choices")) {
                String key = IntakeAi.text(choice, "lineKey");
                String pick = IntakeAi.text(choice, "choice");
                LineResult l = key == null ? null : byKey.get(key);
                if (l == null || pick == null || !allowed.get(key).contains(pick)) {
                    continue;
                }
                GoodsRow goods = refs.get(pick);
                String reason = IntakeAi.text(choice, "reason");
                applyAiChoice(l, goods, reason == null ? "AI 建议选这个" : reason, run.clientContext);
            }
        }
    }

    static void applyAiChoice(LineResult l, GoodsRow goods, String reason, ClientContext client) {
        Map<String, Object> suggestion = new LinkedHashMap<>();
        suggestion.put("goodsId", goods.id().toString());
        suggestion.put("reason", reason.length() > 60 ? reason.substring(0, 60) : reason);
        l.aiSuggestion = suggestion;
        Scored top = l.shown.isEmpty() ? null : l.shown.getFirst();
        if (top != null && top.goods.id().equals(goods.id())) {
            top.evidence.add(Evidence.AI_PICK);
            double second = l.scoring.ranked().size() > 1 ? l.scoring.ranked().get(1).raw : -99;
            boolean conflict = top.hasConflict() || l.input.colors().ambiguous() || l.scoring.aliasAmbiguous()
                    || top.evidence.contains(Evidence.DISCOUNT_ODD);
            if (!conflict && top.raw >= GoodsMatcher.REVIEW_MIN && top.raw - second >= AI_AGREE_MARGIN
                    && l.decision.reason() != Reason.MULTI_SERIES && l.decision.reason() != Reason.CLIENT_UNCONFIRMED) {
                l.status = Status.MATCHED;
                l.reasonText = null;
            } else if (l.status == Status.UNMATCHED) {
                l.status = Status.REVIEW;
                l.reasonText = IntakeTexts.reasonText(Reason.LOW_SCORE, l.shown.size());
            }
            l.selectedGoodsId = goods.id();
            return;
        }
        Scored picked = GoodsMatcher.find(l.scoring.ranked(), goods.id());
        if (picked == null) {
            picked = new Scored(goods);
            picked.raw = 0;
            int count = client.orderCount(goods.id());
            if (count > 0) {
                picked.historyCount = count;
                picked.evidence.add(Evidence.BOUGHT_BEFORE);
            }
        }
        picked.evidence.add(Evidence.AI_PICK);
        if (!l.shown.contains(picked)) {
            if (l.shown.size() >= GoodsMatcher.TOP_K) {
                l.shown.removeLast();
            }
            l.shown.add(Math.min(1, l.shown.size()), picked);
        }
        l.status = Status.REVIEW;
        l.selectedGoodsId = goods.id();
        l.reasonText = "AI 建议选另一个货品, 请核对";
    }

    private static String ref(GoodsRow g, Map<String, GoodsRow> refs, Map<UUID, String> refOf) {
        return refOf.computeIfAbsent(g.id(), id -> {
            String r = "g" + (refs.size() + 1);
            refs.put(r, g);
            return r;
        });
    }

    private static String compact(GoodsRow g) {
        return String.join(" | ", nz(g.code()), nz(g.name()), nz(g.model()), nz(g.series()), nz(g.colorName()));
    }

    private static String customerText(ExtractedLine line) {
        List<String> parts = new ArrayList<>();
        if (line.partNo() != null) {
            parts.add("part " + line.partNo());
        }
        if (line.description() != null) {
            parts.add(line.description());
        }
        if (line.descriptionAlt() != null) {
            parts.add(line.descriptionAlt());
        }
        if (line.series() != null) {
            parts.add("series " + line.series());
        }
        if (line.color() != null || line.colorAlt() != null) {
            parts.add("colour " + nz(line.color()) + " " + nz(line.colorAlt()));
        }
        return PromptTable.cellText(String.join(" ; ", parts));
    }

    private static String nz(String s) {
        return s == null ? "" : s.strip();
    }

    /** 两行及以上对应到同一个货品: 全部待核对。 */
    static void markDuplicateGoods(Run run) {
        Map<UUID, List<LineResult>> byGoods = new HashMap<>();
        for (LineResult l : run.lines) {
            if (l.selectedGoodsId != null) {
                byGoods.computeIfAbsent(l.selectedGoodsId, k -> new ArrayList<>()).add(l);
            }
        }
        for (List<LineResult> group : byGoods.values()) {
            if (group.size() < 2) {
                continue;
            }
            for (LineResult l : group) {
                l.status = Status.REVIEW;
                l.reasonText = IntakeTexts.REASON_DUPLICATE_GOODS;
                l.warnings.add(new IntakeWarning(IntakeWarning.DUPLICATE_GOODS, IntakeTexts.REASON_DUPLICATE_GOODS));
            }
        }
    }

    // ------------------------------------------------------------------ pricing

    /**
     * 定价(SPEC §5.7)。选中货品算不出折扣时这一行一律待核对:
     * 没有标价/客户价高于标价是阻断状态(订货单不能直接导入, 计入顶部提示);
     * 文件有单价却因币种两可、折扣过低、汇率未维护等原因算不出折扣的, 也转待核对并说明原因(不阻断),
     * 绝不让「已对应」的行不带折扣就按标价导入。
     */
    private void price(Run run) {
        int blockingOnOrder = 0;
        for (LineResult l : run.lines) {
            for (Scored s : l.shown) {
                l.pricing.put(s.goods.id(), IntakePricing.price(l.line.customerUnitPrice(), s.goods.price(), run.currency));
            }
            Scored selected = l.selected();
            if (selected == null) {
                continue;
            }
            CandidatePricing p = l.pricing.get(selected.goods.id());
            if (p != null && !p.blocking() && p.discount() == null && IntakeNumbers.positive(l.line.customerUnitPrice())) {
                if (l.status == Status.MATCHED) {
                    l.status = Status.REVIEW;
                }
                String message = p.note() != null ? p.note() : "折扣算不出来, 请核对";
                l.warnings.add(new IntakeWarning(p.flag() != null ? p.flag() : IntakeWarning.PRICE_CHECK, message));
                // 「折扣异常」换成更具体的定价原因(如汇率未维护); 其他原因(重复货品、颜色不对等)保留。
                if (l.reasonText == null || l.reasonText.equals(IntakeTexts.reasonText(Reason.DISCOUNT_ODD, 0))) {
                    l.reasonText = message;
                }
                continue;
            }
            if (p != null && p.blocking()) {
                if (l.status == Status.MATCHED) {
                    l.status = Status.REVIEW;
                }
                String code = IntakePricing.NO_LIST_PRICE.equals(p.flag()) ? IntakeWarning.NO_LIST_PRICE : IntakeWarning.ABOVE_LIST;
                String message = IntakePricing.NO_LIST_PRICE.equals(p.flag())
                        ? (run.params.isOrder() ? "标价为0, 要先做报价单交给财务定价" : "标价为0, 待财务定价")
                        : "客户单价高于标价, 请核对";
                l.warnings.add(new IntakeWarning(code, message));
                if (l.reasonText == null) {
                    l.reasonText = message;
                }
                blockingOnOrder++;
            }
        }
        if (run.params.isOrder() && blockingOnOrder > 0) {
            run.notices.add("这 " + blockingOnOrder + " 个货品还没有标价(或客户价高于标价), 要先做报价单交给财务定价");
        }
    }

    // ------------------------------------------------------------------ duplicates

    private List<Map<String, Object>> duplicates(Run run) {
        UUID clientId = run.clientResult.selectedClientId();
        if (clientId == null || run.clientProfile == null) {
            return List.of();
        }
        List<DuplicateDocRow> recent = lookup.recentDocs(clientId, DUPLICATE_DAYS);
        if (recent == null || recent.isEmpty()) {
            return List.of();
        }
        Map<UUID, String> sameFile = data.docsUsingSameFile(run.ctx.input().sha256(), run.ctx.jobId());
        String docNo = run.header.docNo == null ? null : IntakeTextNormalizer.normalizePart(run.header.docNo);
        Set<String> ours = new HashSet<>();
        for (LineResult l : run.lines) {
            if (l.selectedGoodsId != null && l.line.qty() != null) {
                ours.add(l.selectedGoodsId + "|" + l.line.qty().stripTrailingZeros().toPlainString());
            }
        }
        List<Map<String, Object>> out = new ArrayList<>();
        for (DuplicateDocRow doc : recent) {
            if (doc.docId().equals(run.params.docId())) {
                continue;
            }
            String reason = null;
            if (sameFile.containsKey(doc.docId())) {
                reason = "同一个文件";
            } else if (docNo != null && doc.contractNo() != null && !docNo.isEmpty()
                    && docNo.equals(IntakeTextNormalizer.normalizePart(doc.contractNo()))) {
                reason = "同一个客户单号";
            } else if (ours.size() >= 2) {
                Set<String> theirs = new HashSet<>();
                for (DuplicateDocLine line : doc.lines()) {
                    if (line.goodsId() != null && line.qty() != null) {
                        theirs.add(line.goodsId() + "|" + line.qty().stripTrailingZeros().toPlainString());
                    }
                }
                long same = ours.stream().filter(theirs::contains).count();
                if (same * 5 >= ours.size() * 4L) {
                    reason = "明细基本相同";
                }
            }
            if (reason != null) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("docType", doc.docType());
                m.put("id", doc.docId().toString());
                m.put("billNo", doc.billNo());
                m.put("billDate", doc.billDate() == null ? null : doc.billDate().toString());
                m.put("reason", reason);
                out.add(m);
            }
        }
        return out;
    }

    // ------------------------------------------------------------------ result

    private Map<String, Object> assemble(Run run, AiJobInput input, DocumentKind kind) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("schemaVersion", SCHEMA_VERSION);
        result.put("docType", run.params.docType());

        Map<String, Object> file = new LinkedHashMap<>();
        file.put("name", input.fileName());
        file.put("kind", kind.name());
        file.put("sheet", run.sheetName);
        file.put("sha256", input.sha256());
        file.put("otherSheets", run.otherSheets);
        result.put("file", file);

        Map<String, Object> extraction = new LinkedHashMap<>();
        extraction.put("layoutSource", run.layoutSource);
        extraction.put("headerSource", run.header.source);
        extraction.put("aiUsed", run.ai.used());
        extraction.put("layoutFingerprint", run.layout == null ? null : run.layout.fingerprint());
        extraction.put("headerTexts", run.layout == null ? null : run.layout.headerTexts());
        extraction.put("headerRow", run.layout == null ? null : run.layout.headerRow0() + 1);
        extraction.put("columnRoles", run.layout == null ? Map.of() : run.layout.columnRolesByLetter());
        result.put("extraction", extraction);

        Map<String, Object> header = run.header.toResult();
        result.put("header", header);

        Map<String, Object> currency = new LinkedHashMap<>();
        currency.put("fileCurrency", run.currency.fileCurrency());
        currency.put("baseCurrencyId", run.currency.baseCurrencyId() == null ? null : run.currency.baseCurrencyId().toString());
        currency.put("baseCurrencyName", run.currency.baseCurrencyName());
        currency.put("financeRate", run.currency.foreign() ? run.currency.financeRate() : null);
        currency.put("rateMissing", run.currency.rateMissing());
        result.put("currency", currency);

        result.put("client", clientBlock(run));
        result.put("duplicates", run.duplicates);

        List<Map<String, Object>> lines = new ArrayList<>();
        Map<String, Set<String>> descriptionModels = new HashMap<>();
        for (LineResult l : run.lines) {
            if (l.line.description() != null) {
                descriptionModels.computeIfAbsent(IntakeTextNormalizer.normalizeDescription(l.line.description()),
                        k -> new HashSet<>()).add(l.line.partNorm());
            }
        }
        int matched = 0;
        int review = 0;
        int unmatched = 0;
        BigDecimal customerTotal = BigDecimal.ZERO;
        BigDecimal unpriced = BigDecimal.ZERO;
        for (LineResult l : run.lines) {
            lines.add(lineBlock(l, descriptionModels));
            switch (l.status) {
                case MATCHED -> matched++;
                case REVIEW -> review++;
                case UNMATCHED -> unmatched++;
            }
            BigDecimal amount = l.line.customerAmount() != null ? l.line.customerAmount()
                    : l.line.customerUnitPrice() != null && l.line.qty() != null
                    ? l.line.customerUnitPrice().multiply(l.line.qty()) : null;
            if (amount != null) {
                customerTotal = customerTotal.add(amount);
                if (l.warnings.stream().anyMatch(w -> IntakeWarning.NO_LIST_PRICE.equals(w.code())
                        || IntakeWarning.ABOVE_LIST.equals(w.code()))) {
                    unpriced = unpriced.add(amount);
                }
            }
        }
        result.put("lines", lines);
        Map<String, Object> summary = new LinkedHashMap<>();
        summary.put("lineCount", run.lines.size());
        summary.put("matched", matched);
        summary.put("review", review);
        summary.put("unmatched", unmatched);
        summary.put("customerTotal", customerTotal.stripTrailingZeros());
        summary.put("unpricedCustomerAmount", unpriced.stripTrailingZeros());
        summary.put("priceMasked", false);
        result.put("summary", summary);
        result.put("notices", List.copyOf(new LinkedHashSet<>(run.notices)));
        return result;
    }

    private Map<String, Object> lineBlock(LineResult l, Map<String, Set<String>> descriptionModels) {
        ExtractedLine x = l.line;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("key", x.key());
        m.put("sourceSheet", x.sourceSheet());
        m.put("sourceRow", x.sourceRow());
        m.put("lineNo", x.lineNo());
        m.put("partNo", x.partNo());
        m.put("description", x.description());
        m.put("descriptionAlt", x.descriptionAlt());
        m.put("series", x.series());
        m.put("color", x.color());
        m.put("colorAlt", x.colorAlt());
        m.put("mainColor", x.colors().mainLabel());
        m.put("frameColor", x.colors().frameLabel());
        m.put("contextNorm", x.contextNorm());
        m.put("qty", x.qty());
        m.put("unit", x.unit());
        m.put("suggestedQty", x.suggestedQty());
        m.put("customerUnitPrice", x.customerUnitPrice());
        m.put("customerAmount", x.customerAmount());
        m.put("bundle", x.bundle());
        m.put("bundleParts", l.bundleParts);
        m.put("assembled", x.assembled());
        m.put("status", l.status.name());
        m.put("confidenceLevel", confidence(l));
        m.put("reasonText", l.status == Status.MATCHED ? null : l.reasonText);
        m.put("selectedGoodsId", l.selectedGoodsId == null ? null : l.selectedGoodsId.toString());
        m.put("aiSuggestion", l.aiSuggestion);
        String nameEnText = nameEnText(x);
        m.put("setNameEnDefault", setNameEnDefault(l, nameEnText, descriptionModels));
        m.put("nameEnText", nameEnText);
        List<Map<String, Object>> candidates = new ArrayList<>();
        for (Scored s : l.shown) {
            candidates.add(candidateMap(s, l.pricing.get(s.goods.id())));
        }
        m.put("candidates", candidates);
        List<Map<String, Object>> warnings = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (IntakeWarning w : l.warnings) {
            if (seen.add(w.code() + "|" + w.message())) {
                Map<String, Object> wm = new LinkedHashMap<>();
                wm.put("code", w.code());
                wm.put("message", w.message());
                warnings.add(wm);
            }
        }
        m.put("warnings", warnings);
        return m;
    }

    static Map<String, Object> candidateMap(Scored s, CandidatePricing pricing) {
        GoodsRow g = s.goods;
        Map<String, Object> c = new LinkedHashMap<>();
        c.put("goodsId", g.id().toString());
        c.put("code", g.code());
        c.put("name", g.name());
        c.put("model", g.model());
        c.put("series", g.series());
        c.put("spec", g.spec());
        c.put("colorId", g.colorId() == null ? null : g.colorId().toString());
        c.put("colorName", g.colorName());
        c.put("unitId", g.unitId() == null ? null : g.unitId().toString());
        c.put("unitName", g.unitName());
        c.put("nameEn", g.nameEn());
        c.put("score", s.reportedScore());
        c.put("reasons", IntakeTexts.reasons(s));
        c.put("listPrice", g.price());
        c.put("discount", pricing == null ? null : pricing.discount());
        c.put("rateUsed", pricing == null ? null : pricing.rateUsed());
        c.put("pricingFlag", pricing == null ? null : pricing.flag());
        c.put("pricingNote", pricing == null ? null : pricing.note());
        // 订货单不能直接导入这个货品(没有标价或客户价高于标价, 要先做报价单交财务定价)。不是价格本身,
        // 看不到价格的读者也保留(IntakeResultFilter 不去掉), 订货页据此不勾选并提示改做报价单。
        c.put("orderBlocked", pricing != null && pricing.blocking());
        return c;
    }

    private static String confidence(LineResult l) {
        if (l.status == Status.MATCHED) {
            return "HIGH";
        }
        Scored top = l.shown.isEmpty() ? null : l.shown.getFirst();
        if (l.status == Status.REVIEW && top != null && top.raw >= 85) {
            return "MEDIUM";
        }
        return "LOW";
    }

    static String nameEnText(ExtractedLine line) {
        if (line.description() == null) {
            return null;
        }
        String t = line.description().replaceAll("\\s+", " ").strip();
        return t.length() > 255 ? t.substring(0, 255).strip() : t;
    }

    /**
     * 「设为货品英文名」默认勾选: 选中的货品还没有英文名、文字至少两个词且不含中文、同一文件里没被多个型号共用、
     * 也不等于别的候选货品的英文名。
     */
    static boolean setNameEnDefault(LineResult l, String nameEnText, Map<String, Set<String>> descriptionModels) {
        Scored selected = l.selected();
        if (selected == null || nameEnText == null || l.status == Status.UNMATCHED) {
            return false;
        }
        if (selected.goods.nameEn() != null && !selected.goods.nameEn().isBlank()) {
            return false;
        }
        if (IntakeTextNormalizer.hasCjk(nameEnText) || nameEnText.split("\\s+").length < 2) {
            return false;
        }
        String norm = IntakeTextNormalizer.normalizeDescription(nameEnText);
        Set<String> models = descriptionModels.getOrDefault(norm, Set.of());
        if (models.size() > 1) {
            return false;
        }
        for (Scored s : l.shown) {
            if (s != selected && s.goods.nameEn() != null
                    && IntakeTextNormalizer.normalizeDescription(s.goods.nameEn()).equals(norm)) {
                return false;
            }
        }
        return true;
    }

    private Map<String, Object> clientBlock(Run run) {
        ClientMatcher.Result r = run.clientResult;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", r.status());
        m.put("selectedClientId", r.selectedClientId() == null ? null : r.selectedClientId().toString());
        List<Map<String, Object>> candidates = new ArrayList<>();
        Map<UUID, ClientCandidate> byId = new HashMap<>();
        for (ClientMatcher.ScoredClient s : r.ranked()) {
            if (s.candidate != null) {
                byId.put(s.clientId, s.candidate);
            }
        }
        boolean selectedListed = false;
        for (ClientMatcher.ScoredClient s : r.ranked()) {
            Map<String, Object> c = clientSummary(run, s.clientId, byId.get(s.clientId));
            if (c == null) {
                continue;
            }
            c.put("score", (int) Math.round(Math.min(99, s.score)));
            c.put("reasons", List.copyOf(new LinkedHashSet<>(s.reasons)));
            candidates.add(c);
            selectedListed |= s.clientId.equals(r.selectedClientId());
        }
        if (!selectedListed && r.selectedClientId() != null) {
            Map<String, Object> c = clientSummary(run, r.selectedClientId(), null);
            if (c != null) {
                c.put("score", null);
                c.put("reasons", List.of("你已选择的客户"));
                candidates.addFirst(c);
            }
        }
        m.put("candidates", candidates);
        String warning = null;
        if (r.strongOther() != null && run.clientProfile != null) {
            Map<String, Object> other = clientSummary(run, r.strongOther().clientId, r.strongOther().candidate);
            if (other != null) {
                warning = "文件上的买方像是「" + other.get("name") + "」, 和你选的客户「" + run.clientProfile.name() + "」不一致";
            }
        }
        m.put("mismatchWarning", warning);
        m.put("enrichment", enrichment(run));
        m.put("newClientProposal", "UNMATCHED".equals(r.status()) ? newClientProposal(run.header) : null);
        return m;
    }

    private Map<String, Object> clientSummary(Run run, UUID clientId, ClientCandidate candidate) {
        Map<String, Object> c = new LinkedHashMap<>();
        c.put("clientId", clientId.toString());
        if (candidate != null) {
            c.put("code", candidate.code());
            c.put("name", candidate.name());
            c.put("fullName", candidate.fullName());
            c.put("nameEn", candidate.nameEn());
            return c;
        }
        ClientProfile p = profile(run, clientId);
        if (p == null) {
            return null;
        }
        c.put("code", p.code());
        c.put("name", p.name());
        c.put("fullName", p.fullName());
        c.put("nameEn", p.nameEn());
        return c;
    }

    /** 文件里有而客户资料里没有(或不同)的信息; 只有调用人能改这个客户时才给。 */
    static List<Map<String, Object>> enrichment(Run run) {
        ClientProfile p = run.clientProfile;
        if (p == null || !p.editable()) {
            return List.of();
        }
        IntakeHeader h = run.header;
        List<Map<String, Object>> out = new ArrayList<>();
        String buyer = h.buyerName;
        if (buyer != null && IntakeTextNormalizer.isLatinDominant(buyer)) {
            addField(out, "nameEn", "外文名称", p.nameEn(), buyer);
        }
        if (buyer != null && blank(p.fullName())) {
            addField(out, "fullName", "全称", p.fullName(), buyer);
        }
        addField(out, "linkman", "联系人", p.linkman(), h.contactName);
        if (!h.emails.isEmpty()) {
            String email = h.emails.getFirst();
            boolean known = email.equalsIgnoreCase(nz(p.email()))
                    || p.contactEmails().stream().anyMatch(e -> e.equalsIgnoreCase(email));
            if (!known) {
                addField(out, "email", "邮箱", p.email(), email);
            }
        }
        if (!h.phones.isEmpty()) {
            String phone = h.phones.getFirst();
            String last8 = last8(phone);
            boolean known = last8.equals(last8(p.phone())) || last8.equals(last8(p.mobile()))
                    || p.contactPhones().stream().anyMatch(x -> last8.equals(last8(x)));
            if (!known && !last8.isEmpty()) {
                addField(out, "phone", "电话", p.phone(), phone);
            }
        }
        addField(out, "address", "地址", p.address(), h.buyerAddress);
        addField(out, "taxId", "税号", p.taxId(), h.taxId);
        return out;
    }

    private static void addField(List<Map<String, Object>> out, String field, String label, String current, String proposed) {
        if (proposed == null || proposed.isBlank()) {
            return;
        }
        boolean differs = !blank(current) && !squash(current).equals(squash(proposed));
        if (!blank(current) && !differs) {
            return;
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("field", field);
        m.put("label", label);
        m.put("current", blank(current) ? null : current);
        m.put("proposed", proposed.strip());
        m.put("defaultChecked", blank(current));
        m.put("differs", differs);
        out.add(m);
    }

    static Map<String, Object> newClientProposal(IntakeHeader h) {
        if (h.buyerName == null) {
            return null;
        }
        Map<String, Object> m = new LinkedHashMap<>();
        String name = h.buyerName.length() > 64 ? h.buyerName.substring(0, 64).strip() : h.buyerName;
        m.put("name", name);
        m.put("fullName", h.buyerName);
        m.put("nameEn", IntakeTextNormalizer.isLatinDominant(h.buyerName) ? h.buyerName : null);
        m.put("linkman", h.contactName);
        m.put("email", h.emails.isEmpty() ? null : h.emails.getFirst());
        m.put("phone", h.phones.isEmpty() ? null : h.phones.getFirst());
        m.put("address", h.buyerAddress);
        m.put("taxId", h.taxId);
        m.put("placeId", h.country);
        return m;
    }

    private static boolean blank(String s) {
        return s == null || s.isBlank();
    }

    private static String last8(String phone) {
        if (phone == null) {
            return "";
        }
        String digits = phone.replaceAll("\\D", "");
        return digits.length() >= 8 ? digits.substring(digits.length() - 8) : "";
    }

    // ------------------------------------------------------------------ helpers

    private static DocumentKind parseKind(String kind) {
        try {
            return DocumentKind.valueOf(kind);
        } catch (RuntimeException e) {
            return DocumentKind.UNSUPPORTED;
        }
    }

    private static ApiException aiFailed(Run run) {
        String message = run.ai.lastFailure() == null ? "AI 没能读出这个文件的内容, 请换一个清楚些的文件或上传 Excel"
                : "AI 识别失败: " + run.ai.lastFailure().getMessage();
        return fail(message, "AI_FAILED");
    }

    /** 识别失败(任务置为失败, 消息直接给用户看); 附带错误代码供前端区分。 */
    static ApiException fail(String message, String code) {
        return new ApiException(ErrorCode.BUSINESS, message, List.of(new ApiError.FieldError("errorCode", code)));
    }
}
