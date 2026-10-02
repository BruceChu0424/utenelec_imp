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

  static void requireCompleteSequence(Collection<Integer> versions) {
    var ordered=new TreeSet<Integer>();
    for(int version:versions) {
      if(!ordered.add(version)) throw new IllegalStateException(
          "Duplicate migration V"+version+"; every migration version must be unique");
    }
    if(ordered.isEmpty() || ordered.last()<FIRST_FORWARD_VERSION) return;
    for(int version=FIRST_FORWARD_VERSION;version<=ordered.last();version++) {
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
        if(match.matches()) versions.add(Integer.parseInt(match.group(1)));});
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
