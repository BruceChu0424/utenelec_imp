package com.uten.imp.features.ai.chat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;

/**
 * ADR-153 splits one Markdown design document into knowledge chunks: by heading, about 600-1200
 * characters each, every chunk carrying its document title and section path. Implementation sections are
 * dropped ({@link AiDocKnowledgePolicy#droppedSection}) and the text is stripped of internal patterns
 * ({@link AiChatInternalContent#strip}) before it is indexed or sent anywhere.
 */
final class AiDocChunker {
    static final int MAX_CHARS = 1200;
    static final int MIN_CHARS = 600;
    static final int SMALLEST = 60;
    /** An introduction shorter than this is merged into the first section's chunk. */
    static final int INTRO_CHARS = 300;

    /** One indexed piece of a document. */
    record Chunk(String id, String path, String docTitle, String section, String text, Set<String> domains,
                 String headings) {
        /** "仓库重量账与单重自学习 / 三、决策 › 3.2 重量账规则". */
        String label() {
            return section.isEmpty() ? docTitle : docTitle + " / " + section;
        }
    }

    private record Section(List<String> headings, String body) {}

    private AiDocChunker() {}

    static List<Chunk> chunks(String relativePath, String markdown) {
        String text = markdown == null ? "" : markdown.replace("\r\n", "\n").replace('\r', '\n');
        if (!text.isEmpty() && text.charAt(0) == '\uFEFF') text = text.substring(1);
        String title = null;
        List<Section> sections = new ArrayList<>();
        List<String> stack = new ArrayList<>();
        StringBuilder body = new StringBuilder();
        boolean fenced = false;
        boolean dropped = false;
        for (String line : text.split("\n", -1)) {
            String trimmed = line.strip();
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) fenced = !fenced;
            int level = fenced ? 0 : headingLevel(line);
            if (level == 1 && title == null) {
                title = clean(line.substring(1));
                continue;
            }
            if (level >= 2) {
                if (!dropped) sections.add(new Section(List.copyOf(stack), body.toString()));
                body.setLength(0);
                String heading = clean(line.substring(level));
                while (stack.size() >= level - 1) stack.removeLast();
                while (stack.size() < level - 2) stack.add("");
                stack.add(heading);
                dropped = stack.stream().anyMatch(AiDocKnowledgePolicy::droppedSection);
                continue;
            }
            if (!fenced && AiDocKnowledgePolicy.METADATA_LINE.matcher(line).matches()) continue;
            body.append(line).append('\n');
        }
        if (!dropped) sections.add(new Section(List.copyOf(stack), body.toString()));
        String docTitle = displayTitle(title, relativePath);
        Set<String> domains = AiDocKnowledgePolicy.domains(relativePath, title);
        return pack(relativePath, docTitle, domains, sections);
    }

    /** Packs sections into chunks: long ones split at paragraphs, short neighbours under one top heading merged. */
    private static List<Chunk> pack(String path, String docTitle, Set<String> domains, List<Section> sections) {
        List<Chunk> chunks = new ArrayList<>();
        List<String> names = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        String top = null;
        for (Section section : sections) {
            String cleaned = AiDocKnowledgePolicy.withoutSecurityText(readable(AiChatInternalContent.strip(section.body())));
            String sectionTop = section.headings().isEmpty() ? "" : section.headings().getFirst();
            if (cleaned.length() < 2) continue;
            boolean sameTop = top != null && top.equals(sectionTop);
            // A short introduction (the text before the first heading, often the current user rule in one sentence)
            // stays with the first section instead of becoming a tiny chunk of its own.
            boolean shortIntro = top != null && top.isEmpty() && current.length() < INTRO_CHARS;
            if (current.length() > 0 && ((!sameTop && !shortIntro) || current.length() >= MIN_CHARS
                    || current.length() + cleaned.length() > MAX_CHARS)) {
                emit(chunks, path, docTitle, domains, names, current.toString());
                names.clear();
                current.setLength(0);
            }
            top = sectionTop;
            String name = String.join(" › ", section.headings().stream().filter(heading -> !heading.isEmpty()).toList());
            if (cleaned.length() <= MAX_CHARS) {
                if (!names.contains(name)) names.add(name);
                if (current.length() > 0) current.append("\n\n");
                current.append(cleaned);
                continue;
            }
            for (String piece : split(cleaned)) {
                if (current.length() > 0) {
                    emit(chunks, path, docTitle, domains, names, current.toString());
                    names.clear();
                    current.setLength(0);
                }
                names.add(name);
                current.append(piece);
            }
        }
        if (current.length() > 0) emit(chunks, path, docTitle, domains, names, current.toString());
        return List.copyOf(chunks);
    }

    private static void emit(List<Chunk> chunks, String path, String docTitle, Set<String> domains,
                             List<String> names, String text) {
        String body = text.strip();
        if (body.length() < SMALLEST) return;
        List<String> named = names.stream().filter(name -> !name.isEmpty()).toList();
        String section = named.isEmpty() ? "" : named.size() == 1 ? named.getFirst()
                : named.getFirst() + " 等" + named.size() + "节";
        String id = "doc-" + hash(path + "\n" + section + "\n" + chunks.size());
        // Every merged section's heading is searchable, not only the first one shown in the label.
        chunks.add(new Chunk(id, path, docTitle, section, body, domains, docTitle + " " + String.join(" ", named)));
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
            if (!tableLine(lines[i])) {
                out.append(lines[i]);
                if (i < lines.length - 1) out.append('\n');
                i++;
                continue;
            }
            List<List<String>> rows = new ArrayList<>();
            while (i < lines.length && tableLine(lines[i])) rows.add(cells(lines[i++]));
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

    private static boolean tableLine(String line) {
        String value = line.strip();
        return value.startsWith("|") && value.length() > 1 && value.indexOf('|', 1) > 0;
    }

    private static List<String> cells(String line) {
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
