package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import java.nio.file.*;
import java.util.*;
import java.util.regex.Pattern;
import static org.assertj.core.api.Assertions.*;

/** After the reviewed V768 baseline, an executable checkout must not ship a
 * higher migration while a parallel worker still owns an earlier reservation. */
class ForwardMigrationSequenceContractTest {
  private static final int FIRST_FORWARD_VERSION = 769;
  private static final Pattern SCRIPT = Pattern.compile("V([0-9]+)__.+\\.sql");

  /**
   * 永久注销、永不补发的整版号（既成事实，不作为新批次跳号的先例）。
   *
   * <p>V1010 在 V1000-V1040 财务复刻/精度批次（同一集成快照提交引入）中跳号未用：
   * 该批次连同低于 V1000 的点分补号迁移 V990_1（Flyway 990.1）与 V999_1-13（999.1-999.13）
   * 已按既定顺序应用，V1005-V1040 依赖 V999.x 建立的表；既有库已越过 V1010，
   * 事后补发 V1010 只会在这些库上乱序晚应用，且重编号会破坏已应用迁移的 checksum，
   * 因此只能注销该号。本例外只豁免此清单内的整版号；其它版本仍必须前向连续，
   * 新批次出现新跳号依旧失败。点分子号文件不匹配 {@link #SCRIPT} 的整版模式，
   * 本就不参与整版连续性检查。</p>
   */
  private static final java.util.Set<Integer> RETIRED_NEVER_ISSUED_VERSIONS = java.util.Set.of(1010);

  static void requireCompleteSequence(Collection<Integer> versions) {
    var ordered=new TreeSet<Integer>();
    for(int version:versions) {
      if(!ordered.add(version)) throw new IllegalStateException(
          "Duplicate migration V"+version+"; every migration version must be unique");
    }
    if(ordered.isEmpty() || ordered.last()<FIRST_FORWARD_VERSION) return;
    for(int version=FIRST_FORWARD_VERSION;version<=ordered.last();version++) {
      if(RETIRED_NEVER_ISSUED_VERSIONS.contains(version)) continue;
      if(!ordered.contains(version)) throw new IllegalStateException(
          "Reserved forward migration V"+version+" is missing before V"+ordered.last()
          +"; do not merge later migrations into a runnable checkout first");
    }
  }

  @Test void currentForwardMigrationFilesHaveNoUnfinishedReservationGap() throws Exception {
    Path path=Path.of("src/main/resources/db/migration");
    if(!Files.isDirectory(path)) path=Path.of("server/src/main/resources/db/migration");
    var versions=new ArrayList<Integer>();
    try(var files=Files.list(path)) {
      files.forEach(file->{var match=SCRIPT.matcher(file.getFileName().toString());
        if(match.matches()) versions.add(com.uten.imp.testsupport.FixtureNumbers.integer(match.group(1)));});
    }
    assertThat(versions).isNotEmpty();
    requireCompleteSequence(versions);
  }

  @Test void reproducesTheV774BeforeV773DeliveryFailure() {
    assertThatThrownBy(()->requireCompleteSequence(List.of(768,769,770,771,772,774)))
        .isInstanceOf(IllegalStateException.class).hasMessageContaining("V773");
  }

  @Test void rejectsTheTwoParallelV782FilesInsteadOfSilentlyDeduplicating() {
    // V782__explicit_test_business_reset_with_history.sql and
    // V782__stock_document_item_line_warehouse_and_place_learning.sql.
    var versions=new ArrayList<Integer>();
    for(int version=769;version<=782;version++) versions.add(version);
    versions.add(782);
    assertThatThrownBy(()->requireCompleteSequence(versions))
        .isInstanceOf(IllegalStateException.class).hasMessageContaining("Duplicate migration V782");
  }

  @Test void historicalGapsRemainHistoricalButNewReservedGapsAreRejected() {
    var versions=new ArrayList<>(List.of(1,4,300,768));
    for(int i=769;i<=778;i++) versions.add(i);
    assertThatCode(()->requireCompleteSequence(versions)).doesNotThrowAnyException();
    versions.add(780);
    assertThatThrownBy(()->requireCompleteSequence(versions)).hasMessageContaining("V779");
  }
}
