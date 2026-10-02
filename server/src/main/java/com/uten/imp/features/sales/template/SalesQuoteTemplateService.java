package com.uten.imp.features.sales.template;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientProfile;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.quote.SalesQuoteService;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayOutputStream;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

@Service
public class SalesQuoteTemplateService {
    private static final int MAX_TEMPLATES_PER_EXPORT = 100;
    private static final long MAX_EXPORT_BYTES = 100L * 1024 * 1024;
    private final SalesQuoteService quotes;
    private final SalesQuoteTemplateStore templates;
    private final MasterIntakeLookupPort master;
    private final NamedParameterJdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final WorkbookDownloadService download;
    private final AuditService audit;
    private com.uten.imp.common.platformcolumns.PlatformColumnService platformColumns;
    @org.springframework.beans.factory.annotation.Autowired
    void setPlatformColumns(com.uten.imp.common.platformcolumns.PlatformColumnService service) { this.platformColumns = service; }
    public SalesQuoteTemplateService(SalesQuoteService quotes, SalesQuoteTemplateStore templates, MasterIntakeLookupPort master,
                                    NamedParameterJdbcTemplate jdbc, SecurityContextCurrentUser currentUser,
                                    WorkbookDownloadService download, AuditService audit) {
        this.quotes=quotes; this.templates=templates; this.master=master; this.jdbc=jdbc;
        this.currentUser=currentUser; this.download=download; this.audit=audit;
    }
    public record ExportRequest(List<UUID> templateIds, boolean all, String password, com.uten.imp.common.export.TableColumnProjection columnProjection) {
        public ExportRequest(List<UUID> templateIds, boolean all, String password) { this(templateIds, all, password, null); }
    }
    public record Download(byte[] bytes, String fileName, String contentType, int templateCount, int rowCount) { }

