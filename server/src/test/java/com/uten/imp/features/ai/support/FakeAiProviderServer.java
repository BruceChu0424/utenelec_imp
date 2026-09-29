package com.uten.imp.features.ai.support;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * 测试用的假 AI 服务商(OpenAI Chat Completions 与 Anthropic Messages 两种形状), 基于 JDK 自带的
 * {@link HttpServer}, 只监听 127.0.0.1 随机端口。供公共 AI 平台与接入它的业务测试复用(ADR-133)。
 *
 * <p>路由:
 * <ul>
 *   <li>{@code GET .../models}: 返回 {@link #models(List)} 设置的模型列表(或 {@link #modelsStatus(int)} 指定的错误);</li>
 *   <li>{@code POST .../chat/completions} 与 {@code POST .../messages}: 依次返回 {@link #enqueue} 排好的响应,
 *       队列空了用 {@link #defaultResponse(Response)}(默认: 对应协议形状的 {@code {"ok":true}})。</li>
 * </ul>
 * 每个请求都记录下来({@link #requests()}), 便于断言请求头与请求体。
 *
 * <p>用法:
 * <pre>{@code
 * try (FakeAiProviderServer fake = FakeAiProviderServer.start()) {
 *     fake.enqueue(FakeAiProviderServer.openAiContent("{\"lines\":[]}"));
 *     // 服务商配置: 本机部署(LOCAL), 接口地址 fake.openAiBaseUrl()
 * }
 * }</pre>
 */
public final class FakeAiProviderServer implements AutoCloseable {

    /** 一个脚本化的响应; {@code delayMillis} 用于模拟超时。 */
    public record Response(int status, String body, Map<String, String> headers, long delayMillis) {
        public Response withDelay(long millis) {
            return new Response(status, body, headers, millis);
        }
    }

    /** 收到的请求。 */
    public record RecordedRequest(String method, String path, Map<String, String> headers, String body) {
        public String header(String name) {
            return headers.get(name.toLowerCase(Locale.ROOT));
        }
    }

    private final HttpServer server;
    private final ExecutorService executor;
    private final Deque<Response> queue = new ArrayDeque<>();
    private final List<RecordedRequest> requests = new ArrayList<>();
    private Response defaultOpenAi = openAiContent("{\"ok\": true}");
    private Response defaultAnthropic = anthropicContent("{\"ok\": true}");
    private boolean defaultOverridden;
    private Response overriddenDefault;
    private List<String> models = List.of("fake-model");
    private int modelsStatus = 200;

    private FakeAiProviderServer(HttpServer server, ExecutorService executor) {
        this.server = server;
        this.executor = executor;
    }

    /** 在 127.0.0.1 的随机端口上启动。 */
    public static FakeAiProviderServer start() {
        try {
            HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
            ExecutorService executor = Executors.newCachedThreadPool(runnable -> {
                Thread thread = new Thread(runnable, "fake-ai-provider");
                thread.setDaemon(true);
                return thread;
            });
            FakeAiProviderServer fake = new FakeAiProviderServer(server, executor);
            server.createContext("/", fake::handle);
            server.setExecutor(executor);
            server.start();
            return fake;
        } catch (IOException e) {
            throw new IllegalStateException("cannot start fake AI provider", e);
        }
    }

    /** {@code http://127.0.0.1:<port>}(不带路径)。 */
    public String rootUrl() {
        return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    /** OpenAI 兼容形状的接口地址({@code /v1})。 */
    public String openAiBaseUrl() {
        return rootUrl() + "/v1";
    }

    /** Anthropic 形状的接口地址(客户端会再拼 {@code /v1/messages})。 */
    public String anthropicBaseUrl() {
        return rootUrl() + "/anthropic";
    }

    public synchronized FakeAiProviderServer enqueue(Response... responses) {
        for (Response response : responses) {
            queue.addLast(response);
        }
        return this;
    }

    /** 队列空时的响应(两种协议共用); 不设置时按协议返回 {@code {"ok":true}}。 */
    public synchronized FakeAiProviderServer defaultResponse(Response response) {
        this.defaultOverridden = true;
        this.overriddenDefault = response;
        return this;
    }

    public synchronized FakeAiProviderServer models(List<String> models) {
        this.models = List.copyOf(models);
        this.modelsStatus = 200;
        return this;
    }

    /** 模型列表接口返回这个状态(例如 404 表示服务商没有列表接口)。 */
    public synchronized FakeAiProviderServer modelsStatus(int status) {
        this.modelsStatus = status;
        return this;
    }

    public synchronized List<RecordedRequest> requests() {
        return List.copyOf(requests);
    }

    /** 最后一个对话请求(chat/completions 或 messages)。 */
    public synchronized RecordedRequest lastChatRequest() {
        for (int i = requests.size() - 1; i >= 0; i--) {
            RecordedRequest request = requests.get(i);
            if (request.method().equals("POST")) {
                return request;
            }
        }
        throw new IllegalStateException("no chat request recorded");
    }

    public synchronized long chatRequestCount() {
        return requests.stream().filter(request -> request.method().equals("POST")).count();
    }

    /** 清空脚本、记录与默认值。 */
    public synchronized void reset() {
        queue.clear();
        requests.clear();
        defaultOverridden = false;
        overriddenDefault = null;
        models = List.of("fake-model");
        modelsStatus = 200;
    }

    @Override
    public void close() {
        server.stop(0);
        executor.shutdownNow();
        try {
            executor.awaitTermination(5, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // ------------------------------------------------------------------ 响应工厂

    /** OpenAI 形状的成功回复, 内容是 {@code content}。 */
    public static Response openAiContent(String content) {
        return openAiContent(content, 120, 30, "stop");
    }

    public static Response openAiContent(String content, int promptTokens, int completionTokens,
                                         String finishReason) {
        String body = "{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\",\"choices\":[{\"index\":0,"
                + "\"message\":{\"role\":\"assistant\",\"content\":" + (content == null ? "null" : quote(content))
                + "},\"finish_reason\":" + quote(finishReason) + "}],\"usage\":{\"prompt_tokens\":" + promptTokens
                + ",\"completion_tokens\":" + completionTokens + ",\"total_tokens\":"
                + (promptTokens + completionTokens) + "}}";
        return json(200, body);
    }

    /** Anthropic 形状的成功回复。 */
    public static Response anthropicContent(String text) {
        return anthropicContent(text, 100, 20, "end_turn");
    }

    public static Response anthropicContent(String text, int inputTokens, int outputTokens, String stopReason) {
        String body = "{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\","
                + "\"text\":" + quote(text) + "}],\"stop_reason\":" + quote(stopReason) + ",\"usage\":{\"input_tokens\":"
                + inputTokens + ",\"output_tokens\":" + outputTokens + "}}";
        return json(200, body);
    }

    /** OpenAI 形状的错误。 */
    public static Response openAiError(int status, String message) {
        return json(status, "{\"error\":{\"message\":" + quote(message) + ",\"type\":\"invalid_request_error\"}}");
    }

    /** Anthropic 形状的错误。 */
    public static Response anthropicError(int status, String type, String message) {
        return json(status, "{\"type\":\"error\",\"error\":{\"type\":" + quote(type) + ",\"message\":"
                + quote(message) + "}}");
    }

    /** 跳转(客户端不应跟随)。 */
    public static Response redirect(String location) {
        return new Response(302, "", Map.of("Location", location), 0);
    }

    public static Response raw(int status, String body) {
        return new Response(status, body, Map.of("Content-Type", "text/plain"), 0);
    }

    public static Response json(int status, String body) {
        return new Response(status, body, Map.of("Content-Type", "application/json"), 0);
    }

    // ------------------------------------------------------------------ 内部

    private void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        Map<String, String> headers = new LinkedHashMap<>();
        exchange.getRequestHeaders().forEach((name, values) ->
                headers.put(name.toLowerCase(Locale.ROOT), values.isEmpty() ? "" : values.get(0)));
        String body;
        try (InputStream input = exchange.getRequestBody()) {
            body = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        Response response;
        synchronized (this) {
            requests.add(new RecordedRequest(method, path, Map.copyOf(headers), body));
            if (method.equals("GET") && path.endsWith("/models")) {
                response = modelsStatus == 200 ? modelsResponse() : openAiError(modelsStatus, "models unavailable");
            } else if (method.equals("POST") && (path.endsWith("/chat/completions") || path.endsWith("/messages"))) {
                response = queue.pollFirst();
                if (response == null) {
                    response = defaultOverridden ? overriddenDefault
                            : path.endsWith("/messages") ? defaultAnthropic : defaultOpenAi;
                }
            } else {
                response = openAiError(404, "no route " + path);
            }
        }
        if (response.delayMillis() > 0) {
            try {
                Thread.sleep(response.delayMillis());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        byte[] bytes = response.body() == null ? new byte[0] : response.body().getBytes(StandardCharsets.UTF_8);
        response.headers().forEach((name, value) -> exchange.getResponseHeaders().add(name, value));
        try {
            exchange.sendResponseHeaders(response.status(), bytes.length == 0 ? -1 : bytes.length);
            if (bytes.length > 0) {
                try (OutputStream output = exchange.getResponseBody()) {
                    output.write(bytes);
                }
            }
        } catch (IOException ignored) {
            // 客户端已放弃(超时测试)。
        } finally {
            exchange.close();
        }
    }

    private Response modelsResponse() {
        StringBuilder data = new StringBuilder();
        for (String model : models) {
            if (!data.isEmpty()) {
                data.append(',');
            }
            data.append("{\"id\":").append(quote(model)).append(",\"object\":\"model\",\"type\":\"model\"}");
        }
        return json(200, "{\"object\":\"list\",\"data\":[" + data + "]}");
    }

    /** JSON 字符串字面量。 */
    public static String quote(String value) {
        StringBuilder text = new StringBuilder(value.length() + 2).append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> text.append("\\\"");
                case '\\' -> text.append("\\\\");
                case '\n' -> text.append("\\n");
                case '\r' -> text.append("\\r");
                case '\t' -> text.append("\\t");
                default -> {
                    if (c < 0x20) {
                        text.append(String.format("\\u%04x", (int) c));
                    } else {
                        text.append(c);
                    }
                }
            }
        }
        return text.append('"').toString();
    }
}
