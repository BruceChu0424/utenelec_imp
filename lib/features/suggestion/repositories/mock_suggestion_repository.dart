// 建议 Mock 仓库

import 'dart:async';

import '../models/suggestion.dart';

class MockSuggestionRepository {
  MockSuggestionRepository({this._currentEmployeeId = 'mock-user-001'});

  final String _currentEmployeeId;
  List<Suggestion>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return cb();
  }

  List<Suggestion> _ensureData() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  /// 列表（默认全部员工的建议广场）
  Future<List<Suggestion>> list({SuggestionCategory? category}) async {
    return _delay(() {
      var result = [..._ensureData()];
      if (category != null) {
        result = result.where((s) => s.category == category).toList();
      }
      result.sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
      return result;
    });
  }

  /// 我提交的
  Future<List<Suggestion>> mine() async {
    return _delay(() {
      return _ensureData()
          .where((s) => s.submitterId == _currentEmployeeId)
          .toList()
        ..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
    });
  }

  Future<Suggestion?> getById(String id) async {
    return _delay(() => _ensureData().firstWhere((s) => s.id == id));
  }

  /// 提交建议
  Future<Suggestion> submit({
    required SuggestionCategory category,
    required String title,
    required String content,
    bool isAnonymous = false,
  }) async {
    return _delay(() {
      final s = Suggestion(
        id: 'sug-${DateTime.now().millisecondsSinceEpoch}',
        submitterId: _currentEmployeeId,
        submitterName: '张优腾',
        category: category,
        title: title,
        content: content,
        status: SuggestionStatus.submitted,
        submittedAt: DateTime.now(),
        isAnonymous: isAnonymous,
      );
      _ensureData().insert(0, s);
      return s;
    });
  }

  /// 点赞
  Future<Suggestion> toggleLike(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((s) => s.id == id);
      if (idx < 0) throw Exception('建议不存在');
      final s = list[idx];
      final updated = s.copyWith(
        likes: s.likedByMe ? s.likes - 1 : s.likes + 1,
        likedByMe: !s.likedByMe,
      );
      list[idx] = updated;
      return updated;
    });
  }

  List<Suggestion> _seed() {
    final now = DateTime.now();
    return [
      Suggestion(
        id: 'sug-001',
        submitterId: 'emp-002',
        submitterName: '李工',
        category: SuggestionCategory.equipment,
        title: '建议为车间增加工业风扇',
        content:
            '夏季车间温度较高，虽然有空调但部分工位（特别是焊接区）因为安全原因不能直吹，建议增加工业风扇或岗位送风设备，提升一线员工的工作舒适度。',
        status: SuggestionStatus.resolved,
        submittedAt: now.subtract(const Duration(days: 7)),
        likes: 28,
        replies: [
          SuggestionReply(
            id: 'r1',
            replier: '设备部',
            replierRole: '设备部',
            content: '感谢建议！已采购 8 台岗位送风设备，预计本周内安装到位。',
            repliedAt: now.subtract(const Duration(days: 5)),
          ),
          SuggestionReply(
            id: 'r2',
            replier: '设备部',
            replierRole: '设备部',
            content: '已于昨日完成全部安装，请大家试用后反馈。',
            repliedAt: now.subtract(const Duration(days: 1)),
          ),
        ],
      ),
      Suggestion(
        id: 'sug-002',
        submitterId: 'emp-003',
        submitterName: '王小妹',
        category: SuggestionCategory.welfare,
        title: '建议增加弹性工作时间',
        content:
            '建议公司考虑实施弹性工作时间制度，例如 8:00-9:00 之间打卡都算准时，方便家有小孩的同事接送孩子。这也能缓解早高峰通勤压力。',
        status: SuggestionStatus.reviewing,
        submittedAt: now.subtract(const Duration(days: 4)),
        likes: 45,
        replies: [
          SuggestionReply(
            id: 'r1',
            replier: '人事部',
            replierRole: '人事部',
            content: '已收到您的建议，正在与管理层讨论可行性，会尽快回复。',
            repliedAt: now.subtract(const Duration(days: 3)),
          ),
        ],
      ),
      Suggestion(
        id: 'sug-003',
        submitterId: 'emp-004',
        submitterName: '赵师傅',
        category: SuggestionCategory.process,
        title: '优化产品检测流程',
        content:
            '目前每批产品检测需要往返实验室 3 次取样，建议在生产线末端增设小型检测台，减少搬运时间，预计能提升 15% 的检测效率。',
        status: SuggestionStatus.submitted,
        submittedAt: now.subtract(const Duration(days: 2)),
        isAnonymous: true,
        likes: 12,
      ),
      Suggestion(
        id: 'sug-004',
        submitterId: 'emp-005',
        submitterName: '陈姐',
        category: SuggestionCategory.environment,
        title: '食堂建议增加轻食窗口',
        content:
            '现在食堂菜品偏重油重盐，建议增设轻食窗口（沙拉、水煮、杂粮），照顾健身和减脂同事的需求。同时建议标注菜品的卡路里。',
        status: SuggestionStatus.rejected,
        submittedAt: now.subtract(const Duration(days: 12)),
        likes: 18,
        replies: [
          SuggestionReply(
            id: 'r1',
            replier: '行政部',
            replierRole: '行政部',
            content:
                '感谢建议！考虑到食堂规模和成本，目前暂不增设轻食窗口。但我们已要求食堂每周提供 2-3 道清淡菜品，敬请关注。',
            repliedAt: now.subtract(const Duration(days: 10)),
          ),
        ],
      ),
    ];
  }
}
