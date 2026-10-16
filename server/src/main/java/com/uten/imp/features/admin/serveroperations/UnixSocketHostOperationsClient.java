package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Bounded local transport. No subprocess, sudo, URL, network host, or raw-error logging. */
@Component
public class UnixSocketHostOperationsClient implements HostOperationsClient {
    static final int MAX_FRAME_BYTES = 64 * 1024;
    private final ObjectMapper mapper;
    private final Path socket;
    private final Duration timeout;
    private final boolean supported;

    @Autowired
    public UnixSocketHostOperationsClient(ObjectMapper mapper,
            @Value("${uten.server-operations.socket-path:/run/uten-imp-operations/control.sock}") String socket,
            @Value("${uten.server-operations.timeout-ms:5000}") long timeoutMillis) {
        this(mapper, Path.of(socket), Duration.ofMillis(Math.max(250, Math.min(timeoutMillis, 15_000))),
                System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("linux"));
    }

    UnixSocketHostOperationsClient(ObjectMapper mapper, Path socket, Duration timeout, boolean supported) {
        this.mapper = mapper;
        this.socket = socket;
        this.timeout = timeout;
        this.supported = supported;
    }

    @Override
    public JsonNode call(Operation operation, Map<String, Object> payload, UUID actorId, UUID requestId) {
        if (!supported) throw new HostOperationsException("UNAVAILABLE");
        boolean sent = false;
        try {
            verifySocket();
            byte[] request = requestFrame(mapper, operation, payload, actorId, requestId);
            long deadline = System.nanoTime() + deadlineFor(operation).toNanos();
            try (SocketChannel channel = SocketChannel.open(StandardProtocolFamily.UNIX);
                    Selector selector = Selector.open()) {
                channel.configureBlocking(false);
                SelectionKey key = channel.register(selector, SelectionKey.OP_CONNECT);
                channel.connect(UnixDomainSocketAddress.of(socket));
                while (!channel.finishConnect()) await(selector, key, SelectionKey.OP_CONNECT, deadline);
                ByteBuffer output = ByteBuffer.wrap(request);
                while (output.hasRemaining()) {
                    if (channel.write(output) == 0) await(selector, key, SelectionKey.OP_WRITE, deadline);
                    else sent = true;
                }
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                ByteBuffer input = ByteBuffer.allocate(2048);
                while (true) {
                    int count = channel.read(input);
                    if (count < 0) throw new HostOperationsException("INVALID_RESPONSE", operation.outcomeMayChangeState());
                    if (count == 0) {
                        await(selector, key, SelectionKey.OP_READ, deadline);
                        continue;
                    }
                    input.flip();
                    while (input.hasRemaining()) {
                        byte value = input.get();
                        if (value == '\n') {
                            if (input.hasRemaining()) throw new HostOperationsException("INVALID_RESPONSE", operation.outcomeMayChangeState());
                            return responseData(mapper, bytes.toByteArray(), operation);
                        }
                        bytes.write(value);
                        if (bytes.size() >= MAX_FRAME_BYTES) {
                            throw new HostOperationsException("INVALID_RESPONSE", operation.outcomeMayChangeState());
                        }
                    }
                    input.clear();
                }
            }
        } catch (HostOperationsException failure) {
            throw failure;
        } catch (IOException | RuntimeException failure) {
            // Never preserve exception causes: parser/IO messages may contain credentials or a raw RPC frame.
            throw new HostOperationsException("UNAVAILABLE", sent && operation.outcomeMayChangeState());
        }
    }

    Duration deadlineFor(Operation operation) {
        return operation.name().startsWith("STORAGE_") && timeout.compareTo(Duration.ofSeconds(15)) < 0
                ? Duration.ofSeconds(15) : timeout;
    }

    private void verifySocket() throws IOException {
        if (!socket.isAbsolute() || Files.isSymbolicLink(socket)) throw new HostOperationsException("UNAVAILABLE");
        int mode = (int) Files.getAttribute(socket, "unix:mode", LinkOption.NOFOLLOW_LINKS);
        int owner = (int) Files.getAttribute(socket, "unix:uid", LinkOption.NOFOLLOW_LINKS);
        if (owner != 0 || (mode & 0170000) != 0140000 || (mode & 0007) != 0) {
            throw new HostOperationsException("UNAVAILABLE");
        }
        for (Path parent = socket.getParent(); parent != null; parent = parent.getParent()) {
            if (Files.isSymbolicLink(parent)
                    || (int) Files.getAttribute(parent, "unix:uid", LinkOption.NOFOLLOW_LINKS) != 0
                    || ((int) Files.getAttribute(parent, "unix:mode", LinkOption.NOFOLLOW_LINKS) & 0022) != 0) {
                throw new HostOperationsException("UNAVAILABLE");
            }
        }
    }

    private static void await(Selector selector, SelectionKey key, int operation, long deadline) throws IOException {
        long remaining = deadline - System.nanoTime();
        if (remaining <= 0) throw new IOException();
        key.interestOps(operation);
        selector.select(Math.max(1, remaining / 1_000_000));
        selector.selectedKeys().clear();
    }

    static byte[] requestFrame(ObjectMapper mapper, Operation operation, Map<String, Object> payload,
            UUID actorId, UUID requestId) {
        if (operation == null || payload == null || actorId == null || requestId == null) {
            throw new HostOperationsException("INVALID_REQUEST");
        }
        try {
            Map<String, Object> document = new LinkedHashMap<>();
            document.put("operation", operation.name());
            document.put("actorId", actorId.toString());
            document.put("requestId", requestId.toString());
            document.put("payload", payload);
            byte[] body = mapper.writeValueAsBytes(document);
            if (body.length + 1 > MAX_FRAME_BYTES) throw new HostOperationsException("INVALID_REQUEST");
            byte[] frame = java.util.Arrays.copyOf(body, body.length + 1);
            frame[body.length] = '\n';
            return frame;
        } catch (IOException | IllegalArgumentException invalid) {
            throw new HostOperationsException("INVALID_REQUEST");
        }
    }

    static JsonNode responseData(ObjectMapper mapper, byte[] frame, Operation operation) {
        try {
            if (frame.length == 0 || frame.length >= MAX_FRAME_BYTES) throw new IOException();
            String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(frame)).toString();
            JsonNode envelope = mapper.reader().with(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(text);
            if (envelope == null || !envelope.isObject() || !envelope.path("ok").isBoolean()) throw new IOException();
            if (!envelope.path("ok").booleanValue()) {
                String code = envelope.path("code").isTextual() ? envelope.path("code").textValue() : null;
                throw new HostOperationsException(code);
            }
            JsonNode data = envelope.get("data");
            if (data == null || (!data.isObject() && !(data.isNull() && operation == Operation.UPDATE_JOB))) {
                throw new IOException();
            }
            return data;
        } catch (HostOperationsException failure) {
            throw failure;
        } catch (IOException | RuntimeException invalid) {
            throw new HostOperationsException("INVALID_RESPONSE", operation.outcomeMayChangeState());
        }
    }
}
