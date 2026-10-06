package com.uten.imp.features.ai.chat;

import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Stream;

/**
 * ADR-153 platform knowledge from the project's own design documents. At startup the whitelisted
 * documents packaged under {@code classpath:ai-knowledge/} ({@link AiDocKnowledgePolicy}) are split into
 * chunks and indexed in memory ({@link AiDocIndex}); a search takes a few milliseconds and never touches
 * the disk or the database. A chunk is visible to a reader when its document names none of the business
 * domains or one of the reader's chat domains (the same gate as tools and the reviewed catalog), and, for a section about
 * personnel or finance inside an everyone-readable document, the reader holds that domain too (ADR-159). A question whose
 * best match is hidden from the reader and clearly outranks what the reader sees is recognized as one about another
 * department's rules ({@link #restrictedTopic}).
 *
 * <p>The packaged index is built on a background thread so startup is not delayed; a question that arrives while
 * it is still being built waits for it (at most {@link #READY_WAIT_SECONDS} seconds, then answers without
 * documents). The build time and size are logged.
 */
@Component
public class AiDocKnowledge {
    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(AiDocKnowledge.class);
    static final int MAX_CHUNKS = 6;
    static final int MAX_PER_DOCUMENT = 3;
    static final int MAX_CHARS = 6000;
    /** A weaker chunk is kept only while it scores at least this share of the best one. */
    static final double RELATIVE_FLOOR = 0.35;
    /** Below this best score nothing in the documents is about the question. */
    static final double MIN_SCORE = 10.0;
    /** A one-word question ("黄框") needs a clearly stronger match before a document is used. */
    static final double MIN_SCORE_SINGLE_TERM = 15.0;
    /**
     * A question of one or two words below the thresholds is still answered by chunks that hold all of its words and
     * name one in their title or headings, when the match is at least this strong (a common word such as 待办 is not
     * specific enough).
     */
    static final double MIN_SCORE_HEADING = 7.0;
    /** At most this many glossary definitions go with one answer; the rest of the budget is for the rules. */
    static final int MAX_DEFINITIONS = 2;

    static final AiDocKnowledge EMPTY = new AiDocKnowledge(new Loaded(List.of(), 0, 0, List.of(), List.of()));

    /**
     * One immutable index generation: the chunks, and the index that reads questions with the built-in words plus the
     * glossary's terms and everyday words and the documents' aliases.
     */
    private record State(List<AiDocChunker.Chunk> chunks, Map<String, Integer> byId, Map<String, Integer> definitions,
                         AiDocIndex index) {
        static State of(Loaded loaded) {
            List<AiDocChunker.Chunk> all = List.copyOf(loaded.chunks());
            Map<String, Integer> ids = new HashMap<>();
            Map<String, Integer> defined = new HashMap<>();
            for (int i = 0; i < all.size(); i++) {
                ids.putIfAbsent(all.get(i).id(), i);
                if (all.get(i).kind() == AiDocChunker.Kind.DEFINITION) defined.putIfAbsent(AiDocIndex.normalize(all.get(i).section()), i);
            }
            double[] priors = all.stream().mapToDouble(AiDocChunker.Chunk::prior).toArray();
            AiDocIndex.Vocabulary vocabulary = AiDocIndex.Vocabulary.of(AiDocIndex.SYNONYMS, AiDocIndex.COLLOQUIAL,
                    loaded.glossary(), Stream.concat(AiDocIndex.CORE_WORDS.stream(), loaded.aliases().stream()).toList());
            return new State(all, Map.copyOf(ids), Map.copyOf(defined), new AiDocIndex(all.stream().map(AiDocChunker.Chunk::documentName).toList(),
                    all.stream().map(AiDocChunker.Chunk::headings).toList(), all.stream().map(AiDocChunker.Chunk::text).toList(),
                    priors, vocabulary));
        }
    }

    static final int READY_WAIT_SECONDS = 15;
    private static final State NONE = State.of(new Loaded(List.of(), 0, 0, List.of(), List.of()));
    private final java.util.concurrent.CompletableFuture<State> ready;

