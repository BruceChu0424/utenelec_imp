package com.uten.imp.features.ai.chat;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * The business glossary ({@value #PATH}): one Markdown table with the header {@link #HEADER}. Each row names a term,
 * the everyday words people use for it (column 2, separated by 「、」), what it means, where it shows and the related
 * documents. At index build the terms and everyday words become whole words of the vocabulary and each everyday word
 * finds its term ({@link AiDocIndex.Vocabulary}), so a colloquial question is searched in the documents' words; each
 * row is also one knowledge chunk ({@link AiDocChunker}), so 「X是什么」 is answered from the reviewed definition. A
 * missing glossary leaves both empty.
 */
final class AiDocGlossary {
    /** Where the glossary lives under docs/ ('/'-separated). */
    static final String PATH = "07-业务链路/00-业务术语与状态总表.md";
    /** The glossary table's header, cell by cell. */
    static final List<String> HEADER = List.of("术语", "俗称/也叫", "含义", "出现在哪", "相关文档");

    /** One glossary row; {@code aliases} are the everyday words, never the term itself. */
    record Entry(String term, List<String> aliases, String meaning, String where, String related) {}

    private AiDocGlossary() {}

    /** True when {@code line} is the glossary table's header row. */
    static boolean headerRow(String line) {
        return AiDocChunker.tableRow(line) && AiDocChunker.cells(line).stream().map(AiDocGlossary::plain).toList().equals(HEADER);
    }

    /** The rows of every glossary table in {@code markdown} (rows without a term are skipped). */
    static List<Entry> parse(String markdown) {
        List<Entry> entries = new ArrayList<>();
        if (markdown == null || markdown.isBlank()) return entries;
        String[] lines = markdown.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1);
        for (int i = 0; i < lines.length; i++) {
            if (!headerRow(lines[i])) continue;
            int row = i + 1;
            for (; row < lines.length && AiDocChunker.tableRow(lines[row]); row++) {
                List<String> cells = AiDocChunker.cells(lines[row]);
                if (cells.stream().allMatch(cell -> cell.isEmpty() || cell.matches(":?-{3,}:?"))) continue;
                String term = plain(cell(cells, 0));
                if (term.isEmpty()) continue;
                entries.add(new Entry(term, aliases(term, cell(cells, 1)), cell(cells, 2), cell(cells, 3), cell(cells, 4)));
            }
            i = row - 1;
        }
        return List.copyOf(entries);
    }

    private static List<String> aliases(String term, String cell) {
        Set<String> aliases = new LinkedHashSet<>();
        for (String alias : plain(cell).split("、")) {
            String value = alias.strip();
            if (value.isEmpty() || value.matches("[-—–/无]+") || value.equals(term)) continue;
            aliases.add(value);
        }
        return List.copyOf(aliases);
    }

    private static String cell(List<String> cells, int column) {
        return column < cells.size() ? cells.get(column) : "";
    }

    /** A cell's text without emphasis or inline-code markers. */
    private static String plain(String cell) {
        return cell == null ? "" : cell.replace("**", "").replace("`", "").strip();
    }
}
