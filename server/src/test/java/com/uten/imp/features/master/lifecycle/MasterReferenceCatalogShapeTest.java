package com.uten.imp.features.master.lifecycle;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 引用目录的形状契约(不连库)：每段 SQL 都产出统一六列、引用种类与登记的一致、标签可见范围
 * 只用已知的范围名(写错了会让标签一律只计数，不如在这里当场报出)。真库对账见
 * {@link MasterReferenceCatalogCoverageTest}。
 */
class MasterReferenceCatalogShapeTest {

    private static final Pattern SELECT = Pattern.compile("(?s)^\\s*SELECT (.*?)\\n\\s*FROM ");
    private static final Pattern QUOTED = Pattern.compile("'([a-z_]+)'");

    @Test
    void everyBranchSelectsTheSameSixColumnsWithItsOwnKindAndAKnownLabelScope() {
        Set<String> allowed = new TreeSet<>(MasterObjectAccess.DOCUMENT_SCOPES);
        allowed.add("public");
        allowed.add("goods");
        List<String> problems = new ArrayList<>();
        for (MasterReferenceCatalog.Reference reference : MasterReferenceCatalog.references()) {
            String where = reference.table() + "." + reference.column() + " " + reference.kind();
            Matcher select = SELECT.matcher(reference.sql());
            if (!select.find()) {
                problems.add(where + "：不是单条 SELECT … FROM");
                continue;
            }
            String list = select.group(1);
            if (!list.contains("'" + reference.kind().name() + "'")) {
                problems.add(where + "：第二列的引用种类与登记的不一致");
            }
            if (!reference.sql().contains(" IN (SELECT id FROM targets)")
                    && !reference.sql().contains("JOIN targets ")) {
                problems.add(where + "：没有按本批目标过滤");
            }
            String scope = list.substring(list.lastIndexOf(',') + 1);
            Matcher quoted = QUOTED.matcher(scope);
            int found = 0;
            while (quoted.find()) {
                found++;
                if (!allowed.contains(quoted.group(1))) {
                    problems.add(where + "：未知的标签可见范围 " + quoted.group(1));
                }
            }
            if (found == 0) problems.add(where + "：最后一列不是标签可见范围");
        }
        assertThat(problems).isEmpty();
    }

    @Test
    void everyMasterKindHasReferencesAndGoodsCarriesTheSameBatchBomEdge() {
        for (MasterEntityKind kind : MasterEntityKind.values()) {
            assertThat(MasterReferenceCatalog.references(kind)).as(kind.name()).isNotEmpty();
        }
        assertThat(MasterReferenceCatalog.references(MasterEntityKind.GOODS))
                .extracting(MasterReferenceCatalog.Reference::kind)
                .contains(MasterReferenceGuard.RefKind.BOM_PARENT, MasterReferenceGuard.RefKind.BOM_INTERNAL);
        assertThat(MasterReferenceCatalog.exemptions())
                .allSatisfy(exemption -> assertThat(exemption.note()).isNotBlank());
    }
}
