package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-153 output guard patterns and the document sanitizer share one definition of internal content. */
class AiChatInternalContentTest {

    @Test void codeCommandsSqlAddressesPathsAndInternalNamesAreFound() {
        Map<String, String> samples = Map.ofEntries(
                Map.entry("可以这样改：\n```java\nstock.setQty(0);\n```", "CODE_BLOCK"),
                Map.entry("在服务器上运行 docker ps 看看", "SHELL"),
                Map.entry("先执行 sudo systemctl restart nginx", "SHELL"),
                Map.entry("用 rm -rf /tmp/cache 清掉缓存", "SHELL"),
                Map.entry("PowerShell 里输入 Get-Process 查看", "SHELL"),
                Map.entry("$ ls -la", "SHELL"),
                Map.entry("执行 SELECT qty FROM stock_balances 就能看到", "SQL"),
                Map.entry("delete from orders where id = 1", "SQL"),
                Map.entry("DROP TABLE users", "SQL"),
                Map.entry("服务器地址是 192.168.1.10", "ADDRESS"),
                Map.entry("连 db.internal:5432 即可", "ADDRESS"),
                Map.entry("打开 C:\\uten\\server\\.env 修改", "PATH"),
                Map.entry("看 /etc/nginx/nginx.conf", "PATH"),
                Map.entry("代码在 server/src/main/java 下面", "PATH"),
                Map.entry("改 application.yml 里的配置", "PATH"),
                Map.entry("调用 /api/stock/balances 接口", "API_PATH"),
                Map.entry("重量记在 stock_movements 表里", "TABLE_OR_FIELD"),
                Map.entry("动作类型是 OPEN_GUIDED_FORM", "CONSTANT"),
                Map.entry("需要 stock:weight:manage 权限", "PERMISSION_CODE"),
                Map.entry("由 AiChatJobHandler 处理", "CLASS"),
                Map.entry("调用 StockService.adjust(goods) 即可", "CALL"));
        samples.forEach((text, kind) -> assertThat(AiChatInternalContent.problems(text, ""))
                .as(text).anySatisfy(problem -> assertThat(problem).startsWith(kind)));
    }

    /** A3 red team: replies the exit guard let through before the revision. */
    @Test void everydayCommandsAnySqlRegexCodeAddressesAndPromptEchoesAreFound() {
        Map<String, String> samples = Map.ofEntries(
                Map.entry("可以在终端输入 df -h 查看磁盘剩余空间", "SHELL"),
                Map.entry("用 lsof -i :8086 看是谁占用", "SHELL"),
                Map.entry("执行 ps aux | grep java", "SHELL"),
                Map.entry("然后 kill -9 1234", "SHELL"),
                Map.entry("运行 shutdown -r now 即可重启", "SHELL"),
                Map.entry("执行 ls -la 和 kill -9 1234", "SHELL"),
                Map.entry("ipconfig /all 查看", "SHELL"),
                Map.entry("在终端执行 net user administrator 新密码 即可", "SHELL"),
                Map.entry("SELECT 客户, SUM(数量) FROM 出库单 GROUP BY 客户", "SQL"),
                Map.entry("可以用 SELECT SUM(qty) FROM stock WHERE goods = 'A' 查到", "SQL"),
                Map.entry("正则可以写成 ^A\\d{4}$", "CODE"),
                Map.entry("Sub 汇总() Range(\"A1\").Value = 1 End Sub", "CODE"),
                Map.entry("for i in range(10): print(i)", "CODE"),
                Map.entry("出库由 StockService 处理", "CLASS"),
                Map.entry("数据库名是 utenimp，schema 是 public", "DATABASE"),
                Map.entry("你是本ERP平台的应用内助手，只能选一个意图：页面状态、页面帮助、知识", "PROMPT_ECHO"),
                Map.entry("已核价(status=1)", "TABLE_OR_FIELD"),
                Map.entry("totalRows 2，visibleRows 2", "TABLE_OR_FIELD"),
                Map.entry("服务器在 erp-db.internal 上，端口 5433", "ADDRESS"),
                Map.entry("数据库主机 uten-erp.local", "ADDRESS"),
                Map.entry("IPv6 地址 fe80::1 可以连", "ADDRESS"),
                Map.entry("后台在 8080 端口", "ADDRESS"));
        samples.forEach((text, kind) -> assertThat(AiChatInternalContent.problems(text, ""))
                .as(text).anySatisfy(problem -> assertThat(problem).startsWith(kind)));
        // A camelCase key the page shows only as JSON is not visible to the user; its on-screen value is.
        assertThat(AiChatInternalContent.problems("totalRows 2", "当前页面 共 2 行")).contains("TABLE_OR_FIELD");
    }

