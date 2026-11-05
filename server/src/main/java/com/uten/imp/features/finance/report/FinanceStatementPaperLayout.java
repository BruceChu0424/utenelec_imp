package com.uten.imp.features.finance.report;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.export.ExportTableLayout;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** One canonical paper geometry for XLSX, Flutter and PDF. Reads source values;
 * it never sums rows, converts currencies, rounds, or derives a payable balance. */
public final class FinanceStatementPaperLayout {
 private FinanceStatementPaperLayout(){}
 private static final Set<String> KEYS=Set.of("subcontractStatement","supplierStatement","otherReceivableStatement","clientStatement");
 public record PaperLayout(int version,String templateKey,String title,int mainColumnCount,int canvasColumns,List<Double> widths,List<Integer> hiddenColumns,String fontName,int fontSize,float rowHeight,int headerStartRow,int headerRow,List<ExportTableLayout.Heading> headings,List<ExportTableLayout.Merge> merges,Map<Integer,Float> headingRowHeights,ExportTableLayout.FooterBlock footer,boolean landscape,Map<String,Object> sourcePrint,String geometrySha256){}
 /** New financial forms use the existing XLSX geometry and this same paper
  * codec. This does not reinterpret the four frozen statement versions. */
 public static Map<String,Object> financialMetadata(String key,ExportTableLayout layout,List<ReportColumn> columns,List<Map<String,Object>> rows){
  if(!Set.of("balanceSheet","monthlyProfit","annualProfit").contains(key)||layout==null||layout.widths().size()!=columns.size())throw new IllegalArgumentException("Financial paper layout is incomplete");
  var headings=new ArrayList<>(layout.headings());var heights=new LinkedHashMap<Integer,Float>();
  for(var heading:layout.headings())heights.merge(heading.row(),Math.max(layout.rowHeight(),heading.fontSize()+8),Math::max);
  heights.putAll(layout.headingRowHeights());
  for(int column=0;column<columns.size();column++){
   final int at=column;if(headings.stream().noneMatch(h->h.row()==layout.headerRow()&&h.column()==at))
    headings.add(new ExportTableLayout.Heading(layout.headerRow(),column,columns.get(column).label(),layout.fontSize(),false,"CENTER"));
  }
  var footer=new ArrayList<ExportTableLayout.FooterCell>();int minimum=0;
  if(layout.footer()!=null){minimum=layout.footer().minimumDataRows();footer.addAll(layout.footer().cells());}
  int offset=footer.stream().mapToInt(cell->cell.rowOffset()+cell.rowSpan()).max().orElse(0);
  for(String note:layout.footnotes())footer.add(new ExportTableLayout.FooterCell(offset++,0,columns.size()-1,1,"text",note,layout.fontSize(),false,"LEFT",false,"财务原表脚注"));
  var paper=new PaperLayout(1,key,layout.sheetName(),columns.size(),layout.widths().size(),layout.widths(),layout.hiddenColumns(),layout.fontName(),layout.fontSize(),layout.rowHeight(),layout.headerStartRow(),layout.headerRow(),List.copyOf(headings),layout.merges(),Map.copyOf(heights),new ExportTableLayout.FooterBlock(minimum,footer),layout.landscape(),Map.of(),null);
  var metadata=new LinkedHashMap<>(json(paper));
  metadata.put("protectCompleteValues",true);
  metadata.put("columnAlignments",columns.stream().map(column->ExportTableLayout.columnAlignment(column.type())).toList());
  metadata.put("bodyBands",layout.bands().stream().map(band->{var value=new LinkedHashMap<String,Object>();value.put("row",band.row());value.put("firstColumn",band.firstColumn());value.put("lastColumn",band.lastColumn());value.put("fill",band.fill());value.put("bold",band.bold());return value;}).toList());
  metadata.put("textSpans",layout.spans().stream().map(span->Map.of("row",span.row(),"column",span.column(),"start",span.start(),"end",span.end(),"color",span.color())).toList());
  var keep=new ArrayList<Integer>();if(key.equals("balanceSheet"))for(int row=0;row+1<rows.size();row++){
   var values=rows.get(row);for(String side:List.of("asset","liability"))if(values.get(side+"Item") instanceof String label&&!label.isBlank()&&values.get(side+"LineNo")==null){keep.add(row);break;}
  }
  metadata.put("keepWithNextRows",List.copyOf(keep));
  return Map.of("paperLayout",metadata);
 }
 private static final class Legacy {
  private static final JsonNode PRINTS=load();
  private static JsonNode load(){try(var stream=FinanceStatementPaperLayout.class.getResourceAsStream("/finance/statement-paper-v1.json")){if(stream==null)throw new IllegalStateException("Legacy source paper geometry unavailable");return new com.fasterxml.jackson.databind.ObjectMapper().readTree(stream);}catch(java.io.IOException failure){throw new IllegalStateException("Legacy source paper geometry unreadable",failure);}}
 }
 /** The returned wrapper can be putAll'ed into documentMetadata without a
  * Jackson round trip: nested content is already maps/lists and exact strings. */
 public static Map<String,Object> metadata(String templateKey,Map<String,Object> documentMetadata){
  var layout=layout(templateKey,documentMetadata);if(layout==null)return Map.of();var fresh=json(layout);var frozen=map(documentMetadata==null?null:documentMetadata.get("paperLayout"));
  if(!frozen.isEmpty()){
   // Keep the exact frozen geometry representation, including decimal text.
   // Only already-authoritative footer facts (e.g. actual confirmations or an
   // explicitly new settlement version) are rebound by their original anchor.
   var preserved=new LinkedHashMap<String,Object>(fresh);preserved.putAll(frozen);var oldFooter=map(frozen.get("footer"));
   if(oldFooter.get("cells") instanceof List<?> oldCells){var currentFooter=map(fresh.get("footer"));var current=new HashMap<String,Map<String,Object>>();for(Object raw:(List<?>)currentFooter.get("cells")){var cell=map(raw);current.put(anchor(cell),cell);}var cells=new ArrayList<Map<String,Object>>();for(Object raw:oldCells){var original=new LinkedHashMap<>(map(raw));var updated=current.get(anchor(original));if(updated==null)throw new IllegalArgumentException("Frozen footer source anchor changed");for(String field:List.of("value","pending","basis")){original.put(field,updated.get(field));}cells.add(original);}var footer=new LinkedHashMap<>(oldFooter);footer.put("cells",cells);preserved.put("footer",footer);}
   fresh=preserved;
  }
  return Map.of("paperLayout",fresh);
 }
 private static String anchor(Map<String,Object> cell){return geometryInteger(cell.get("rowOffset"),-1,0,64)+":"+geometryInteger(cell.get("column"),-1,0,159);}
 public static PaperLayout layout(String templateKey,Map<String,Object> documentMetadata){
  if(!KEYS.contains(templateKey))return null;var metadata=documentMetadata==null?Map.<String,Object>of():documentMetadata;
  var liveContract=FinanceTemplateContract.template(templateKey);var frozen=map(metadata.get("paperLayout"));
  if(frozen.isEmpty()&&metadata.containsKey("reviewId"))throw new IllegalArgumentException("旧原件缺少纸面版本依据，不能按当前版静默重绘");
  int requested=frozen.isEmpty()?2:geometryInteger(frozen.get("version"),-1,1,2);
  if(!frozen.isEmpty()&&!templateKey.equals(frozen.get("templateKey")))throw new IllegalArgumentException("Frozen source paper template changed");
  var contract=requested==1?Legacy.PRINTS.path("templates").path(templateKey):liveContract;var print=contract.path("print");var paper=print.path("paper");
  if(!paper.isObject()||paper.path("version").asInt()!=requested)throw new IllegalStateException("原对账单纸面坐标合同尚未同步");
  String geometrySha=requested==2?paper.path("geometrySha256").asText():null;
  if(requested==2&&!frozen.isEmpty()&&!Objects.equals(geometrySha,frozen.get("geometrySha256")))throw new IllegalArgumentException("Frozen source paper geometry version changed");
  if(requested==2&&!frozen.isEmpty()&&!Objects.equals(paper.path("sourcePrint").path("sourceSha256").asText(),map(frozen.get("sourcePrint")).get("sourceSha256")))throw new IllegalArgumentException("Frozen source paper identity changed");
  if(requested==2&&!frozen.isEmpty()&&!Objects.equals(geometrySha,map(frozen.get("sourcePrint")).get("geometrySha256")))throw new IllegalArgumentException("Frozen source print fingerprint changed");
  if(requested==2&&!frozen.isEmpty()){
   var expectedMetadata=new LinkedHashMap<String,Object>(metadata);expectedMetadata.remove("paperLayout");expectedMetadata.remove("reviewId");for(String field:List.of("canvasColumns","hiddenColumns")){if(!expectedMetadata.containsKey(field)&&frozen.containsKey(field))expectedMetadata.put(field,frozen.get(field));}if(!expectedMetadata.containsKey("supplementalWidths"))expectedMetadata.put("supplementalWidths",frozen.get("widths"));
   requireSameGeometry(geometryProjection(json(layout(templateKey,expectedMetadata))),geometryProjection(frozen));
  }
  int count=contract.path("headers").size(),canvas=geometryInteger(frozen.getOrDefault("canvasColumns",metadata.get("canvasColumns")),count,1,160);
  if(canvas<count||canvas>160)throw new IllegalArgumentException("Invalid source paper canvas");
  var widths=new ArrayList<Double>();for(int at=0;at<count;at++)widths.add(print.path("widths").path(at).asDouble(16));
  List<?> extra=metadata.get("supplementalWidths") instanceof List<?> values?values:List.of();for(int at=count;at<canvas;at++){Object requestedWidth=extra.size()==canvas?extra.get(at):extra.size()==canvas-count?extra.get(at-count):null;if(requestedWidth==null&&requested==2){var known=paper.path("sourcePrint").path("columnWidthCharacters").path(at);if(!known.isNumber())throw new IllegalArgumentException("Source supplemental width proof unavailable");requestedWidth=known.decimalValue();}widths.add(geometryNumber(requestedWidth,16d));}
  if(!frozen.isEmpty()&&frozen.get("widths") instanceof List<?> original){if(original.size()!=canvas)throw new IllegalArgumentException("Frozen paper canvas changed");widths.clear();for(Object width:original)widths.add(geometryNumber(width,16d));}
  var hidden=new ArrayList<Integer>();if(frozen.getOrDefault("hiddenColumns",metadata.get("hiddenColumns")) instanceof List<?> values)for(Object value:values)hidden.add(geometryInteger(value,-1,0,canvas-1));
  if(templateKey.equals("otherReceivableStatement")&&canvas>=17&&hidden.isEmpty())hidden.addAll(List.of(11,12,13,14,15,16));
  var headings=new ArrayList<ExportTableLayout.Heading>();var merges=new ArrayList<ExportTableLayout.Merge>();var heights=new LinkedHashMap<Integer,Float>();
  paper.path("headingRowHeights").properties().forEach(entry->heights.put(headingRowNumber(entry.getKey()),(float)entry.getValue().asDouble()));
  for(var cell:paper.path("headings")){var address=address(cell.path("sourceCell").asText());var value=value(metadata,cell.path("field").asText(null));String text=caption(cell,value);
   headings.add(new ExportTableLayout.Heading(address[0],address[1],text,(float)cell.path("fontSize").asDouble(print.path("fontSize").asInt(10)),cell.path("bold").asBoolean(),cell.path("alignment").asText("LEFT")));merge(merges,cell.path("merge").asText(null));}
  int depth=0;for(var parts:contract.path("headerParts")){depth=Math.max(depth,parts.size()-1);}var groups=new HashSet<String>();
  for(int col=0;col<count;col++){var parts=contract.path("headerParts").path(col);int levels=Math.max(0,parts.size()-1);
   for(int level=0;level<levels;level++){String anchor=parts.path(level).path("cell").asText();if(!groups.add(level+":"+anchor))continue;int end=col;while(end+1<count){var next=contract.path("headerParts").path(end+1);if(next.size()<=level+1||!next.path(level).path("cell").asText().equals(anchor))break;end++;}int row=paper.path("headerStartRow").asInt()+level;headings.add(new ExportTableLayout.Heading(row,col,parts.path(level).path("label").asText(),print.path("fontSize").asInt(10),true,"CENTER"));if(end>col)merges.add(new ExportTableLayout.Merge(row,row,col,end));}
   int row=paper.path("headerStartRow").asInt()+levels,lastRow=paper.path("headerRow").asInt();headings.add(new ExportTableLayout.Heading(row,col,FinanceTemplateContract.header(templateKey,col),print.path("fontSize").asInt(10),true,"CENTER"));if(levels<depth)merges.add(new ExportTableLayout.Merge(row,lastRow,col,col));
  }
  if(frozen.get("headings") instanceof List<?> originalHeadings){headings.clear();for(Object raw:originalHeadings){var cell=map(raw);headings.add(new ExportTableLayout.Heading(geometryInteger(cell.get("row"),-1,0,12),geometryInteger(cell.get("column"),-1,0,canvas-1),Objects.toString(cell.get("text"),""),(float)geometryNumber(cell.get("fontSize"),print.path("fontSize").asDouble()),Boolean.TRUE.equals(cell.get("bold")),Objects.toString(cell.get("alignment"),"LEFT")));}}
  if(frozen.get("merges") instanceof List<?> originalMerges){merges.clear();for(Object raw:originalMerges){var cell=map(raw);merges.add(new ExportTableLayout.Merge(geometryInteger(cell.get("firstRow"),-1,0,12),geometryInteger(cell.get("lastRow"),-1,0,12),geometryInteger(cell.get("firstColumn"),-1,0,canvas-1),geometryInteger(cell.get("lastColumn"),-1,0,canvas-1)));}}
  int firstFooter=paper.path("footer").path("sourceFirstRow").asInt(),minimum=paper.path("footer").path("minimumDataRows").asInt();var footer=new ArrayList<ExportTableLayout.FooterCell>();
  for(var cell:paper.path("footer").path("cells")){var at=address(cell.path("sourceCell").asText());int last=at[1],span=1;String region=cell.path("merge").asText(null);if(region!=null){var parts=region.split(":");var end=address(parts[1]);if(!parts[0].equals(cell.path("sourceCell").asText()))throw new IllegalArgumentException("Footer value must be the merged source anchor");last=end[1];span=end[0]-at[0]+1;}
   var resolved=value(metadata,cell.path("field").asText(null));String type=cell.path("type").asText("text");Object content=type.equals("text")?caption(cell,resolved):resolved.value();
   footer.add(new ExportTableLayout.FooterCell(at[0]-(firstFooter-1),at[1],last,span,type,content,(float)cell.path("fontSize").asDouble(print.path("fontSize").asInt(10)),cell.path("bold").asBoolean(),cell.path("alignment").asText("LEFT"),resolved.pending(),resolved.basis()));
  }
  String title=Objects.toString(metadata.get("title"),contract.path("reportTitle").asText(contract.path("entryName").asText()));
  var sourcePrint=new LinkedHashMap<String,Object>();if(requested==2){if(!frozen.isEmpty()){sourcePrint.putAll(map(frozen.get("sourcePrint")));}else{sourcePrint.putAll(new com.fasterxml.jackson.databind.ObjectMapper().convertValue(paper.path("sourcePrint"),new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){}));}sourcePrint.put("geometrySha256",geometrySha);var proof=paper.path("sourcePrint").path("columnWidthCharacters");if(proof.size()<canvas)throw new IllegalArgumentException("原宽缺少同源物理尺寸依据");for(int column=0;column<canvas;column++)if(Math.abs(widths.get(column)-proof.path(column).asDouble())>.0001)throw new IllegalArgumentException("原宽与同源物理尺寸不一致");}
  return new PaperLayout(requested,templateKey,title,count,canvas,List.copyOf(widths),List.copyOf(hidden),print.path("fontName").asText("宋体"),print.path("fontSize").asInt(10),(float)print.path("rowHeight").asDouble(22),paper.path("headerStartRow").asInt(),paper.path("headerRow").asInt(),List.copyOf(headings),List.copyOf(merges),Map.copyOf(heights),new ExportTableLayout.FooterBlock(minimum,footer),false,Map.copyOf(sourcePrint),geometrySha);
 }
 private record Value(Object value,boolean pending,String basis){}
 /** Geometry-only comparison accepts the production snapshot codec's exact
  * decimal strings. Business rows, heading text and footer values are excluded. */
 private static Map<String,Object> geometryProjection(Map<String,Object> layout){
  var result=new LinkedHashMap<String,Object>();for(String key:List.of("version","templateKey","mainColumnCount","canvasColumns","widths","hiddenColumns","fontName","fontSize","rowHeight","headerStartRow","headerRow","headingRowHeights","landscape","geometrySha256","sourcePrint")){if(!layout.containsKey(key))throw new IllegalArgumentException("Frozen source geometry is incomplete");result.put(key,layout.get(key));}
  if(!(layout.get("headings") instanceof List<?> sourceHeadings)||!(layout.get("merges") instanceof List<?>))throw new IllegalArgumentException("Frozen source header geometry is incomplete");var headings=new ArrayList<Map<String,Object>>();for(Object raw:sourceHeadings){var cell=new LinkedHashMap<>(map(raw));cell.remove("text");headings.add(cell);}result.put("headings",headings);result.put("merges",layout.get("merges"));
  var footer=map(layout.get("footer"));if(!(footer.get("cells") instanceof List<?> sourceCells)||footer.get("minimumDataRows")==null)throw new IllegalArgumentException("Frozen source footer geometry is incomplete");var cells=new ArrayList<Map<String,Object>>();for(Object raw:sourceCells){var cell=new LinkedHashMap<>(map(raw));for(String key:List.of("value","pending","basis")){cell.remove(key);}cells.add(cell);}result.put("footer",Map.of("minimumDataRows",footer.get("minimumDataRows"),"cells",cells));return result;
 }
 private static void requireSameGeometry(Object expected,Object actual){
  if(expected instanceof Number number){try{if(!(actual instanceof Number||actual instanceof String)||new BigDecimal(number.toString()).compareTo(new BigDecimal(actual.toString()))!=0)throw new IllegalArgumentException("Frozen source numeric geometry changed");return;}catch(NumberFormatException failure){throw new IllegalArgumentException("Frozen source numeric geometry invalid",failure);}}
  if(expected instanceof Map<?,?> object){if(!(actual instanceof Map<?,?> value))throw new IllegalArgumentException("Frozen source geometry keys changed");var left=stringGeometryKeys(object);var right=stringGeometryKeys(value);if(!left.keySet().equals(right.keySet()))throw new IllegalArgumentException("Frozen source geometry keys changed");for(String key:left.keySet()){requireSameGeometry(left.get(key),right.get(key));}return;}
  if(expected instanceof List<?> list){if(!(actual instanceof List<?> value)||list.size()!=value.size())throw new IllegalArgumentException("Frozen source geometry list changed");for(int index=0;index<list.size();index++){requireSameGeometry(list.get(index),value.get(index));}return;}
  if(!Objects.equals(expected,actual))throw new IllegalArgumentException("Frozen source geometry changed");
 }
 private static Map<String,Object> stringGeometryKeys(Map<?,?> input){var result=new LinkedHashMap<String,Object>();for(var entry:input.entrySet()){if(entry.getKey()==null||result.containsKey(entry.getKey().toString()))throw new IllegalArgumentException("Ambiguous source geometry key");result.put(entry.getKey().toString(),entry.getValue());}return result;}
 // Frozen originals encode non-integral geometry as decimal text, just as the
 // client worker contract does. Reading it must not replace source widths.
 private static double geometryNumber(Object value,double fallback){
  if(value==null)return fallback;
  try{double result=new BigDecimal(value.toString()).doubleValue();if(!Double.isFinite(result)||result<0||result>255)throw new NumberFormatException();return result;}
  catch(NumberFormatException failure){throw new IllegalArgumentException("Invalid source paper width",failure);}
 }
 private static int geometryInteger(Object value,int fallback,int minimum,int maximum){
  if(value==null)return fallback;
  try{int result=new BigDecimal(value.toString()).intValueExact();if(result<minimum||result>maximum)throw new ArithmeticException();return result;}
  catch(NumberFormatException|ArithmeticException failure){throw new IllegalArgumentException("Invalid source paper column",failure);}
 }
 private static int headingRowNumber(String key){try{return Integer.parseInt(key);}catch(NumberFormatException failure){throw new IllegalArgumentException("Invalid source paper heading row",failure);}}
 private static Value value(Map<String,Object> metadata,String field){
  if(field==null)return new Value(null,false,"");
  if(field.startsWith("paperTotals.")){Object raw=map(metadata.get("paperTotals")).get(field.substring(12));if(!(raw instanceof List<?> groups)||groups.size()!=1)return new Value(null,true,"原单位分组不唯一或缺完整合计，不混加数量/金额");var total=map(groups.getFirst());return new Value(exact(total.get("value")),total.get("value")==null,Objects.toString(total.get("unit"),""));}
  if(field.startsWith("header.")||field.startsWith("footer.")){var parts=field.split(java.util.regex.Pattern.quote("."));var line=line(metadata,parts[0].equals("header")?"headerLines":"footerLines",parts[1]);Object content=parts.length>2?(parts[2].equals("captionLine")?line.isEmpty()?null:lineCaption(line):line.get(parts[2])):line.isEmpty()?null:lineCaption(line);return new Value(exact(content),line.isEmpty()||Boolean.TRUE.equals(line.get("pending")),Objects.toString(line.get("basis"),""));}
  if(field.startsWith("confirmation.")){String key=field.substring(13);var confirmation=map(metadata.get("confirmationMetadata"));if(key.equals("internalState"))return new Value(confirmation.get("internalName")==null?null:"已核对",confirmation.get("internalName")==null,"本份原件实际内部确认");return new Value(exact(confirmation.get(key)),confirmation.get(key)==null,"本份原件实际确认事实");}
  if(field.equals("supplierCustomerPeriod")){var customer=line(metadata,"headerLines","customerName");return new Value(lineCaption(customer)+"                      对帐日期："+date(metadata.get("dateFrom"),"yyyy-M-d")+" 至 "+date(metadata.get("dateTo"),"yyyy-M-d"),Boolean.TRUE.equals(customer.get("pending")),"原供应商客户及查询期间");}
  Object raw=metadata.get(field);return new Value(exact(raw),raw==null,"原件已冻结的实际资料");
 }
 private static String caption(JsonNode cell,Value value){String prefix=cell.path("text").asText("");Object raw=value.value();String field=cell.path("field").asText("");String content=raw==null?"":(field.endsWith("Date")?date(raw,"yyyy年M月d日"):raw.toString());return prefix+content;}
 private static String date(Object value,String pattern){if(value==null)return "";try{return LocalDate.parse(value.toString()).format(DateTimeFormatter.ofPattern(pattern));}catch(java.time.format.DateTimeParseException ignored){return value.toString();}}
 private static String lineCaption(Map<String,Object> line){String label=Objects.toString(line.get("label"),"");Object raw=line.get("value");return label+(label.endsWith(":")||label.endsWith("：")||label.isBlank()?"":"：")+Objects.toString(raw,"");}
 private static Map<String,Object> line(Map<String,Object> metadata,String name,String key){if(metadata.get(name) instanceof List<?> lines){for(Object raw:lines){var line=map(raw);if(key.equals(line.get("key")))return line;}}return Map.of();}
 @SuppressWarnings("unchecked")private static Map<String,Object> map(Object value){return value instanceof Map<?,?> raw?(Map<String,Object>)raw:Map.of();}
 private static Object exact(Object value){return value instanceof BigDecimal number?number.toPlainString():value;}
 private static int[] address(String value){var match=java.util.regex.Pattern.compile("^([A-Z]{1,2})([1-9][0-9]{0,3})$").matcher(value);if(!match.matches())throw new IllegalArgumentException("Invalid source paper address");int column=0;for(char letter:match.group(1).toCharArray()){column=column*26+letter-'A'+1;}return new int[]{Integer.parseInt(match.group(2))-1,column-1};}
 private static void merge(List<ExportTableLayout.Merge> merges,String region){if(region==null)return;var bounds=region.split(":");var first=address(bounds[0]);var last=address(bounds[1]);merges.add(new ExportTableLayout.Merge(first[0],last[0],first[1],last[1]));}
 private static Map<String,Object> json(PaperLayout layout){var result=new LinkedHashMap<String,Object>();result.put("version",layout.version());result.put("templateKey",layout.templateKey());result.put("title",layout.title());result.put("mainColumnCount",layout.mainColumnCount());result.put("canvasColumns",layout.canvasColumns());result.put("widths",layout.widths());result.put("hiddenColumns",layout.hiddenColumns());result.put("fontName",layout.fontName());result.put("fontSize",layout.fontSize());result.put("rowHeight",layout.rowHeight());result.put("headerStartRow",layout.headerStartRow());result.put("headerRow",layout.headerRow());
  result.put("headings",layout.headings().stream().map(h->{var value=new LinkedHashMap<String,Object>();value.put("row",h.row());value.put("column",h.column());value.put("text",h.text());value.put("fontSize",h.fontSize());value.put("bold",h.bold());value.put("alignment",h.alignment());sourceStyle(layout,h.row(),h.column(),value);return value;}).toList());result.put("merges",layout.merges().stream().map(m->Map.of("firstRow",m.firstRow(),"lastRow",m.lastRow(),"firstColumn",m.firstColumn(),"lastColumn",m.lastColumn())).toList());result.put("headingRowHeights",layout.headingRowHeights());
  var cells=new ArrayList<Map<String,Object>>();for(var cell:layout.footer().cells()){var value=new LinkedHashMap<String,Object>();value.put("rowOffset",cell.rowOffset());value.put("column",cell.column());value.put("lastColumn",cell.lastColumn());value.put("rowSpan",cell.rowSpan());value.put("type",cell.type());value.put("value",cell.value());value.put("fontSize",cell.fontSize());value.put("bold",cell.bold());value.put("alignment",cell.alignment());value.put("pending",cell.pending());value.put("basis",cell.basis());sourceStyle(layout,layout.headerRow()+1+layout.footer().minimumDataRows()+cell.rowOffset(),cell.column(),value);cells.add(value);}result.put("footer",Map.of("minimumDataRows",layout.footer().minimumDataRows(),"cells",cells));result.put("landscape",layout.landscape());if(layout.version()==2){result.put("sourcePrint",layout.sourcePrint());result.put("geometrySha256",layout.geometrySha256());}return result;
 }
 private static void sourceStyle(PaperLayout layout,int row,int column,Map<String,Object> value){if(layout.version()!=2)return;int at=column+1;var letters=new StringBuilder();while(at>0){letters.insert(0,(char)('A'+(at-1)%26));at=(at-1)/26;}var style=map(map(layout.sourcePrint().get("sourceStyles")).get(letters.toString()+(row+1)));for(String key:List.of("fontSize","bold","wrapText","shrinkToFit")){if(style.containsKey(key))value.put(key,style.get(key));}Object alignment=style.get("alignment");if(alignment instanceof String name&&Set.of("LEFT","CENTER","RIGHT").contains(name))value.put("alignment",alignment);}
}