    /**
     * Loads and indexes the packaged documents on a background thread; a failure leaves an empty index (the
     * assistant still works, without documents).
     */
    public AiDocKnowledge() {
        this.ready = new java.util.concurrent.CompletableFuture<>();
        Thread builder = new Thread(() -> {
            try {
                Loaded loaded = loadClasspath();
                State built = State.of(loaded);
                ready.complete(built);
                log.info("AI knowledge index: {} documents, {} chunks, {} glossary terms, {} terms, {} postings, about {} KB,"
                                + " built in {} ms", loaded.documents(), built.chunks().size(), loaded.glossary().size(),
                        built.index().termCount(), built.index().postingCount(), built.index().approximateBytes() / 1024,
                        (System.nanoTime() - loaded.started()) / 1_000_000);
            } catch (RuntimeException | Error failure) {
                ready.complete(NONE);
                log.warn("AI knowledge index not built ({})", failure.getClass().getSimpleName());
            }
        }, "ai-knowledge-index");
        builder.setDaemon(true);
        builder.start();
    }

    private AiDocKnowledge(Loaded loaded) {
        this.ready = java.util.concurrent.CompletableFuture.completedFuture(State.of(loaded));
    }

    /** The built index; while the startup build runs, waits for it a bounded time (then answers without documents). */
    private State state() {
        try {
            return ready.get(READY_WAIT_SECONDS, java.util.concurrent.TimeUnit.SECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return NONE;
        } catch (java.util.concurrent.ExecutionException | java.util.concurrent.TimeoutException notReady) {
            return NONE;
        }
    }

    /** Index over given documents (relative path to Markdown), applying the same policy as the packaged ones. */
    static AiDocKnowledge of(Map<String, String> documents) {
        Loading loading = new Loading();
        for (var entry : documents.entrySet()) {
            if (AiDocKnowledgePolicy.included(entry.getKey())) loading.add(entry.getKey(), entry.getValue());
        }
        return new AiDocKnowledge(loading.done(0));
    }

    /** Index over a checked-out docs/ directory (tests use the real documents). */
    static AiDocKnowledge fromDirectory(Path docsRoot) {
        Map<String, String> documents = new LinkedHashMap<>();
        try (Stream<Path> files = Files.walk(docsRoot)) {
            for (Path file : files.filter(Files::isRegularFile).sorted().toList()) {
                String relative = docsRoot.relativize(file).toString().replace('\\', '/');
                if (AiDocKnowledgePolicy.included(relative)) documents.put(relative, Files.readString(file, StandardCharsets.UTF_8));
            }
        } catch (IOException unreadable) {
            throw new UncheckedIOException(unreadable);
        }
        return of(documents);
    }

    /**
     * The loaded documents: their chunks, the glossary rows (P1-2, none when the glossary is missing) and the
     * aliases the documents declare.
     */
    private record Loaded(List<AiDocChunker.Chunk> chunks, int documents, long started, List<AiDocGlossary.Entry> glossary,
                          List<String> aliases) {}

    /** Collects documents one by one; the glossary is read from its own path only. */
    private static final class Loading {
        private final List<AiDocChunker.Chunk> chunks = new ArrayList<>();
        private final List<AiDocGlossary.Entry> glossary = new ArrayList<>();
        private final Set<String> aliases = new java.util.LinkedHashSet<>();
        private int documents;

        void add(String relativePath, String markdown) {
            chunks.addAll(AiDocChunker.chunks(relativePath, markdown));
            aliases.addAll(AiDocChunker.aliases(markdown));
            if (AiDocGlossary.PATH.equals(relativePath)) glossary.addAll(AiDocGlossary.parse(markdown));
            documents++;
        }

        Loaded done(long started) {
            return new Loaded(List.copyOf(chunks), documents, started, List.copyOf(glossary), List.copyOf(aliases));
        }
    }

    private static Loaded loadClasspath() {
        long started = System.nanoTime();
        Loading loading = new Loading();
        try {
            var resolver = new PathMatchingResourcePatternResolver(AiDocKnowledge.class.getClassLoader());
            String marker = "/" + AiDocKnowledgePolicy.RESOURCE_ROOT + "/";
            for (Resource resource : resolver.getResources("classpath*:" + AiDocKnowledgePolicy.RESOURCE_ROOT + "/**/*.md")) {
                String location = URLDecoder.decode(resource.getURL().toString(), StandardCharsets.UTF_8);
                int at = location.lastIndexOf(marker);
                if (at < 0) continue;
                String relative = location.substring(at + marker.length());
                if (!AiDocKnowledgePolicy.included(relative)) continue;
                try (InputStream in = resource.getInputStream()) {
                    loading.add(relative, new String(in.readAllBytes(), StandardCharsets.UTF_8));
                }
            }
        } catch (IOException | RuntimeException failure) {
            log.warn("AI knowledge index not built ({}); rule questions are answered without design documents",
                    failure.getClass().getSimpleName());
            return new Loaded(List.of(), 0, started, List.of(), List.of());
        }
        Loaded loaded = loading.done(started);
        if (loaded.documents() == 0) log.warn("AI knowledge index is empty: no design documents were packaged");
        return loaded;
    }

    /** How many packaged documents and chunks the index holds, and how many glossary terms it reads questions with. */
    public record Summary(int documents, int chunks, int glossaryTerms) {}

    /**
     * Loads the packaged documents synchronously through this class's own class loader, exactly as the background
     * build does at startup (under the executable jar that is the nested-jar loader). Used by
     * {@link AiKnowledgeIndexCheck} to verify a release jar without starting the application.
     */
    public static Summary packagedSummary() {
        Loaded loaded = loadClasspath();
        return new Summary(loaded.documents(), loaded.chunks().size(), loaded.glossary().size());
    }

    int size() { return state().chunks().size(); }

    /** Every indexed chunk (tests check that none of them carries internal names). */
    List<AiDocChunker.Chunk> chunks() { return state().chunks(); }

    Optional<AiDocChunker.Chunk> chunk(String id) {
        State current = state();
        Integer at = id == null ? null : current.byId().get(id);
        return at == null ? Optional.empty() : Optional.of(current.chunks().get(at));
    }

    /**
     * Domains whose design documents stay inside the department: personnel and payroll, finance and cost,
     * and system administration.
     */
    static final Set<String> RESTRICTED_DOMAINS = Set.of("HR", "FINANCE", "ADMIN");

    /**
     * The reader may see this chunk. Business process rules (sales, purchase, warehouse, production, quality,
     * subcontract, R&amp;D) and platform-wide conventions are explained to everyone who may use the assistant:
     * they hold no business data, and a cross-department question answered from half the rules is answered
     * wrongly. A document touching personnel, finance or administration needs one of its domains. ADR-159: a section
     * of an everyone-readable document that is about personnel or finance (its heading or a list item's bold lead says
     * so) needs that domain as well; the section gate only ever narrows the document's.
     */
    static boolean visible(AiDocChunker.Chunk chunk, Set<String> domains) {
        if (chunk == null || domains == null) return false;
        if (!chunk.sectionDomains().isEmpty() && chunk.sectionDomains().stream().noneMatch(domains::contains)) return false;
        if (chunk.domains().stream().noneMatch(RESTRICTED_DOMAINS::contains)) return true;
        return chunk.domains().stream().anyMatch(domains::contains);
    }

    /**
     * The chunks that answer {@code query} for a reader with {@code domains}: at most {@link #MAX_CHUNKS}
     * (at most {@link #MAX_PER_DOCUMENT} from one document), at most {@link #MAX_CHARS} characters, only
     * chunks scoring at least {@link #RELATIVE_FLOOR} of the best and matching two or more of the question's
     * own terms; nothing when the best score is below {@link #MIN_SCORE} or the best chunk is not about the question
     * (see {@link #search(String, String, Set)}).
     */
    List<AiDocChunker.Chunk> search(String query, Set<String> domains) {
        return search(query, "", domains);
    }

    /**
     * Search for a question asked in a conversation: {@code context} (the earlier questions it follows up) keeps
     * the topic at a lower weight ({@link AiDocIndex#CONTEXT_WEIGHT}); thresholds and the matched-term rule count
     * the question's own words only, and only words some document uses.
     *
     * <p>Two rules decide whether the documents answer the question at all. The best chunk must hold at least half of
     * the question's own words or name one of them in its title or headings; otherwise it only shares stray words
     * with the question and nothing is sent (the answer then says so instead of building on unrelated rules). A
     * question of one or two words that misses the score threshold is still answered by the chunks that hold all of its
     * words and name one of them in their title or headings (「让料是什么意思」 finds the decision titled 让料), or name both
     * words of a two-word question in their headings whatever the score (「通知能删除吗」 finds that FAQ). The glossary definitions of the
     * terms the question names (by the term or an everyday word for it) among the ranked chunks always go along, and a
     * question of one or two words gets the definition of each term it names literally even when it ranks low
     * (「预留是什么」); at most {@link #MAX_DEFINITIONS}.
     */
    List<AiDocChunker.Chunk> search(String query, String context, Set<String> domains) {
        State current = state();
        List<AiDocChunker.Chunk> chunks = current.chunks();
        Map<String, Double> terms = current.index().query(query, context);
        if (terms.isEmpty() || chunks.isEmpty()) return List.of();
        long own = terms.entrySet().stream()
                .filter(term -> term.getValue() >= 1.0 && current.index().known(term.getKey())).count();
        if (own == 0) return List.of();
        int needed = own >= 3 ? 2 : 1;
        List<AiDocIndex.Hit> hits = current.index().search(terms, chunk -> visible(chunks.get(chunk), domains), 60,
                AiDocIndex.mechanicsAsked(query));
        if (hits.isEmpty()) return List.of();
        AiDocIndex.Hit best = hits.getFirst();
        List<AiDocIndex.Hit> pool;
        if (best.score() >= (own <= 1 ? MIN_SCORE_SINGLE_TERM : MIN_SCORE) && about(best, own)) {
            pool = hits;
        } else if (own <= 2) {
            // Headings that name both words of a two-word question ("通知能删除吗" under the FAQ 「通知能删除吗…」) are
            // about it even when common words keep the score low; one word alone still needs the heading score.
            pool = hits.stream().filter(hit -> hit.inHeading() >= 1 && hit.matched() >= own
                    && (hit.score() >= MIN_SCORE_HEADING || (own >= 2 && hit.inHeading() >= own))).toList();
        } else {
            pool = List.of();
        }
        List<AiDocChunker.Chunk> picked = new ArrayList<>();
        Map<String, Integer> perDocument = new HashMap<>();
        int chars = 0;
        int definitions = 0;
        // The glossary definitions of the terms the question names go first, whatever their score.
        Set<String> named = current.index().vocabulary().named(query);
        for (AiDocIndex.Hit hit : hits) {
            AiDocChunker.Chunk chunk = chunks.get(hit.chunk());
            if (definitions >= MAX_DEFINITIONS) break;
            boolean definesNamedTerm = chunk.kind() == AiDocChunker.Kind.DEFINITION
                    && named.contains(AiDocIndex.normalize(chunk.section()));
            if (!definesNamedTerm) continue;
            picked.add(chunk);
            definitions++;
            chars += chunk.text().length();
        }
        // A short question about a term ("预留是什么") gets the term's own definition even when the many rules that use
        // the word outrank the short glossary row.
        if (own <= 2) {
            String asked = AiDocIndex.normalize(query);
            List<String> literal = named.stream().filter(asked::contains)
                    .sorted(java.util.Comparator.comparingInt((String term) -> asked.indexOf(term))
                            .thenComparing(java.util.Comparator.comparingInt(String::length).reversed())).toList();
            for (String term : literal) {
                if (definitions >= MAX_DEFINITIONS) break;
                Integer at = current.definitions().get(term);
                if (at == null || picked.contains(chunks.get(at)) || !visible(chunks.get(at), domains)) continue;
                picked.add(chunks.get(at));
                definitions++;
                chars += chunks.get(at).text().length();
            }
        }
        if (pool.isEmpty()) return List.copyOf(picked);
        // A short glossary definition scores far above the rules it summarizes; the floor is set by the best rule.
        double floor = pool.stream().filter(hit -> chunks.get(hit.chunk()).kind() != AiDocChunker.Kind.DEFINITION).findFirst()
                .orElse(pool.getFirst()).score() * RELATIVE_FLOOR;
        for (AiDocIndex.Hit hit : pool) {
            if (picked.size() >= MAX_CHUNKS) break;
            if (hit.score() < floor || !enough(hit, needed)) continue;
            AiDocChunker.Chunk chunk = chunks.get(hit.chunk());
            boolean definition = chunk.kind() == AiDocChunker.Kind.DEFINITION;
            if (picked.contains(chunk) || (definition && definitions >= MAX_DEFINITIONS)) continue;
            if (!definition && perDocument.getOrDefault(chunk.path(), 0) >= MAX_PER_DOCUMENT) continue;
            if (chars + chunk.text().length() > MAX_CHARS) continue;
            picked.add(chunk);
            if (definition) definitions++;
            else perDocument.merge(chunk.path(), 1, Integer::sum);
            chars += chunk.text().length();
        }
        return List.copyOf(picked);
    }

    /**
     * The chunk holds enough of the question: the needed number of its own words, or, for a follow-up, one of them and
     * two words of the earlier question it continues ("审核之前又出库了会怎样" after a stocktake question finds the
     * stocktake rule that says so).
     */
    private static boolean enough(AiDocIndex.Hit hit, int needed) {
        return hit.matched() >= needed || (hit.matched() >= 1 && hit.inContext() >= 2);
    }

    /** The chunk is about the question: it holds half of the question's own words or names one in its headings. */
    private static boolean about(AiDocIndex.Hit hit, long own) {
        return hit.matched() * 2L >= own || hit.inHeading() >= 1;
    }

    /**
     * ADR-159 (live N3): how far the best match over every document must outscore the best match this reader may see
     * before the question counts as one about a subject outside the reader's domains. Calibrated on the golden set (no
     * doc-answerable question of a single-department reader reaches it, see {@code AiKnowledgeGoldenQuestionsEvalTest})
     * and on the live questions (货品成本是怎么算出来的 and 工资条怎么生成 as a sales reader are far above it).
     */
    static final double RESTRICTED_MARGIN = 1.5;
    /**
     * ADR-159 (live N2) the other way a hidden match clearly outranks the visible one: it scores higher and holds at least
     * this many more of the question's own words (工资条怎么生成 生成完要谁审核: the payroll pages hold 工资条, 生成 and
     * 审核, the best match a sales reader sees only 审核).
     */
    static final int RESTRICTED_WORD_MARGIN = 2;

    /**
     * The best match of a question over every document and the best one a reader may see.
     *
     * @param best           score of the best match over every document (0 when nothing matches)
     * @param visible        score of the best match this reader may see (0 when none)
     * @param bestWords      how many of the question's own words the best match holds
     * @param visibleWords   how many of them the best match this reader may see holds
     * @param answers        the best match over every document passes the answer threshold and is about the question
     * @param hiddenBy       the domains any one of which would let this reader see the best match (empty when the reader
     *                       sees it; see {@link #hiddenBy(AiDocChunker.Chunk, Set)})
     */
    record TopicCheck(double best, double visible, int bestWords, int visibleWords, boolean answers, Set<String> hiddenBy) {
        /**
         * The question is about a subject the reader may not read: its best match is hidden and answers the question, and
         * it clearly outranks what the reader sees: nothing visible would be used, or the hidden match scores at least
         * {@link #RESTRICTED_MARGIN} times the best visible one, or it scores higher and holds at least
         * {@link #RESTRICTED_WORD_MARGIN} more of the question's own words.
         */
        boolean restricted(boolean visibleAnswers) {
            if (!answers || hiddenBy.isEmpty()) return false;
            return !visibleAnswers || best >= RESTRICTED_MARGIN * visible
                    || (best > visible && bestWords >= visibleWords + RESTRICTED_WORD_MARGIN);
        }
    }

    /**
     * ADR-159 (live N3) the domains a question is about when the reader may not read their rules: the best match over every
     * document is hidden from this reader (a personnel, finance or administration document or section) and clearly
     * outranks everything the reader may see ({@link TopicCheck#restricted}). Then tangential visible passages must not be
     * sent: the answer names only the departments (the domains any one of which would open that match). Empty otherwise
     * (the question is answered from what the reader sees, as before). Only the question's own words count (a follow-up's
     * earlier question does not).
     */
    Optional<Set<String>> restrictedTopic(String query, Set<String> domains) {
        TopicCheck check = topicCheck(query, domains);
        if (!check.answers() || check.hiddenBy().isEmpty()) return Optional.empty();
        // Whether anything the reader sees would be used at all (the same thresholds as answering).
        boolean visibleAnswers = !search(query, "", domains).isEmpty();
        return check.restricted(visibleAnswers) ? Optional.of(check.hiddenBy()) : Optional.empty();
    }

    /** The best match over every document and over what the reader sees (for the restricted-topic answer and calibration). */
    TopicCheck topicCheck(String query, Set<String> domains) {
        State current = state();
        List<AiDocChunker.Chunk> chunks = current.chunks();
        Map<String, Double> terms = current.index().query(query, "");
        long own = ownTerms(current, terms);
        if (own == 0 || chunks.isEmpty() || domains == null) return new TopicCheck(0, 0, 0, 0, false, Set.of());
        List<AiDocIndex.Hit> all = current.index().search(terms, chunk -> true, 200, AiDocIndex.mechanicsAsked(query));
        if (all.isEmpty()) return new TopicCheck(0, 0, 0, 0, false, Set.of());
        AiDocIndex.Hit best = all.getFirst();
        Optional<AiDocIndex.Hit> seen = all.stream().filter(hit -> visible(chunks.get(hit.chunk()), domains)).findFirst();
        return new TopicCheck(best.score(), seen.map(AiDocIndex.Hit::score).orElse(0.0), best.matched(),
                seen.map(AiDocIndex.Hit::matched).orElse(0), passes(best, own), hiddenBy(chunks.get(best.chunk()), domains));
    }

    private static long ownTerms(State current, Map<String, Double> terms) {
        return terms.entrySet().stream().filter(term -> term.getValue() >= 1.0 && current.index().known(term.getKey())).count();
    }

    /** The hit would be used by {@link #search}: above the score threshold and about the question. */
    private static boolean passes(AiDocIndex.Hit hit, long own) {
        return hit.score() >= (own <= 1 ? MIN_SCORE_SINGLE_TERM : MIN_SCORE) && about(hit, own);
    }

    /**
     * The domains any one of which would let the reader see this chunk (its section's personnel or finance domain, else
     * every domain of its document: a sales and finance decision opens to either); empty when the reader sees it.
     */
    static Set<String> hiddenBy(AiDocChunker.Chunk chunk, Set<String> domains) {
        if (chunk == null || domains == null || visible(chunk, domains)) return Set.of();
        if (!chunk.sectionDomains().isEmpty() && chunk.sectionDomains().stream().noneMatch(domains::contains)) {
            return Set.copyOf(chunk.sectionDomains());
        }
        return Set.copyOf(chunk.domains());
    }

    /**
     * The raw ranking a reader with {@code domains} gets for a question (no threshold, floor or cap), read with this
     * index's words; for the retrieval evaluation and calibration.
     */
    List<AiDocIndex.Hit> ranking(String query, Set<String> domains, int limit) {
        State current = state();
        List<AiDocChunker.Chunk> chunks = current.chunks();
        return current.index().search(current.index().query(query, ""), chunk -> visible(chunks.get(chunk), domains), limit,
                AiDocIndex.mechanicsAsked(query));
    }

    /** The question's own content terms read with this index's words (glossary terms and aliases included). */
    List<String> keyTerms(String question) {
        return state().index().vocabulary().keyTerms(question);
    }

    /** Scores of the best hits, for tests and calibration. */
    List<String> explain(String query, Set<String> domains, int limit) {
        List<AiDocChunker.Chunk> chunks = chunks();
        return ranking(query, domains, limit).stream()
                .map(hit -> String.format(java.util.Locale.ROOT, "%.2f m%d h%d %s", hit.score(), hit.matched(), hit.inHeading(),
                        chunks.get(hit.chunk()).label()))
                .toList();
    }
}
