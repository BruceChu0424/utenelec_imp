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
 * domains or one of the reader's chat domains (the same gate as tools and the reviewed catalog).
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

    static final AiDocKnowledge EMPTY = new AiDocKnowledge(List.of());

    /** One immutable index generation. */
    private record State(List<AiDocChunker.Chunk> chunks, Map<String, Integer> byId, AiDocIndex index) {
        static State of(List<AiDocChunker.Chunk> chunks) {
            List<AiDocChunker.Chunk> all = List.copyOf(chunks);
            Map<String, Integer> ids = new HashMap<>();
            for (int i = 0; i < all.size(); i++) ids.putIfAbsent(all.get(i).id(), i);
            return new State(all, Map.copyOf(ids), new AiDocIndex(all.stream().map(AiDocChunker.Chunk::docTitle).toList(),
                    all.stream().map(AiDocChunker.Chunk::headings).toList(), all.stream().map(AiDocChunker.Chunk::text).toList()));
        }
    }

    static final int READY_WAIT_SECONDS = 15;
    private static final State NONE = State.of(List.of());
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
                State built = State.of(loaded.chunks());
                ready.complete(built);
                log.info("AI knowledge index: {} documents, {} chunks, {} terms, {} postings, about {} KB, built in {} ms",
                        loaded.documents(), built.chunks().size(), built.index().termCount(), built.index().postingCount(),
                        built.index().approximateBytes() / 1024, (System.nanoTime() - loaded.started()) / 1_000_000);
            } catch (RuntimeException | Error failure) {
                ready.complete(NONE);
                log.warn("AI knowledge index not built ({})", failure.getClass().getSimpleName());
            }
        }, "ai-knowledge-index");
        builder.setDaemon(true);
        builder.start();
    }

    private AiDocKnowledge(List<AiDocChunker.Chunk> chunks) {
        this.ready = java.util.concurrent.CompletableFuture.completedFuture(State.of(chunks));
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
        List<AiDocChunker.Chunk> all = new ArrayList<>();
        for (var entry : documents.entrySet()) {
            if (!AiDocKnowledgePolicy.included(entry.getKey())) continue;
            all.addAll(AiDocChunker.chunks(entry.getKey(), entry.getValue()));
        }
        return new AiDocKnowledge(all);
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

    private record Loaded(List<AiDocChunker.Chunk> chunks, int documents, long started) {}

    private static Loaded loadClasspath() {
        long started = System.nanoTime();
        List<AiDocChunker.Chunk> all = new ArrayList<>();
        int documents = 0;
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
                    all.addAll(AiDocChunker.chunks(relative, new String(in.readAllBytes(), StandardCharsets.UTF_8)));
                    documents++;
                }
            }
        } catch (IOException | RuntimeException failure) {
            log.warn("AI knowledge index not built ({}); rule questions are answered without design documents",
                    failure.getClass().getSimpleName());
            return new Loaded(List.of(), 0, started);
        }
        if (documents == 0) log.warn("AI knowledge index is empty: no design documents were packaged");
        return new Loaded(all, documents, started);
    }

    /** How many packaged documents and chunks the index holds. */
    public record Summary(int documents, int chunks) {}

    /**
     * Loads the packaged documents synchronously through this class's own class loader, exactly as the background
     * build does at startup (under the executable jar that is the nested-jar loader). Used by
     * {@link AiKnowledgeIndexCheck} to verify a release jar without starting the application.
     */
    public static Summary packagedSummary() {
        Loaded loaded = loadClasspath();
        return new Summary(loaded.documents(), loaded.chunks().size());
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
     * wrongly. A document touching personnel, finance or administration needs one of its domains.
     */
    static boolean visible(AiDocChunker.Chunk chunk, Set<String> domains) {
        if (chunk == null || domains == null) return false;
        if (chunk.domains().stream().noneMatch(RESTRICTED_DOMAINS::contains)) return true;
        return chunk.domains().stream().anyMatch(domains::contains);
    }

    /**
     * The chunks that answer {@code query} for a reader with {@code domains}: at most {@link #MAX_CHUNKS}
     * (at most {@link #MAX_PER_DOCUMENT} from one document), at most {@link #MAX_CHARS} characters, only
     * chunks scoring at least {@link #RELATIVE_FLOOR} of the best and matching two or more of the question's
     * own terms; nothing when the best score is below {@link #MIN_SCORE}.
     */
    List<AiDocChunker.Chunk> search(String query, Set<String> domains) {
        return search(query, "", domains);
    }

    /**
     * Search for a question asked in a conversation: {@code context} (the earlier questions it follows up) keeps
     * the topic at a lower weight ({@link AiDocIndex#CONTEXT_WEIGHT}); thresholds and the matched-term rule count
     * the question's own words only.
     */
    List<AiDocChunker.Chunk> search(String query, String context, Set<String> domains) {
        State current = state();
        List<AiDocChunker.Chunk> chunks = current.chunks();
        Map<String, Double> terms = AiDocIndex.queryTerms(query, context);
        if (terms.isEmpty() || chunks.isEmpty()) return List.of();
        long own = terms.values().stream().filter(weight -> weight >= 1.0).count();
        if (own == 0) return List.of();
        int needed = own >= 3 ? 2 : 1;
        List<AiDocIndex.Hit> hits = current.index().search(terms, chunk -> visible(chunks.get(chunk), domains), 60,
                AiDocIndex.mechanicsAsked(query));
        if (hits.isEmpty() || hits.getFirst().score() < (own <= 1 ? MIN_SCORE_SINGLE_TERM : MIN_SCORE)) return List.of();
        double floor = hits.getFirst().score() * RELATIVE_FLOOR;
        List<AiDocChunker.Chunk> picked = new ArrayList<>();
        Map<String, Integer> perDocument = new HashMap<>();
        int chars = 0;
        for (AiDocIndex.Hit hit : hits) {
            if (hit.score() < floor || picked.size() >= MAX_CHUNKS) break;
            if (hit.matched() < needed) continue;
            AiDocChunker.Chunk chunk = chunks.get(hit.chunk());
            if (perDocument.getOrDefault(chunk.path(), 0) >= MAX_PER_DOCUMENT) continue;
            if (chars + chunk.text().length() > MAX_CHARS) continue;
            picked.add(chunk);
            perDocument.merge(chunk.path(), 1, Integer::sum);
            chars += chunk.text().length();
        }
        return List.copyOf(picked);
    }

    /** Scores of the best hits, for tests and calibration. */
    List<String> explain(String query, Set<String> domains, int limit) {
        State current = state();
        List<AiDocChunker.Chunk> chunks = current.chunks();
        return current.index().search(AiDocIndex.queryTerms(query), chunk -> visible(chunks.get(chunk), domains), limit,
                        AiDocIndex.mechanicsAsked(query)).stream()
                .map(hit -> String.format(java.util.Locale.ROOT, "%.2f m%d %s", hit.score(), hit.matched(),
                        chunks.get(hit.chunk()).label()))
                .toList();
    }
}
