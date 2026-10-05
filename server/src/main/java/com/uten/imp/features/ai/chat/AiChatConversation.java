package com.uten.imp.features.ai.chat;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * ADR-152 conversation memory given to the model: the owner's earlier turns of the same conversation,
 * from any page, oldest first, bounded to {@link #MAX_BYTES} of UTF-8 text. The newest turn keeps the
 * longest reply; when the budget runs out the oldest turns are dropped and the model is told so.
 *
 * <p>Only answers marked shareable are carried; an answer built from sensitive tool results is replaced
 * by a marker and only its question is kept. An answer whose quoted business data has changed since
 * (the tool no longer vouches for it) is replaced by its own marker as well: the question still links the
 * follow-up, the old values never return. Each turn arrives already re-authorized for the current reader
 * (same account, unchanged identity, sources still visible); turns that failed that check are counted,
 * never shown. History text is memory, not current page facts: the prompt and the answer guard treat it
 * separately from the page snapshot.
 *
 * <p>The byte budget covers the whole text as sent, including the "Turn N " prefixes and line breaks.
 */
final class AiChatConversation {
    static final int MAX_BYTES = 8 * 1024;
    static final int QUESTION_BYTES = 600;
    static final int NEWEST_REPLY_BYTES = 3000;
    static final int OLDER_REPLY_BYTES = 1200;
    static final String WITHHELD = "(该回答含敏感数据，未带入)";
    static final String DATA_CHANGED = "(这条回答引用的业务数据已变化，未带入；需要时请重新查询)";
    static final String OMITTED = "(更早的对话已省略)";

    private AiChatConversation() {}

    /**
     * One earlier turn, re-authorized for the current reader.
     *
     * @param route     model-safe route shape (record ids replaced by ":id"), or empty
     * @param toolTitle title of the tool the answer used, or empty
     * @param cards       titles of confirmation cards the answer proposed
     * @param dataChanged the business data the answer quoted has changed since; the answer is not carried
     * @param documents   design-document chunks the answer relied on (ADR-153 revision): a follow-up is answered from
     *                    the same rules, not from the bare memory of the earlier reply
     */
    record Turn(String question, String reply, boolean shareable, String pageTitle, String route, String toolTitle,
                String intent, String knowledgeId, Map<?, ?> help, Map<String, Object> query, List<String> cards,
                boolean dataChanged, List<String> documents) {
        Turn(String question, String reply, boolean shareable, String pageTitle, String route, String toolTitle,
             String intent, String knowledgeId, Map<?, ?> help, Map<String, Object> query, List<String> cards) {
            this(question, reply, shareable, pageTitle, route, toolTitle, intent, knowledgeId, help, query, cards, false, List.of());
        }

        Turn(String question, String reply, boolean shareable, String pageTitle, String route, String toolTitle,
             String intent, String knowledgeId, Map<?, ?> help, Map<String, Object> query, List<String> cards,
             boolean dataChanged) {
            this(question, reply, shareable, pageTitle, route, toolTitle, intent, knowledgeId, help, query, cards, dataChanged,
                    List.of());
        }

        Turn {
            question = question == null ? "" : question;
            reply = reply == null ? "" : reply;
            pageTitle = pageTitle == null ? "" : pageTitle;
            route = route == null ? "" : route;
            toolTitle = toolTitle == null ? "" : toolTitle;
            intent = intent == null ? "" : intent;
            knowledgeId = knowledgeId == null ? "" : knowledgeId;
            help = help == null ? Map.of() : help;
            query = query == null ? Map.of() : query;
            cards = cards == null ? List.of() : List.copyOf(cards);
            documents = documents == null ? List.of() : List.copyOf(documents);
        }
    }

    /**
     * @param carried   turns given to the model, oldest first
     * @param text      the bounded history text
     * @param truncated earlier turns were left out to stay within the budget
     * @param hidden    stored turns that no longer pass the reader checks (identity or access changed)
     */
    record History(List<Turn> carried, String text, boolean truncated, int hidden) {
        static final History NONE = new History(List.of(), "", false, 0);

        boolean isEmpty() { return carried.isEmpty(); }

        /** The latest carried turn (deterministic follow-ups such as "举个例子"), or null. */
        Turn latest() { return carried.isEmpty() ? null : carried.getLast(); }

        /** The questions of the latest {@code count} carried turns, oldest first (the topic a follow-up continues). */
        String recentQuestions(int count) {
            return String.join(" ", carried.subList(Math.max(0, carried.size() - count), carried.size()).stream()
                    .map(Turn::question).toList()).strip();
        }

        /** Words the model may repeat from memory: carried questions and shareable replies as sent. */
        String memoryEvidence() { return text; }
    }

    /** Builds the bounded history from turns given newest first. */
    static History assemble(List<Turn> newestFirst, int hidden) {
        int count = newestFirst == null ? 0 : newestFirst.size();
        Builder builder = new Builder(Math.max(1, count));
        for (int i = 0; i < hidden; i++) builder.hide();
        if (newestFirst != null) {
            for (Turn turn : newestFirst) {
                if (!builder.offer(turn)) break;
            }
        }
        return builder.build();
    }

    /**
     * Collects turns newest first while they fit: the caller re-authorizes a stored turn only while
     * {@link #open()} says another one can still be carried.
     */
    static final class Builder {
        private final int maxTurns;
        private final List<Turn> kept = new ArrayList<>();
        private final List<String> blocks = new ArrayList<>();
        /** The "(earlier turns omitted)" line is always reserved. */
        private int used = utf8(OMITTED) + 1;
        private boolean truncated;
        private int hidden;

        Builder(int maxTurns) {
            this.maxTurns = Math.max(1, maxTurns);
        }

        /** Another (older) turn can still be carried. */
        boolean open() {
            return !truncated && kept.size() < maxTurns;
        }

        /** A stored turn that failed the reader checks: counted, never carried. */
        void hide() {
            hidden++;
        }

        /** Offers the next older turn; false once it no longer fits (the history is then marked truncated). */
        boolean offer(Turn turn) {
            if (!open()) return false;
            String block = block(turn, kept.isEmpty() ? NEWEST_REPLY_BYTES : OLDER_REPLY_BYTES);
            // Written as "Turn N " + block + line break; N never has more digits than maxTurns.
            int size = utf8(prefix(maxTurns)) + utf8(block) + 1;
            if (used + size > MAX_BYTES) {
                truncated = true;
                return false;
            }
            used += size;
            kept.add(turn);
            blocks.add(block);
            return true;
        }

        History build() {
            if (kept.isEmpty()) return new History(List.of(), "", false, hidden);
            List<Turn> turns = new ArrayList<>(kept);
            List<String> texts = new ArrayList<>(blocks);
            Collections.reverse(turns);
            Collections.reverse(texts);
            StringBuilder text = new StringBuilder();
            if (truncated) text.append(OMITTED).append('\n');
            for (int i = 0; i < texts.size(); i++) {
                text.append(prefix(i + 1)).append(texts.get(i)).append('\n');
            }
            return new History(List.copyOf(turns), text.toString().strip(), truncated, hidden);
        }
    }

    private static String prefix(int number) {
        return "Turn " + number + " ";
    }

    private static String block(Turn turn, int replyBytes) {
        StringBuilder header = new StringBuilder("(");
        header.append(turn.pageTitle().isBlank() && turn.route().isBlank() ? "no page"
                : "page: " + (turn.pageTitle().isBlank() ? "" : clip(turn.pageTitle(), 120) + " ")
                + (turn.route().isBlank() ? "" : turn.route())).append(')');
        if (!turn.toolTitle().isBlank()) header.append(" (tool: ").append(clip(turn.toolTitle(), 80)).append(')');
        String reply;
        if (turn.dataChanged()) {
            reply = DATA_CHANGED;
        } else if (!turn.shareable()) {
            reply = WITHHELD;
        } else {
            reply = clip(turn.reply(), replyBytes);
            if (!turn.cards().isEmpty()) {
                reply += " (确认卡: " + clip(String.join("、", turn.cards()), 200) + ")";
            }
        }
        return header.toString().strip() + "\nQ: " + clip(turn.question(), QUESTION_BYTES) + "\nA: " + reply;
    }

    /** Cuts to at most {@code bytes} UTF-8 bytes on a code point boundary, marking the cut. */
    static String clip(String value, int bytes) {
        String text = value == null ? "" : value.strip();
        if (utf8(text) <= bytes) return text;
        String suffix = "...(已截断)";
        int budget = Math.max(0, bytes - utf8(suffix));
        StringBuilder out = new StringBuilder();
        int size = 0;
        for (int offset = 0; offset < text.length(); ) {
            int codePoint = text.codePointAt(offset);
            String piece = new String(Character.toChars(codePoint));
            int pieceSize = utf8(piece);
            if (size + pieceSize > budget) break;
            out.append(piece);
            size += pieceSize;
            offset += Character.charCount(codePoint);
        }
        return out.toString().strip() + suffix;
    }

    static int utf8(String value) {
        return value == null ? 0 : value.getBytes(StandardCharsets.UTF_8).length;
    }
}
