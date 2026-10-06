package com.uten.imp.features.ai.chat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * ADR-153 splits one Markdown design document into knowledge chunks: by heading, about 600-1200
 * characters each, every chunk carrying its document title and section path. Implementation sections are
 * dropped ({@link AiDocKnowledgePolicy#droppedSection}) and the text is stripped of internal patterns
 * ({@link AiChatInternalContent#strip}) before it is indexed or sent anywhere.
 *
 * <p>A document whose top says it was wholly replaced by a later one becomes one short pointer to its successor; a
 * page document of a page never built (「未实施提案」) gives nothing; each row of the business glossary
 * ({@link AiDocGlossary}) is a chunk of its own. The file name and an optional {@code > 别名：…} line near the top are
 * searchable with the title.
 *
 * <p>ADR-159: in a document every chat user reads, a section whose heading (or a list item whose bold lead) is about
 * personnel or finance ({@link AiDocKnowledgePolicy#sectionDomains}) becomes chunks of its own carrying that domain, so
 * it is shown only to readers of that department; it never shares a chunk with the shared rules around it.
 */
final class AiDocChunker {
    static final int MAX_CHARS = 1200;
    static final int MIN_CHARS = 600;
    static final int SMALLEST = 60;
    /** A glossary row is short by nature; below this it says nothing. */
    static final int SMALLEST_ROW = 10;
    /** An introduction shorter than this is merged into the first section's chunk. */
    static final int INTRO_CHARS = 300;
    /** Ranking weight of the pointer left for a wholly replaced document (it points to the rule, it is not one). */
    static final double POINTER_PRIOR = 0.5;
    /** Ranking weight of a glossary definition: short and dense, it would otherwise outrank the rules it summarizes. */
    static final double DEFINITION_PRIOR = 0.5;
    /** Stands for a heading that names internals in the heading stack (that section and its subsections are dropped). */
    private static final String INTERNAL_HEADING = "#internal";
    /** Section label of the pointer left for a wholly replaced document. */
    static final String SUPERSEDED_SECTION = "已被取代";

    /** What a chunk is: part of a document's rules, one glossary definition, or the pointer left for a replaced document. */
    enum Kind { RULE, DEFINITION, POINTER }

    /**
     * One indexed piece of a document.
     *
     * @param headings     searchable title text: the document name and every merged section's heading
     * @param documentName searchable name of the whole document: its title, file name and aliases (for a glossary row
     *                     also its term and everyday words)
     * @param kind         rules, a glossary definition or a pointer to the document that replaced this one
     * @param prior        fixed ranking weight (below 1 for a plan or a pointer to a replaced document)
     * @param sectionDomains ADR-159 the personnel or finance domain a section of an everyone-readable document is about
     *                     (its heading or a list item's bold lead says so); a reader needs one of them besides the
     *                     document's own gate. Empty for a shared section.
     */
    record Chunk(String id, String path, String docTitle, String section, String text, Set<String> domains,
                 String headings, String documentName, Kind kind, double prior, Set<String> sectionDomains) {
        /** "仓库重量账与单重自学习 / 三、决策 › 3.2 重量账规则". */
        String label() {
            return section.isEmpty() ? docTitle : docTitle + " / " + section;
        }
    }

    /** One heading's text, or the part of it under one list item lead, with the restricted domains it is about. */
    private record Section(List<String> headings, String body, Set<String> domains) {}

    /** {@code > 别名：A、B} near the top: everyday names of the document's subject. */
    private static final Pattern ALIAS_LINE = Pattern.compile("^\\s*>\\s*(?:\\*\\*)?别名(?:\\*\\*)?\\s*[:：]\\s*(.+)$");
    /** A link to the successor decision record in a supersession banner. */
    private static final Pattern SUCCESSOR_LINK = Pattern.compile("\\[(ADR-\\d+)[^\\]]*\\]\\(([^)\\s]*?)(?:\\.md)?\\)");
    private static final Pattern SUCCESSOR_ID = Pattern.compile("ADR-\\d+");
    private static final Pattern DATE = Pattern.compile("\\d{4}-\\d{2}-\\d{2}");
    /** A space between Chinese words or punctuation: the place of an internal name that was removed. */
    private static final Pattern HOLE = Pattern.compile(
            "[\\p{IsHan}\u3001\uFF0C\uFF1A\uFF1B\uFF08(]\\s+[\\p{IsHan}\u3001\uFF0C\uFF1B\uFF09)]");
    /** At most this much of a supersession banner's explanation goes with the pointer. */
    private static final int POINTER_DETAIL_CHARS = 300;

    private AiDocChunker() {}

    static List<Chunk> chunks(String relativePath, String markdown) {
        String text = markdown == null ? "" : markdown.replace("\r\n", "\n").replace('\r', '\n');
        if (!text.isEmpty() && text.charAt(0) == '\uFEFF') text = text.substring(1);
        String[] lines = text.split("\n", -1);
        String title = null;
        for (String line : lines) {
            if (headingLevel(line) == 1) {
                title = clean(line.substring(1));
                break;
            }
        }
        if (AiDocKnowledgePolicy.unimplemented(title)) return List.of();
        String docTitle = displayTitle(title, relativePath);
        Set<String> domains = AiDocKnowledgePolicy.domains(relativePath, title);
        String documentName = documentName(relativePath, docTitle, aliases(text));
        String banner = supersessionBanner(lines);
        if (banner != null) return List.of(pointer(relativePath, docTitle, domains, documentName, banner));

        List<Section> sections = new ArrayList<>();
        List<AiDocGlossary.Entry> rows = new ArrayList<>();
        List<String> stack = new ArrayList<>();
        StringBuilder body = new StringBuilder();
        boolean fenced = false;
        boolean dropped = false;
        boolean titleSeen = false;
        // ADR-159: in a document every chat user reads, a section about personnel or finance (by its heading, or by the
        // bold lead of a list item) is scoped to that domain on its own.
        boolean scoped = AiDocKnowledgePolicy.sectionScoped(relativePath, title, domains);
        boolean ownMatters = false;
        Set<String> headingScope = Set.of();
        Set<String> scope = Set.of();
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.strip();
            boolean fence = trimmed.startsWith("```") || trimmed.startsWith("~~~");
            if (fence) fenced = !fenced;
            int level = fenced ? 0 : headingLevel(line);
            if (level == 1 && !titleSeen) {
                titleSeen = true;
                continue;
            }
            if (level >= 2) {
                if (!dropped) sections.add(new Section(List.copyOf(stack), body.toString(), scope));
                body.setLength(0);
                String heading = label(clean(line.substring(level)));
                while (stack.size() >= level - 1) stack.removeLast();
                while (stack.size() < level - 2) stack.add("");
                // A heading naming internals is dropped with its subsections, like an implementation section.
                stack.add(heading == null ? INTERNAL_HEADING : heading);
                dropped = stack.stream()
                        .anyMatch(name -> name.equals(INTERNAL_HEADING) || AiDocKnowledgePolicy.droppedSection(name));
                // Under a heading about one's own matters (「我的部门」) nothing is scoped: every employee reads it.
                ownMatters = stack.stream().anyMatch(AiDocKnowledgePolicy::selfServiceHeading);
                headingScope = scoped && !ownMatters ? scopeOf(stack) : Set.of();
                scope = headingScope;
                continue;
            }
            if (scoped && !ownMatters && !fenced && !fence && !trimmed.isEmpty() && !Character.isWhitespace(line.charAt(0))) {
                // A line at the left margin starts a list item (its bold lead may scope it) or ends the current one.
                String lead = AiDocKnowledgePolicy.listStart(line) ? AiDocKnowledgePolicy.listLead(line) : null;
                Set<String> next = union(headingScope, lead == null ? Set.of() : AiDocKnowledgePolicy.sectionDomains(clean(lead)));
                if (!next.equals(scope)) {
                    if (!dropped) sections.add(new Section(List.copyOf(stack), body.toString(), scope));
                    body.setLength(0);
                    scope = next;
                }
            }
            if (!fenced && AiDocGlossary.headerRow(line)) {
                // The glossary table: its rows become chunks of their own (one term each), not one long table.
                int end = i + 1;
                while (end < lines.length && tableRow(lines[end])) end++;
                if (!dropped) rows.addAll(AiDocGlossary.parse(String.join("\n", List.of(lines).subList(i, end))));
                i = end - 1;
                continue;
            }
            if (!fenced && (AiDocKnowledgePolicy.METADATA_LINE.matcher(line).matches()
                    || ALIAS_LINE.matcher(line).matches())) continue;
            body.append(line).append('\n');
        }
        if (!dropped) sections.add(new Section(List.copyOf(stack), body.toString(), scope));
        double prior = AiDocKnowledgePolicy.documentPrior(relativePath, title);
        List<Chunk> chunks = new ArrayList<>(pack(relativePath, docTitle, domains, documentName, prior, sections));
        for (int row = 0; row < rows.size(); row++) {
            Chunk chunk = glossaryRow(relativePath, docTitle, domains, documentName, rows.get(row), row);
            if (chunk != null) chunks.add(chunk);
        }
        return List.copyOf(chunks);
    }

    /** The everyday names a document declares near its top ({@code > 别名：A、B}), in order. */
    static List<String> aliases(String markdown) {
        Set<String> aliases = new LinkedHashSet<>();
        if (markdown == null) return List.of();
        String[] lines = markdown.replace("\r\n", "\n").split("\n", -1);
        for (int i = 0; i < Math.min(lines.length, AiDocKnowledgePolicy.HEADER_LINES); i++) {
            Matcher alias = ALIAS_LINE.matcher(lines[i]);
            if (!alias.matches()) continue;
            for (String value : alias.group(1).replace("**", "").split("[、,，;；/]")) {
                String word = value.strip();
                if (word.length() >= 2 && word.length() <= 20) aliases.add(word);
            }
        }
        return List.copyOf(aliases);
    }

    /** The restricted domains the headings on the stack are about (a subsection inherits its parent's). */
    private static Set<String> scopeOf(List<String> stack) {
        Set<String> scope = new java.util.TreeSet<>();
        for (String heading : stack) scope.addAll(AiDocKnowledgePolicy.sectionDomains(heading));
        return Set.copyOf(scope);
    }

    private static Set<String> union(Set<String> a, Set<String> b) {
        if (b.isEmpty()) return a;
        if (a.isEmpty()) return b;
        Set<String> all = new java.util.TreeSet<>(a);
        all.addAll(b);
        return Set.copyOf(all);
    }

    /**
     * The searchable name of a document: its title, plus its file name when that names it differently (a page document
     * titled 「联合排产…」 is filed as 「生产计划单一键生成…」), plus its aliases.
     */
    private static String documentName(String path, String docTitle, List<String> aliases) {
        StringBuilder name = new StringBuilder(docTitle);
        String stem = displayTitle(null, path).replaceFirst("^\\d{4}-\\d{2}-\\d{2}-", "");
        Set<String> titleTerms = Set.copyOf(AiDocIndex.terms(docTitle));
        if (AiDocIndex.terms(stem).stream().filter(term -> !titleTerms.contains(term)).distinct().count() >= 2) {
            name.append(' ').append(stem);
        }
        for (String alias : aliases) name.append(' ').append(alias);
        return name.toString();
    }

    /** The banner near the top that says the whole document was replaced, or null. */
    private static String supersessionBanner(String[] lines) {
        for (int i = 0; i < Math.min(lines.length, AiDocKnowledgePolicy.HEADER_LINES); i++) {
            if (AiDocKnowledgePolicy.whollySuperseded(lines[i])) return lines[i];
        }
        return null;
    }

    /**
     * The one chunk left for a wholly replaced document: that it was replaced, by which decision and when, and what the
     * banner says changed, so a question about the old rule learns that it no longer applies and where the current
     * rule is.
     */
    private static Chunk pointer(String path, String docTitle, Set<String> domains, String documentName, String banner) {
        String successor = "";
        Matcher link = SUCCESSOR_LINK.matcher(banner);
        if (link.find()) {
            String file = link.group(2);
            successor = displayTitle(null, file.substring(file.lastIndexOf('/') + 1));
            if (successor.startsWith("ADR-") || successor.isBlank()) successor = link.group(1);
        } else {
            Matcher id = SUCCESSOR_ID.matcher(banner);
            if (id.find()) successor = id.group();
        }
        Matcher date = DATE.matcher(banner);
        String when = date.find() ? "已于 " + date.group() + " " : "已";
        String lead = "《" + docTitle + "》" + when + "被" + (successor.isEmpty() ? "后续决策" : "《" + successor + "》")
                + "整份取代，只作追溯，不是现行规则；现行规则请看" + (successor.isEmpty() ? "取代它的决策" : "《" + successor + "》") + "。";
        String detail = AiDocKnowledgePolicy.withoutSecurityText(readable(AiChatInternalContent.strip(banner)));
        int colon = Math.max(detail.indexOf('：'), detail.indexOf(':'));
        detail = colon >= 0 ? detail.substring(colon + 1).strip() : "";
        // What the banner says changed, sentence by sentence; a sentence with a hole left by a removed internal name goes.
        StringBuilder changed = new StringBuilder();
        for (String sentence : detail.split("(?<=[。；])")) {
            String value = sentence.strip();
            if (value.length() < 10 || HOLE.matcher(value).find()
                    || changed.length() + value.length() > POINTER_DETAIL_CHARS) continue;
            changed.append(value);
        }
        String text = changed.isEmpty() ? lead : lead + "\n" + changed;
        String id = "doc-" + hash(path + "\n" + SUPERSEDED_SECTION + "\n0");
        return new Chunk(id, path, docTitle, SUPERSEDED_SECTION, text, domains, documentName + " " + SUPERSEDED_SECTION,
                documentName, Kind.POINTER, POINTER_PRIOR, Set.of());
    }

    /** One glossary row as a chunk: the term is its section, its everyday words are searchable with it. */
    private static Chunk glossaryRow(String path, String docTitle, Set<String> domains, String documentName,
                                     AiDocGlossary.Entry entry, int row) {
        StringBuilder text = new StringBuilder(entry.term()).append("：").append(entry.meaning().strip());
        if (!entry.aliases().isEmpty()) text.append("\n也叫：").append(String.join("、", entry.aliases()));
        if (!entry.where().isBlank()) text.append("\n出现在：").append(entry.where().strip());
        if (!entry.related().isBlank()) text.append("\n相关说明：").append(entry.related().strip());
        String body = AiDocKnowledgePolicy.withoutSecurityText(readable(AiChatInternalContent.strip(text.toString()))).strip();
        String term = label(clean(entry.term()));
        if (term == null || term.isEmpty() || body.length() < SMALLEST_ROW) return null;
        if (body.length() > MAX_CHARS) body = body.substring(0, MAX_CHARS);
        String id = "doc-" + hash(path + "\n" + term + "\n" + row);
        // The term and its everyday words name this row the way a title names a document.
        String name = documentName + " " + term + " " + String.join(" ", entry.aliases());
        return new Chunk(id, path, docTitle, term, body, domains, name, name, Kind.DEFINITION, DEFINITION_PRIOR, Set.of());
    }

    /** Packs sections into chunks: long ones split at paragraphs, short neighbours under one top heading merged. */
    private static List<Chunk> pack(String path, String docTitle, Set<String> domains, String documentName, double prior,
                                    List<Section> sections) {
        List<Chunk> chunks = new ArrayList<>();
        List<String> names = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        String top = null;
        Set<String> scope = Set.of();
        Emitter emitter = new Emitter(chunks, path, docTitle, domains, documentName, prior);
        for (Section section : sections) {
            String cleaned = AiDocKnowledgePolicy.withoutSecurityText(readable(AiChatInternalContent.strip(section.body())));
            String sectionTop = section.headings().isEmpty() ? "" : section.headings().getFirst();
            if (cleaned.length() < 2) continue;
            boolean sameTop = top != null && top.equals(sectionTop);
            // A short introduction (the text before the first heading, often the current user rule in one sentence)
            // stays with the first section instead of becoming a tiny chunk of its own.
            boolean shortIntro = top != null && top.isEmpty() && current.length() < INTRO_CHARS;
            // A section scoped to personnel or finance never shares a chunk with a shared one (ADR-159).
            if (current.length() > 0 && ((!sameTop && !shortIntro) || !scope.equals(section.domains())
                    || current.length() >= MIN_CHARS || current.length() + cleaned.length() > MAX_CHARS)) {
                emitter.emit(names, current.toString(), scope);
                names.clear();
                current.setLength(0);
            }
            top = sectionTop;
            scope = section.domains();
            String name = String.join(" › ", section.headings().stream().filter(heading -> !heading.isEmpty()).toList());
            if (cleaned.length() <= MAX_CHARS) {
                if (!names.contains(name)) names.add(name);
                if (current.length() > 0) current.append("\n\n");
                current.append(cleaned);
                continue;
            }
            for (String piece : split(cleaned)) {
                if (current.length() > 0) {
                    emitter.emit(names, current.toString(), scope);
                    names.clear();
                    current.setLength(0);
                }
                names.add(name);
                current.append(piece);
            }
        }
        if (current.length() > 0) emitter.emit(names, current.toString(), scope);
        return List.copyOf(chunks);
    }

    private record Emitter(List<Chunk> chunks, String path, String docTitle, Set<String> domains, String documentName,
                           double prior) {
        void emit(List<String> names, String text, Set<String> sectionDomains) {
            String body = text.strip();
            if (body.length() < SMALLEST) return;
            List<String> named = names.stream().filter(name -> !name.isEmpty()).toList();
            String section = named.isEmpty() ? "" : named.size() == 1 ? named.getFirst()
                    : named.getFirst() + " 等" + named.size() + "节";
            String id = "doc-" + hash(path + "\n" + section + "\n" + chunks.size());
            // Every merged section's heading is searchable, not only the first one shown in the label.
            chunks.add(new Chunk(id, path, docTitle, section, body, domains, documentName + " " + String.join(" ", named),
                    documentName, Kind.RULE, prior, sectionDomains));
        }
    }

    /** Paragraph-boundary pieces of at most {@link #MAX_CHARS} (a single long paragraph is cut at sentence ends). */
    private static List<String> split(String text) {
        List<String> pieces = new ArrayList<>();
        StringBuilder piece = new StringBuilder();
        for (String paragraph : text.split("\n(?=\\s*\n)|\n(?=\\s*(?:[-*|]|\\d+[.、]))")) {
            String part = paragraph.strip();
            if (part.isEmpty()) continue;
            while (part.length() > MAX_CHARS) {
                int cut = Math.max(part.lastIndexOf('。', MAX_CHARS), part.lastIndexOf('\n', MAX_CHARS));
                if (cut < MAX_CHARS / 2) cut = MAX_CHARS - 1;
                String head = part.substring(0, cut + 1).strip();
                if (piece.length() > 0) {
                    pieces.add(piece.toString());
                    piece.setLength(0);
                }
                pieces.add(head);
                part = part.substring(cut + 1).strip();
            }
            if (piece.length() > 0 && piece.length() + part.length() + 1 > MAX_CHARS) {
                pieces.add(piece.toString());
                piece.setLength(0);
            }
            if (piece.length() > 0) piece.append('\n');
            piece.append(part);
        }
        if (piece.length() > 0) pieces.add(piece.toString());
        return pieces;
    }

    private static int headingLevel(String line) {
        int level = 0;
        while (level < line.length() && level < 7 && line.charAt(level) == '#') level++;
        return level >= 1 && level <= 6 && level < line.length() && line.charAt(level) == ' ' ? level : 0;
    }

    private static String clean(String heading) {
        return AiChatInternalContent.strip(heading.replace("**", "").strip()).replaceAll("\\s+", " ").strip();
    }

    /**
     * P2-1 a heading as the user may read it: a bracketed note naming internals (ports, cloned test databases,
     * acceptance runs, security or deployment words) is cut; null when the heading itself still names one (the
     * section is then not indexed).
     */
    static String label(String heading) {
        if (heading == null || !internal(heading)) return heading;
        Matcher note = BRACKETED.matcher(heading);
        StringBuilder kept = new StringBuilder();
        while (note.find()) note.appendReplacement(kept, internal(note.group()) ? "" : Matcher.quoteReplacement(note.group()));
        note.appendTail(kept);
        String value = kept.toString().replaceAll("\\s+", " ").strip();
        return internal(value) ? null : value;
    }

    /** A bracketed note in a heading: (\u2026), full-width brackets or \u3010\u2026\u3011. */
    private static final Pattern BRACKETED = Pattern.compile(
            "[(\uFF08\u3010\\[][^()\uFF08\uFF09\u3010\u3011\\[\\]]*[)\uFF09\u3011\\]]");

    private static boolean internal(String text) {
        return AiDocKnowledgePolicy.INTERNAL_LABEL.matcher(text).find()
                || AiDocKnowledgePolicy.SECURITY_TEXT.matcher(text).find();
    }

    /** Readable plain text: no emphasis or quote markers; tables as one "a | b" line per row. */
    private static String readable(String text) {
        String value = text.replace("**", "").replaceAll("(?m)^\\s*>\\s?", "");
        return tables(value).replaceAll("\n{3,}", "\n\n").strip();
    }

    /**
     * Markdown tables row by row: the separator row goes, cells left empty by the removal of internal names go,
     * and a column whose every value was internal (a permission code column) goes with its header, so "普通仓库 |
     * 财务 → 普通仓盘点审核" stays one readable row and never runs into the next one.
     */
    static String tables(String text) {
        String[] lines = text.split("\n", -1);
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < lines.length) {
            if (!tableRow(lines[i])) {
                out.append(lines[i]);
                if (i < lines.length - 1) out.append('\n');
                i++;
                continue;
            }
            List<List<String>> rows = new ArrayList<>();
            while (i < lines.length && tableRow(lines[i])) rows.add(cells(lines[i++]));
            rows.removeIf(row -> row.stream().allMatch(cell -> cell.isEmpty() || cell.matches(":?-{3,}:?")));
            int width = rows.stream().mapToInt(List::size).max().orElse(0);
            boolean[] keep = new boolean[width];
            for (int column = 0; column < width; column++) {
                for (int row = rows.size() == 1 ? 0 : 1; row < rows.size(); row++) {
                    List<String> cells = rows.get(row);
                    if (column < cells.size() && !cells.get(column).isEmpty()) keep[column] = true;
                }
            }
            for (List<String> row : rows) {
                List<String> kept = new ArrayList<>();
                for (int column = 0; column < row.size(); column++) {
                    if (keep[column] && !row.get(column).isEmpty()) kept.add(row.get(column));
                }
                if (!kept.isEmpty()) out.append(String.join(" | ", kept)).append('\n');
            }
        }
        return out.toString();
    }

    /** A Markdown table row ("| a | b |"). */
    static boolean tableRow(String line) {
        String value = line.strip();
        return value.startsWith("|") && value.length() > 1 && value.indexOf('|', 1) > 0;
    }

    /** The cells of a Markdown table row, stripped. */
    static List<String> cells(String line) {
        String value = line.strip();
        if (value.startsWith("|")) value = value.substring(1);
        if (value.endsWith("|")) value = value.substring(0, value.length() - 1);
        List<String> cells = new ArrayList<>();
        for (String cell : value.split("\\|", -1)) cells.add(cell.strip());
        return cells;
    }

    /** "ADR-135 仓库重量账与单重自学习" -> "仓库重量账与单重自学习"; a document without a title uses its file name. */
    static String displayTitle(String title, String path) {
        String value = title;
        if (value == null || value.isBlank()) {
            value = path.substring(path.lastIndexOf('/') + 1).replaceFirst("\\.md$", "");
        }
        value = value.replaceFirst("^ADR-\\d+\\s*[:：、.\\-—]?\\s*", "").replaceFirst("^\\d{1,3}-", "").strip();
        return value.length() > 60 ? value.substring(0, 60) : value;
    }

    private static String hash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest, 0, 6);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }
}