    @Transactional(readOnly=true)
    public List<SalesQuoteTemplateStore.TemplateView> list(UUID quoteId) {
        QuoteDetail quote=readable(quoteId);
        return templates.list(quote.getClientId());
    }
    @Transactional(readOnly=true, isolation=Isolation.REPEATABLE_READ)
    public Download export(UUID quoteId, ExportRequest request) {
        AuthUser actor=currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (actor.isVisitor() || actor.getPermissions()==null || !actor.getPermissions().containsAll(
                Set.of("sales_quote:view","sales_quote:export","sales_order:price:view"))) throw new ApiException(ErrorCode.FORBIDDEN);
        QuoteDetail quote=readable(quoteId);
        if (quote.isPriceMasked()) throw new ApiException(ErrorCode.FORBIDDEN,"你没有报价价格查看权限");
        if (quote.getItems()==null || quote.getItems().size()>500) throw new ApiException(ErrorCode.VALIDATION_FAILED,"报价最多导出 500 行");
        ExportRequest req=request==null ? new ExportRequest(List.of(),false,null) : request;
        if (req.password()!=null && req.password().length()>128) throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出密码最多 128 位");
        List<SalesQuoteTemplateStore.TemplateView> available=templates.list(quote.getClientId());
        List<UUID> ids=req.all() ? available.stream().map(SalesQuoteTemplateStore.TemplateView::id).toList()
                : req.templateIds()==null ? List.of() : req.templateIds().stream().filter(Objects::nonNull).distinct().toList();
        if (ids.size()>MAX_TEMPLATES_PER_EXPORT) throw new ApiException(ErrorCode.VALIDATION_FAILED,"一次最多导出 100 个模板，请分批选择");
        ClientProfile client=quote.getClientId()==null ? null : master.clientProfile(quote.getClientId());
        Map<String,String> header=new HashMap<>();
        if (client!=null) {
            header.put("buyerName", first(client.nameEn(),client.fullName(),client.name())); header.put("buyerAddress",client.address());
            header.put("contactName",client.linkman()); header.put("email",client.email()); header.put("phone",first(client.phone(),client.mobile()));
        }
        Map<String, Object> currencyParameter = new HashMap<>(); currencyParameter.put("currency", quote.getCurrencyId());
        List<String> currencyCodes = jdbc.query("""
                SELECT code FROM currencies WHERE id=CAST(:currency AS uuid)
                    OR (CAST(:currency AS uuid) IS NULL AND is_base_currency=true AND NOT is_deleted)
                ORDER BY code LIMIT 1
                """, currencyParameter, (rs, row) -> rs.getString(1));
        if (currencyCodes.isEmpty() || currencyCodes.getFirst() == null || currencyCodes.getFirst().isBlank())
            throw new ApiException(ErrorCode.CONFLICT,"请先设置报价币种或本位币后再导出");
        header.put("currencyCode", currencyCodes.getFirst().strip().toUpperCase(Locale.ROOT));
        header.put("docNo",quote.getBillNo()); header.put("docDate",quote.getBillDate()==null ? "" : quote.getBillDate().toString());
        List<QuoteTemplateWorkbook.ExportLine> lines=exportLines(quote);
        List<QuoteTemplateWorkbook.DisplayColumn> projection = projection(quote, req.columnProjection(), lines);
        LinkedHashMap<String,byte[]> files=new LinkedHashMap<>();
        String bill=quote.getBillNo()==null ? "报价单" : quote.getBillNo().replaceAll("[\\\\/\\p{Cntrl}:*?\"<>|]","_");
        if (ids.isEmpty()) {
            QuoteTemplateWorkbook.Candidate base=QuoteTemplateWorkbook.defaultTemplate();
            if (projection != null) base = QuoteTemplateWorkbook.project(base.xlsx(), base.mapping(), projection);
            addFile(files, bill+".xlsx", download.protect(QuoteTemplateWorkbook.render(base.xlsx(),base.mapping(),lines,header,quote.getTotalOriginalExact()),req.password()));
        } else for (UUID id : ids) {
            if (quote.getClientId()==null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先选择客户");
            SalesQuoteTemplateStore.Stored template=templates.load(quote.getClientId(),id);
            if (projection != null) {
                var projected = QuoteTemplateWorkbook.project(template.bytes(), template.mapping(), projection);
                template = new SalesQuoteTemplateStore.Stored(projected.xlsx(), projected.mapping(), template.features(), template.fingerprint(), template.sourceName());
            }
            String name=available.stream().filter(t -> t.id().equals(id)).map(SalesQuoteTemplateStore.TemplateView::name)
                    .findFirst().orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
            addFile(files, bill+"_"+name.replaceAll("[\\\\/\\p{Cntrl}:*?\"<>|]","_")+"_"+id.toString().substring(0,8)+".xlsx",
                    download.protect(QuoteTemplateWorkbook.render(template.bytes(),template.mapping(),lines,header,quote.getTotalOriginalExact()),req.password()));
        }
        byte[] bytes; String name; String contentType;
        if (files.size()==1) {
            var entry=files.entrySet().iterator().next(); bytes=entry.getValue(); name=entry.getKey();
            contentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        } else {
            try (ByteArrayOutputStream out=new ByteArrayOutputStream(); ZipOutputStream zip=new ZipOutputStream(out)) {
                for (var entry:files.entrySet()) { zip.putNextEntry(new ZipEntry(entry.getKey())); zip.write(entry.getValue()); zip.closeEntry(); }
                zip.finish(); bytes=out.toByteArray();
                if (bytes.length > MAX_EXPORT_BYTES) throw new ApiException(ErrorCode.VALIDATION_FAILED,"报价文件合计超过 100 MiB，请分批选择模板");
            } catch (ApiException e) { throw e; }
            catch (Exception e) { throw new IllegalStateException("报价文件打包失败",e); }
            name=bill+"_报价模板.zip"; contentType="application/zip";
        }
        audit.logExplicit(actor.getId(),actor.getLoginAccount(),"export_sales_quote","sales_quotes",quoteId.toString(),
                "导出报价 "+files.size()+" 份，明细 "+lines.size()+" 行"+(req.password()==null || req.password().isEmpty() ? "" : "，已加密"));
        return new Download(bytes,name,contentType,files.size(),lines.size());
    }
    private static void addFile(Map<String, byte[]> files, String name, byte[] bytes) {
        long total = bytes.length;
        for (byte[] stored : files.values()) total += stored.length;
        if (total > MAX_EXPORT_BYTES) throw new ApiException(ErrorCode.VALIDATION_FAILED,
                "报价文件合计超过 100 MiB，请分批选择模板");
        files.put(name, bytes);
    }
    private QuoteDetail readable(UUID id) {
        QuoteDetail quote=quotes.detail(id); // Authoritative quote permission, masking and owner scope.
        if (quote.getClientId()!=null && master.clientProfile(quote.getClientId())==null)
            throw new ApiException(ErrorCode.FORBIDDEN,"客户不在你的查看范围内");
        return quote;
    }
    private List<QuoteTemplateWorkbook.ExportLine> exportLines(QuoteDetail quote) {
        Map<UUID,GoodsRow> goods=new HashMap<>();
        for (GoodsRow g:master.goodsByIds(quote.getItems().stream().map(QuoteItemDto::getGoodsId).filter(Objects::nonNull).distinct().toList())) goods.put(g.id(),g);
        Map<UUID,Map<String,String>> display=new HashMap<>();
        jdbc.query("""
                SELECT i.id,c.name AS color_name,u.name AS unit_name
                FROM sales_quote_items i LEFT JOIN colors c ON c.id=i.color_id LEFT JOIN units u ON u.id=i.unit_id
                WHERE i.quote_id=:id AND NOT i.is_deleted ORDER BY i.line_no,i.id
                """, Map.of("id",quote.getId()), rs -> {
            Map<String,String> map=new HashMap<>(); map.put("COLOR",rs.getString("color_name")); map.put("UNIT",rs.getString("unit_name"));
            display.put(rs.getObject("id",UUID.class),map);
        });
        List<QuoteTemplateWorkbook.ExportLine> out=new ArrayList<>();
        for (QuoteItemDto item:quote.getItems()) {
            Map<String,String> values=new LinkedHashMap<>(display.getOrDefault(item.getId(),Map.of())); GoodsRow g=goods.get(item.getGoodsId());
            if (item.getExtraColumns() != null) for (var column : item.getExtraColumns()) {
                if (column.name() == null) continue;
                values.put("EXTRA_ID:" + column.columnId(), column.value());
            }
            values.put("GOODS_NAME", first(item.getGoodsNameSnapshot(), g == null ? null : g.name()));
            values.put("GOODS_NAME_EN", item.getGoodsNameEn());
            values.put("GOODS_CODE", first(item.getGoodsCodeSnapshot(), g == null ? null : g.code()));
            values.put("CLIENT_MODEL", item.getClientModel()); values.put("CLIENT_DESCRIPTION", item.getClientGoodsName());
            values.put("CLIENT_PRICE", item.getClientPriceExact());
            values.put("PART_NO",first(item.getClientModel(),item.getGoodsCodeSnapshot(),g==null ? null : g.code()));
            values.put("DESCRIPTION",first(item.getClientGoodsName(),item.getGoodsNameEn(),item.getGoodsNameSnapshot()));
            values.put("DESCRIPTION_ALT",first(item.getGoodsNameSnapshot(),g==null ? null : g.name()));
            values.put("SERIES",g==null ? null : g.series()); values.put("QTY",item.getQtyExact()); values.put("UNIT_PRICE",item.getPriceExact());
            values.put("UNIT_PRICE_NET", item.getPrice() == null ? null : com.uten.imp.common.util.DecimalText.of(
                    item.getPrice().multiply(item.getDiscount() == null ? java.math.BigDecimal.ONE : item.getDiscount())));
            values.put("DISCOUNT",item.getDiscountExact()); values.put("AMOUNT",item.getAmountOriginalExact()); values.put("REMARK",item.getRemark());
            out.add(new QuoteTemplateWorkbook.ExportLine(values, item.getExtraColumns()));
        }
        return out;
    }
    private record BaseColumn(String role, String sourceRole) { }
    private static final Map<String, BaseColumn> BASE_COLUMNS = Map.ofEntries(
            Map.entry("goods", new BaseColumn("GOODS_NAME", "DESCRIPTION_ALT")),
            Map.entry("goodsName", new BaseColumn("GOODS_NAME", "DESCRIPTION_ALT")),
            Map.entry("nameEn", new BaseColumn("GOODS_NAME_EN", "DESCRIPTION")),
            Map.entry("goodsNameEn", new BaseColumn("GOODS_NAME_EN", "DESCRIPTION")),
            Map.entry("goodsCode", new BaseColumn("GOODS_CODE", "PART_NO")),
            Map.entry("color", new BaseColumn("COLOR", "COLOR")), Map.entry("colorName", new BaseColumn("COLOR", "COLOR")),
            Map.entry("qty", new BaseColumn("QTY", "QTY")), Map.entry("unit", new BaseColumn("UNIT", "UNIT")),
            Map.entry("unitName", new BaseColumn("UNIT", "UNIT")), Map.entry("price", new BaseColumn("UNIT_PRICE", "UNIT_PRICE")),
            Map.entry("discount", new BaseColumn("DISCOUNT", "DISCOUNT")), Map.entry("amount", new BaseColumn("AMOUNT", "AMOUNT")),
            Map.entry("remark", new BaseColumn("REMARK", "REMARK")),
            Map.entry("clientModel", new BaseColumn("CLIENT_MODEL", "PART_NO")),
            Map.entry("clientGoodsName", new BaseColumn("CLIENT_DESCRIPTION", "DESCRIPTION")),
            Map.entry("clientPrice", new BaseColumn("CLIENT_PRICE", "UNIT_PRICE")));

    private List<QuoteTemplateWorkbook.DisplayColumn> projection(QuoteDetail quote, com.uten.imp.common.export.TableColumnProjection requested,
            List<QuoteTemplateWorkbook.ExportLine> lines) {
        if (requested == null) return null;
        String suppliedScope = requested.scope();
        if (suppliedScope != null && !Set.of("sales_quote", "view_sales").contains(suppliedScope.toString()))
            throw invalidProjection("导出表头不属于销售报价明细");
        var columns = requested.columns();
        if (columns == null || columns.isEmpty() || columns.size() > 100)
            throw invalidProjection("导出表头需要 1 至 100 列");
        Map<UUID, com.uten.imp.common.columns.ExtraColumnSnapshot> extras = new HashMap<>();
        for (var item : quote.getItems()) if (item.getExtraColumns() != null)
            for (var column : item.getExtraColumns()) extras.putIfAbsent(column.columnId(), column);
        Set<String> seen = new HashSet<>(); Set<UUID> requestedPlatform = new LinkedHashSet<>();
        List<QuoteTemplateWorkbook.DisplayColumn> out = new ArrayList<>();
        for (var column : columns) {
            if (column == null || column.key() == null || column.key().isBlank() || !seen.add(column.key()))
                throw invalidProjection("导出表头编号为空或重复");
            String key = column.key();
            String label = column.label() == null ? key : column.label().strip();
            if (label.isEmpty() || label.length() > 100 || label.chars().anyMatch(Character::isISOControl))
                throw invalidProjection("导出表头名称无效");
            double width = column.width() == null ? 120 : column.width();
            if (!Double.isFinite(width) || width < 1 || width > 2000) throw invalidProjection("导出列宽无效");
            BaseColumn base = BASE_COLUMNS.get(key);
            if (base != null) {
                out.add(new QuoteTemplateWorkbook.DisplayColumn(key, label, width, base.role(), base.sourceRole(), null)); continue;
            }
            if (key.startsWith("extra:")) {
                UUID id = projectionId(key.substring(6));
                var saved = extras.get(id);
                if (saved == null) {
                    List<com.uten.imp.common.columns.ExtraColumnSnapshot> matches = jdbc.query("""
                            SELECT id,name,value_type,operation FROM business_column_definitions WHERE id=:id AND scope='sales_quote'
                            """, Map.of("id",id), (rs, row) -> new com.uten.imp.common.columns.ExtraColumnSnapshot(
                                    rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3),rs.getString(4),null));
                    if (matches.isEmpty()) throw invalidProjection("报价扩展列不存在或不属于此单据");
                    saved = matches.getFirst();
                }
                String sourceRole = Set.of("ADD", "SUBTRACT").contains(saved.operation()) ? "AMOUNT" : null;
                out.add(new QuoteTemplateWorkbook.DisplayColumn(key,label,width,"EXTRA_ID:"+id,sourceRole,saved.name())); continue;
            }
            if (key.startsWith("platform:")) {
                UUID id = projectionId(key.substring(9)); requestedPlatform.add(id);
                out.add(new QuoteTemplateWorkbook.DisplayColumn(key,label,width,"PLATFORM_ID:"+id,null,null)); continue;
            }
            throw invalidProjection("当前报价没有可导出的字段：" + key);
        }
        if (!requestedPlatform.isEmpty()) {
            if (platformColumns == null) throw invalidProjection("扩展字段服务暂不可用");
            Set<String> permittedFacts = platformColumns.scopes().stream().filter(scope -> "view_sales".equals(scope.scope()))
                    .findFirst().orElseThrow(() -> invalidProjection("当前账号不能使用报价计算展示列")).facts().stream()
                    .map(com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition::key)
                    .collect(java.util.stream.Collectors.toSet());
            List<Map<String, java.math.BigDecimal>> rows = new ArrayList<>();
            for (int i = 0; i < quote.getItems().size(); i++) {
                QuoteItemDto item = quote.getItems().get(i);
                Map<String, java.math.BigDecimal> facts = new HashMap<>();
                facts.put("qty", item.getQty()); facts.put("price", item.getPrice()); facts.put("discount", item.getDiscount());
                facts.put("amount", item.getAmountOriginal()); facts.put("amountOriginal", item.getAmountOriginal());
                facts.put("amountLocal", item.getAmountLocal()); facts.put("weight", item.getWeight());
                facts.put("unitRate", item.getUnitRate()); facts.put("clientPrice", item.getClientPrice());
                facts.entrySet().removeIf(entry -> entry.getValue() == null || !permittedFacts.contains(entry.getKey()));
                rows.add(facts);
            }
            List<Map<UUID, String>> evaluated = platformColumns.evaluateDisplayRows("view_sales", new ArrayList<>(requestedPlatform), rows);
            if (evaluated.size() != lines.size()) throw invalidProjection("报价计算展示行数不一致");
            for (int i = 0; i < lines.size(); i++) {
                Map<UUID, String> calculated = evaluated.get(i);
                for (UUID id : requestedPlatform) {
                    if (!calculated.containsKey(id)) throw invalidProjection("报价计算展示字段未完整返回");
                    lines.get(i).values().put("PLATFORM_ID:" + id, calculated.get(id));
                }
            }
        }
        return out;
    }
    private static UUID projectionId(String value) {
        try { return UUID.fromString(value); }
        catch (IllegalArgumentException invalid) { throw invalidProjection("扩展列编号无效"); }
    }
    private static ApiException invalidProjection(String text) { return new ApiException(ErrorCode.VALIDATION_FAILED, text); }
    private static String first(String... values) { for (String value:values) if (value!=null && !value.isBlank()) return value; return ""; }
}
