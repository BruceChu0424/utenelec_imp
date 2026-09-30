package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.common.files.document.DocumentGrid;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
import java.util.regex.Pattern;

/**
 * 读取 {@code sales-intake/matching-fixture.json}(货品匹配回归夹具): 我司货品资料快照(约 1600 个货品: 两份文件的候选、
 * 客户历史, 以及与正确答案同型号/同名称/同名称族的全部在用货品)、匿名化客户与其历史购买、两份按客户文件形状合成的表格
 * (联系方式与银行信息都是假的)以及每行的正确答案。
 */
final class IntakeFixture {

    private static final Pattern PLAIN_NUMBER = Pattern.compile("-?\\d+(\\.\\d+)?");
    private static IntakeFixture cached;

    final LocalDate asOf;
    final List<GoodsRow> goods = new ArrayList<>();
    final Map<UUID, GoodsRow> goodsById = new LinkedHashMap<>();
    final Map<String, GoodsRow> goodsByCode = new LinkedHashMap<>();
    final Set<UUID> invisibleGoods = new LinkedHashSet<>();
    final Map<String, FixtureClient> clients = new LinkedHashMap<>();
    final Map<String, List<HistoryItem>> history = new LinkedHashMap<>();
    final Map<String, FixtureDocument> documents = new LinkedHashMap<>();

    record FixtureClient(String key, UUID id, String code, String name, String fullName, String nameEn, String placeId) {
    }

    record HistoryItem(UUID goodsId, int orderCount, LocalDate lastOrderDate) {
    }

    record TruthLine(int row, BigDecimal qty, Set<UUID> truth) {
    }

    record Sim2Line(int row, String status, String topCode, Double topScore, List<String> top8) {
    }

    record FixtureDocument(String key, String clientKey, String sheetName, List<String> merges,
                           Map<Integer, Map<String, String>> rows, List<TruthLine> lines, List<Sim2Line> sim2) {
    }

    static synchronized IntakeFixture load() {
        if (cached == null) {
            try (InputStream in = IntakeFixture.class.getResourceAsStream("/sales-intake/matching-fixture.json")) {
                cached = new IntakeFixture(new ObjectMapper().readTree(in));
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }
        return cached;
    }

    private IntakeFixture(JsonNode root) {
        asOf = LocalDate.parse(root.get("asOf").asText());
        for (JsonNode g : root.get("goods")) {
            GoodsRow row = new GoodsRow(UUID.fromString(g.get("id").asText()), text(g, "code"), text(g, "name"),
                    text(g, "model"), text(g, "series"), text(g, "spec"), uuid(g, "colorId"), text(g, "colorName"),
                    uuid(g, "unitId"), text(g, "unitName"), text(g, "nameEn"), text(g, "nameEnSource"),
                    g.get("price").isNull() ? null : g.get("price").decimalValue(), text(g, "status"));
            goods.add(row);
            goodsById.put(row.id(), row);
            if (row.code() != null) {
                goodsByCode.put(row.code(), row);
            }
            if (!"使用".equals(row.status()) || g.get("autoCreated").asBoolean() || g.get("deleted").asBoolean()) {
                invisibleGoods.add(row.id());
            }
        }
        for (JsonNode c : root.get("clients")) {
            FixtureClient client = new FixtureClient(c.get("key").asText(), UUID.fromString(c.get("id").asText()),
                    text(c, "code"), text(c, "name"), text(c, "fullName"), text(c, "nameEn"), text(c, "placeId"));
            clients.put(client.key(), client);
        }
        for (Map.Entry<String, JsonNode> e : root.get("history").properties()) {
            List<HistoryItem> items = new ArrayList<>();
            for (JsonNode h : e.getValue()) {
                items.add(new HistoryItem(UUID.fromString(h.get("goodsId").asText()), h.get("orderCount").asInt(),
                        LocalDate.parse(h.get("lastOrderDate").asText())));
            }
            history.put(e.getKey(), items);
        }
        for (JsonNode d : root.get("documents")) {
            Map<Integer, Map<String, String>> rows = new LinkedHashMap<>();
            for (JsonNode r : d.get("rows")) {
                Map<String, String> cells = new LinkedHashMap<>();
                r.get("cells").properties().forEach(e -> cells.put(e.getKey(), e.getValue().asText()));
                rows.put(r.get("row").asInt(), cells);
            }
            List<TruthLine> lines = new ArrayList<>();
            for (JsonNode l : d.get("lines")) {
                Set<UUID> truth = new LinkedHashSet<>();
                l.get("truth").forEach(t -> truth.add(UUID.fromString(t.asText())));
                lines.add(new TruthLine(l.get("row").asInt(), l.get("qty").decimalValue(), truth));
            }
            List<Sim2Line> sim2 = new ArrayList<>();
            for (JsonNode s : d.get("sim2")) {
                List<String> top8 = new ArrayList<>();
                s.get("top8").forEach(t -> top8.add(t.asText()));
                sim2.add(new Sim2Line(s.get("row").asInt(), s.get("status").asText(), text(s, "topCode"),
                        s.get("topScore").isNull() ? null : s.get("topScore").asDouble(), top8));
            }
            List<String> merges = new ArrayList<>();
            d.get("merges").forEach(m -> merges.add(m.asText()));
            documents.put(d.get("key").asText(), new FixtureDocument(d.get("key").asText(), d.get("clientKey").asText(),
                    d.get("sheetName").asText(), merges, rows, lines, sim2));
        }
    }

    FixtureClient client(String key) {
        return clients.get(key);
    }

    FixtureDocument document(String key) {
        return documents.get(key);
    }

    /** 合成表格写成 xlsx(纯数字的单元格写成数字格, 其余写文字格; 保留合并区域)。 */
    static byte[] toXlsx(FixtureDocument doc, Predicate<String> keepColumn) {
        try (XSSFWorkbook wb = new XSSFWorkbook(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            Sheet sheet = wb.createSheet(doc.sheetName());
            for (Map.Entry<Integer, Map<String, String>> r : doc.rows().entrySet()) {
                Row row = sheet.createRow(r.getKey() - 1);
                for (Map.Entry<String, String> c : r.getValue().entrySet()) {
                    if (!keepColumn.test(c.getKey())) {
                        continue;
                    }
                    Cell cell = row.createCell(DocumentGrid.columnIndex(c.getKey()));
                    String v = c.getValue();
                    if (PLAIN_NUMBER.matcher(v).matches()) {
                        cell.setCellValue(Double.parseDouble(v));
                    } else {
                        cell.setCellValue(v);
                    }
                }
            }
            for (String m : doc.merges()) {
                sheet.addMergedRegion(CellRangeAddress.valueOf(m));
            }
            wb.write(out);
            return out.toByteArray();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    static byte[] toXlsx(FixtureDocument doc) {
        return toXlsx(doc, c -> true);
    }

    private static String text(JsonNode node, String field) {
        JsonNode v = node.get(field);
        return v == null || v.isNull() ? null : v.asText();
    }

    private static UUID uuid(JsonNode node, String field) {
        String t = text(node, field);
        return t == null ? null : UUID.fromString(t);
    }
}
