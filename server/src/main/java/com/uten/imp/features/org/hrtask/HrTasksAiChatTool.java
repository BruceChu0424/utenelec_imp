package com.uten.imp.features.org.hrtask;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Reuses the HR task center's authoritative dates and claim state; never reveals salary or identity documents. */
@Component
public class HrTasksAiChatTool implements AiChatToolPort {
    private static final Set<String> CATEGORIES=Set.of("SUMMARY","CONFIRM","NEW_HIRES","ANNIVERSARY","BIRTHDAY");
    private final AiChatAccessPolicy access;
    private final HrTaskService tasks;
    private final ObjectMapper json;
    public HrTasksAiChatTool(AiChatAccessPolicy access,HrTaskService tasks,ObjectMapper json) {
        this.access=access; this.tasks=tasks; this.json=json;
    }
    @Override public String name() { return "hr_tasks"; }
    @Override public String title() { return "查询人事提醒任务"; }
    @Override public String domain() { return "HR"; }
    @Override public String description() { return "查询当前获授权HR任务中心中的转正、新入职、入职周年提醒；生日仅在单独隐私查看授权下可查。可用category选择类别、keyword按员工姓名或工号筛选，最多展示20条。不查工资、证件、银行信息，不认领、不修改员工、不发送祝福。"; }
    @Override public Map<String,Object> parameters() {
        List<String> categories=CATEGORIES.stream().filter(value->!"BIRTHDAY".equals(value)||canPii()).sorted().toList();
        return Map.of("type","object","additionalProperties",false,"properties",Map.of(
                "category",Map.of("type","string","enum",categories),
                "keyword",Map.of("type","string","maxLength",80)),"required",List.of());
    }
    @Override public boolean available() {
        try { var actor=access.requireChat(); return access.hasDomain(domain())&&(actor.isSuperAdmin()||actor.getPermissions().contains("employee:view")); }
        catch(ApiException denied) { return false; }
    }
    @Override @Transactional(readOnly=true,propagation=Propagation.REQUIRES_NEW,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> execute(Map<String,Object> arguments) {
        Request request=parse(arguments); Snapshot facts=read(request);
        StringBuilder reply=new StringBuilder("人事任务计算基准日：").append(facts.day()).append("。范围：当前获授权的人事任务中心。\n");
        facts.counts().forEach((kind,count)->reply.append("\n• ").append(kind).append("：").append(count).append(" 项"));
        if(facts.rows().isEmpty()) reply.append("\n当前范围未找到符合筛选条件的提醒；这不代表所有员工事项均已处理。");
        else {
            reply.append("\n\n以下显示前 ").append(Math.min(20,facts.rows().size())).append(" 条：");
            for(Row row:facts.rows().stream().limit(20).toList()) {
                reply.append("\n• ").append(row.kind()).append(" · ").append(row.code()).append(" · ").append(row.name())
                        .append(" · ").append(row.department()).append(" · 相关日期 ").append(row.date()).append(" · ").append(row.claim());
            }
            if(facts.rows().size()>20) reply.append("\n还有其他匹配提醒，请指定类别或员工工号缩小范围。");
        }
        if(facts.legacy()!=null) reply.append("\n另有人事中心标记的历史转正日期待补录 ").append(facts.legacy()).append(" 项，请在原页面核对。");
        reply.append("\n\n来源：HR任务中心的动态提醒与有效认领状态。提醒不等于已审批或已办理；后续操作由你在原页面手动处理。未提供薪资、证件号码、银行账户或年龄。");
        return Map.of("reply",reply.toString(),"actions",List.of(),"_toolEvidence",Map.of("category",request.category(),"keyword",request.keyword(),"snapshot",signature(facts)));
    }
    @Override @Transactional(readOnly=true,propagation=Propagation.REQUIRES_NEW,isolation=Isolation.REPEATABLE_READ)
    public void authorizeResultRead(Map<String,Object> evidence) {
        if(evidence==null||!evidence.keySet().equals(Set.of("category","keyword","snapshot"))
                ||!(evidence.get("snapshot") instanceof String expected)||!(evidence.get("category") instanceof String category)
                ||!(evidence.get("keyword") instanceof String keyword)) throw changed();
        Request request=parse(Map.of("category",category,"keyword",keyword));
        if(!expected.equals(signature(read(request)))) throw changed();
    }
    private Snapshot read(Request request) {
        if(!available()) throw new ApiException(ErrorCode.FORBIDDEN,"当前账号没有人事任务查看权限");
        boolean pii=canPii();
        if("BIRTHDAY".equals(request.category())&&!pii) throw new ApiException(ErrorCode.FORBIDDEN,"生日提醒需要单独的员工隐私查看权限");
        HrTaskSummary summary=tasks.summary();
        List<Row> rows=new ArrayList<>(); Map<String,Long> counts=new LinkedHashMap<>();
        if(Set.of("SUMMARY","CONFIRM").contains(request.category())) {
            add(rows,counts,summary.confirmToday(),"今日预计转正",request.keyword());
            add(rows,counts,summary.confirmOverdue(),"逾期转正",request.keyword());
            add(rows,counts,summary.confirmUpcoming(),"30天内预计转正",request.keyword());
        }
        if(Set.of("SUMMARY","NEW_HIRES").contains(request.category())) add(rows,counts,summary.newHires(),"近30天新入职",request.keyword());
        if(Set.of("SUMMARY","ANNIVERSARY").contains(request.category())) add(rows,counts,summary.anniversaryToday(),"今日入职周年",request.keyword());
        if(pii&&Set.of("SUMMARY","BIRTHDAY").contains(request.category())) {
            add(rows,counts,summary.birthdayToday(),"今日生日",request.keyword());
            add(rows,counts,summary.birthdayUpcoming(),"30天内生日",request.keyword());
        }
        Long legacy=request.keyword().isEmpty()&&Set.of("SUMMARY","CONFIRM").contains(request.category())?summary.unconfirmedLegacyCount():null;
        return new Snapshot(String.valueOf(summary.generatedAt()),request.category(),request.keyword(),counts,List.copyOf(rows),legacy);
    }
    private static void add(List<Row> target,Map<String,Long> counts,List<HrTaskSummary.Item> source,String kind,String keyword) {
        String query=keyword.toLowerCase(Locale.ROOT);
        List<HrTaskSummary.Item> selected=source.stream().filter(item->query.isEmpty()
                || safe(item.code()).toLowerCase(Locale.ROOT).contains(query)||safe(item.name()).toLowerCase(Locale.ROOT).contains(query)).toList();
        counts.put(kind,(long)selected.size());
        for(var item:selected) {
            if(item.employeeId()==null) throw changed();
            String claim=item.claimedByMe()?"我已认领":item.claimedByName()==null?"未认领":"其他同事已认领";
            if(item.blessed()) claim+="；已登记庆典祝福";
            target.add(new Row(item.employeeId(),kind,label(item.code()),label(item.name()),label(item.deptName()),
                    String.valueOf(item.date()),claim));
        }
    }
    private boolean canPii() {
        try { AuthUser actor=access.requireChat(); return actor.isSuperAdmin()||actor.getPermissions().contains("employee:pii:view"); }
        catch(ApiException denied) { return false; }
    }
    private static Request parse(Map<String,Object> args) {
        if(args==null||!Set.of("category","keyword").containsAll(args.keySet())) throw invalid();
        Object category=args.getOrDefault("category","SUMMARY"),keyword=args.getOrDefault("keyword","");
        if(!(category instanceof String type)||!CATEGORIES.contains(type)||!(keyword instanceof String text)
                ||text.length()>80||text.codePoints().anyMatch(Character::isISOControl)) throw invalid();
        return new Request(type,text.strip());
    }
    private String signature(Snapshot snapshot) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(json.writeValueAsString(snapshot).getBytes(StandardCharsets.UTF_8))); }
        catch(JsonProcessingException|NoSuchAlgorithmException failed) { throw new IllegalStateException("Cannot fingerprint HR reminders",failed); }
    }
    private record Request(String category,String keyword) {}
    private record Row(UUID employeeId,String kind,String code,String name,String department,String date,String claim) {}
    private record Snapshot(String day,String category,String keyword,Map<String,Long> counts,List<Row> rows,Long legacy) {}
    private static String safe(String text) { return text==null?"":text; }
    private static String label(String text) { String value=safe(text).replaceAll("[\\p{Cntrl}]"," "); return value.isBlank()?"未登记":value.length()>64?value.substring(0,63)+"…":value; }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED,"人事任务只支持已登记类别及员工姓名或工号筛选"); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN,"人事任务或可见范围已变化，请重新查询"); }
}
