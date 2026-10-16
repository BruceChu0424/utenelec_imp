import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/search/keyword_search.dart';

void main() {
  test('关键词跨字段AND且通配符为字面值', () {
    expect(matchesKeywordSearch(['张三', 'UT001', '工程研发部'], '张三 研发'), isTrue);
    expect(matchesKeywordSearch(['张三', 'UT001', '工程研发部'], '张三 财务'), isFalse);
    expect(matchesKeywordSearch(['普通人员'], '%'), isFalse);
    expect(matchesKeywordSearch(['编号_%\\'], '_%\\'), isTrue);
  });
  test('身份精确、前缀、完整短语、跨字段多词顺序明确', () {
    expect(normalizedKeywordPhrase('  UT001　 张三  '), 'ut001 张三');
    expect(keywordSearchRank(['张三'], ' 张三 '), 0);
    expect(keywordSearchRank(['张三助手'], '张三'), 1);
    expect(keywordSearchRank(['新张三助手'], '张三'), 2);
    expect(keywordSearchRank(['张三', '工程部'], '张三 工程'), 3);
    expect(keywordSearchRank(['李四'], '张三'), isNull);
  });
  test('名称包含与多词匹配先于编号精确，且不扩大原候选集合', () {
    final rows = [
      ('code', 'ordinary', 'Metric Screw'),
      ('prefix', 'Metric Screw extra', 'other'),
      ('exact', 'Metric Screw', 'other'),
      ('contains', 'Small Metric Screw', 'other'),
      ('words', 'Metric steel Screw', 'other'),
      ('unrelated', 'Metric', 'other'),
    ];
    final matches = rows
        .where(
          (row) =>
              keywordSearchRankWithPrimary(
                [row.$2],
                [row.$3],
                'Metric Screw',
              ) !=
              null,
        )
        .toList();
    matches.sort(
      (a, b) => keywordSearchRankWithPrimary([a.$2], [a.$3], 'Metric Screw')!
          .compareTo(
            keywordSearchRankWithPrimary([b.$2], [b.$3], 'Metric Screw')!,
          ),
    );
    expect(matches.map((row) => row.$1), [
      'exact',
      'prefix',
      'contains',
      'words',
      'code',
    ]);
    expect(keywordSearchRankWithPrimary(['AxYB'], ['other'], 'A%_B'), isNull);
    expect(keywordSearchRankWithPrimary(['A%_B'], ['other'], 'A%_B'), 0);
  });
}