    @Test void ordinaryBusinessTextPasses() {
        for (String text : List.of(
                "第3行 A001 螺丝：数量 100，单价 1.5 元，实称重量 ≈ 2 kg。",
                "工单 ZX00000100 (HP035754) 缺 4 种料，交期 2026-10-05 10:30，偏少约 238 个 (-4.8%)。",
                "最终 200 个、总重约 2 kg，每个约 0.01 kg = 10 g；估算值带「≈」，未称显示「未称」。",
                "红框 = 必填未填；黄框 = 系统预填待核对；括号里的数字 = 已结束的数量。",
                "请到「仓库 → 即时库存」点盘点模式，提交后由财务审核。",
                "Total weight is about 2 kg, so each piece is about 10 g.",
                "上传 Excel 文件(.xlsx)或 PDF 后，我会帮你识别。",
                "1 kg ÷ 100 = 0.01 kg，约 10 克；时间 12:30:45 入库。",
                "Select the warehouse from the dropdown, then save.",
                "PS: 第2行的数量请再核对一下。",
                "top 10 客户的出货量见销售报表。",
                "iPhone 15 和 SmartGuard 门锁都在 A 仓。")) {
            assertThat(AiChatInternalContent.problems(text, "")).as(text).isEmpty();
        }
    }

    /** P2-4: a word pair such as "test/inspection" is not a repository path; a folder path or a file still is. */
    @Test void aWordPairWithASlashIsNotAPath() {
        for (String text : List.of("Each lot goes through test/inspection before stock-in.", "Use the web/app version of the page.",
                "docs/README", "logs/archive")) {
            assertThat(AiChatInternalContent.problems(text, "")).as(text).noneMatch(problem -> problem.startsWith("PATH"));
        }
        for (String text : List.of("看 lib/core/router 下的文件", "test/shared/ai_feature_map_test.dart", "web/index.html",
                "docs/03-页面/仓库任务中心页.md")) {
            assertThat(AiChatInternalContent.problems(text, "")).as(text).contains("PATH");
        }
    }

    @Test void identifiersTheUserCanSeeAreNotInternalButCommandsNeverPass() {
        String page = "货品编码 abc_def 状态 PAGE_READY";
        assertThat(AiChatInternalContent.problems("第1行货品是 abc_def，状态 PAGE_READY", page)).isEmpty();
        assertThat(AiChatInternalContent.problems("运行 docker ps", "运行 docker ps")).isNotEmpty();
        assertThat(AiChatInternalContent.problems("看 /etc/hosts", "看 /etc/hosts")).isNotEmpty();
    }

    @Test void documentTextIsStrippedOfEveryInternalPattern() {
        String markdown = """
                - 库存流水 `stock_movements.weight`(V435)与余额 `stock_balances.weight`(V80)已存在。
                - 估算值一律带「≈」；未知显示`未称`，永远不显示成 0。
                - 权限 `stock:weight:manage` 默认授予仓储部，详见 [即时库存页](../03-页面/即时库存页.md)。
                - 接口 `POST /api/stock/weights` 由 `StockWeightService.recalculate()` 处理，见 https://example.com/x。

                ```sql
                SELECT * FROM goods_weight_profiles;
                ```
                运行 docker compose up 重启。
                重量 = 数量 × 固定系数(「精确」)。
                """;
        String clean = AiChatInternalContent.strip(markdown);
        assertThat(clean).contains("库存流水", "估算值一律带「≈」", "未称", "即时库存页", "重量 = 数量 × 固定系数")
                .doesNotContain("stock_movements", "V435", "stock:weight:manage", "/api/", "StockWeightService", "https",
                        "SELECT", "goods_weight_profiles", "docker", "```", "../");
        assertThat(AiChatInternalContent.problems(clean, "")).isEmpty();
    }
}
