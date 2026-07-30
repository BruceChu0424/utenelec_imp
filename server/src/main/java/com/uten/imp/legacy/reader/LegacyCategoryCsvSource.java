package com.uten.imp.legacy.reader;

import org.springframework.context.annotation.Profile;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * <b>dev</b> 离线数据源：从 classpath 读老库导出的 CSV。
 *
 * <p>避开「Java 连 Windows LocalDB 需 sqljdbc_auth.dll」的集成认证坑——dev 直接读快照。
 * prod 用 {@link LegacySystemItemReader} 连真实老库。
 *
 * <p>CSV 格式（管道分隔，首行表头 {@code legacy_id|parent_legacy|code|name}）。
 * 按 {@code itemClassId} 选择对应快照：1=货品分类、18=模具系列；新模块落地时补充对应 CSV。
 */
@Component
@Profile("dev")
public class LegacyCategoryCsvSource implements LegacyCategorySource {

    /** ItemclassID → classpath 离线 CSV 映射。 */
    private static String csvFor(int itemClassId) {
        return switch (itemClassId) {
            case 1 -> "legacy-migration/goods_categories.csv";
            case 2 -> "legacy-migration/client_categories.csv";
            case 3 -> "legacy-migration/supplier_categories.csv";
            case 18 -> "legacy-migration/mould_categories.csv";
            default -> throw new IllegalStateException("无离线 CSV：ItemclassID=" + itemClassId
                    + "（dev 预置：货品=1、客户=2、供应商=3、模具=18；其他 itemclass 请先补 CSV）");
        };
    }

    @Override
    public List<LegacyCategoryRow> readCategoryTree(int itemClassId) {
        String csv = csvFor(itemClassId);
        try (var is = new ClassPathResource(csv).getInputStream();
             var br = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
            return br.lines()
                    .skip(1)  // 表头
                    .filter(l -> !l.isBlank())
                    .map(this::parse)
                    .toList();
        } catch (IOException e) {
            throw new IllegalStateException("读取 legacy CSV 失败：" + csv, e);
        }
    }

    private LegacyCategoryRow parse(String line) {
        var p = line.split("\\|", -1);
        return new LegacyCategoryRow(
                Integer.parseInt(p[0].trim()),
                Integer.parseInt(p[1].trim()),
                p[2].trim(),
                p[3].trim());
    }
}
