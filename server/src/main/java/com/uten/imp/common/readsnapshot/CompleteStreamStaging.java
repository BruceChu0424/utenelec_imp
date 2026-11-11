package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.servlet.http.HttpServletResponse;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Bounded frame staging for the complete NDJSON streams (master summaries,
 * instant inventory), 2026-11-10: the data RR transaction must never wait for
 * the consumer. Inside {@code VersionedSummaryPages.readWithProof}'s reader
 * the stream materializes every frame beyond the first here; after the
 * publication fence the caller replays the staged bytes to the response at
 * the client's own speed, so a slow consumer no longer spends the read's
 * 60s transaction budget while holding its RR snapshot and DB connection.
 *
 * <p>Frames stay in memory up to {@code memoryLimit}; larger reads spill to
 * one private temp file (the export spool pattern of XlsxExportService /
 * StreamingPdfDocumentWriter) that {@link #close()} always removes. The
 * staged bytes and the one-frame-one-flush framing are exactly the direct
 * {@code writeFrame} output, so the wire protocol is unchanged for every
 * client. Staging-sink failures are real read failures (error-frame path),
 * never a silent disconnect; response writes during the replay keep the
 * disconnect semantics of the direct writer.
 */
public final class CompleteStreamStaging implements AutoCloseable {
    /** Export spools use the same order of magnitude; beyond it a read spills to disk. */
    private static final int DEFAULT_MEMORY_LIMIT = 8 * 1024 * 1024;
    private static final int FILE_BUFFER = 64 * 1024;

    private final ObjectMapper json;
    private final int memoryLimit;
    private final List<Integer> lengths = new ArrayList<>();
    private ByteArrayOutputStream memory = new ByteArrayOutputStream();
    private Path spill;
    private OutputStream spillOutput;
    private boolean closed;

    CompleteStreamStaging(ObjectMapper json, int memoryLimit) {
        this.json = json;
        this.memoryLimit = memoryLimit;
    }

    public static CompleteStreamStaging open(ObjectMapper json) {
        return new CompleteStreamStaging(json, DEFAULT_MEMORY_LIMIT);
    }

    /** Stages one frame; a staging-sink failure is a real read failure, not a disconnect. */
    public void stage(Object frame) {
        if (closed) throw new IllegalStateException("Complete stream staging is closed");
        byte[] encoded;
        try { encoded = json.writeValueAsBytes(frame); }
        catch (IOException invalid) { throw new IllegalStateException("完整读取帧无法暂存", invalid); }
        if (spillOutput == null) {
            // Frames sit back-to-back; the length list below is the only delimiter.
            memory.write(encoded, 0, encoded.length);
            lengths.add(encoded.length);
            if (memory.size() > memoryLimit) spillToTempFile();
        } else {
            try {
                spillOutput.write(encoded);
            } catch (IOException failure) {
                throw new IllegalStateException("完整读取暂存文件不可用", failure);
            }
            lengths.add(encoded.length);
        }
    }

    private void spillToTempFile() {
        try {
            Path file = Files.createTempFile("uten-complete-stream-", ".frames");
            OutputStream output = new BufferedOutputStream(Files.newOutputStream(file), FILE_BUFFER);
            try {
                output.write(memory.toByteArray());
            } catch (IOException writeFailure) {
                // 首次写入失败时没有任何接管者，必须就地关闭，避免临时文件句柄泄漏。
                try { output.close(); } catch (IOException suppressed) { writeFailure.addSuppressed(suppressed); }
                throw writeFailure;
            }
            memory = null;
            spill = file;
            spillOutput = output;
        } catch (IOException failure) {
            throw new IllegalStateException("完整读取暂存文件不可用", failure);
        }
    }

    /** One frame per flush, exactly like the direct writer; IOException means the consumer disconnected. */
    public void replayTo(HttpServletResponse response) throws IOException {
        if (closed) throw new IllegalStateException("Complete stream staging is closed");
        try (InputStream staged = openStagedBytes()) {
            for (int length : lengths) {
                byte[] frame = staged.readNBytes(length);
                if (frame.length != length) throw new IOException("暂存的完整读取帧不完整");
                var output = response.getOutputStream();
                output.write(frame);
                output.write('\n');
                response.flushBuffer();
            }
        }
    }

    private InputStream openStagedBytes() throws IOException {
        if (spill == null) return new ByteArrayInputStream(memory.toByteArray());
        spillOutput.flush();
        return Files.newInputStream(spill);
    }

    boolean spilled() { return spill != null; }
    Path spillFile() { return spill; }

    @Override public void close() {
        if (closed) return;
        closed = true;
        lengths.clear();
        memory = null;
        IOException failure = null;
        if (spillOutput != null) {
            try { spillOutput.close(); } catch (IOException error) { failure = error; }
            spillOutput = null;
        }
        if (spill != null) {
            try { Files.deleteIfExists(spill); } catch (IOException error) {
                if (failure == null) failure = error; else failure.addSuppressed(error);
            }
            spill = null;
        }
        if (failure != null) throw new UncheckedIOException(failure);
    }
}
