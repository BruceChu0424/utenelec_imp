// 检测 Mock 仓库（Phase 4）

import '../../../core/utils/china_datetime.dart';
import '../models/lab_test.dart';

class MockLabRepository {
  MockLabRepository();
  List<LabTest>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    return cb();
  }

  List<LabTest> _ensure() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  Future<List<LabTest>> list({String? search, bool? qualified}) async {
    return _delay(() {
      var result = [..._ensure()];
      if (qualified != null) {
        result = result.where((t) => t.qualified == qualified).toList();
      }
      if (search != null && search.trim().isNotEmpty) {
        final q = search.trim().toLowerCase();
        result = result
            .where(
              (t) =>
                  t.sampleCode.toLowerCase().contains(q) ||
                  t.sampleName.toLowerCase().contains(q) ||
                  t.project.toLowerCase().contains(q),
            )
            .toList();
      }
      result.sort((a, b) => b.testDate.compareTo(a.testDate));
      return result;
    });
  }

  Future<LabTest?> getById(String id) async {
    return _delay(() => _ensure().firstWhere((t) => t.id == id));
  }

  Future<LabTest> create(LabTest t) async {
    return _delay(() {
      _ensure().insert(0, t);
      return t;
    });
  }

  List<LabTest> _seed() {
    final now = ChinaDateTime.now();
    DateTime d(int days) => now.subtract(Duration(days: days));
    return [
      LabTest(
        id: 'lab-001',
        sampleCode: 'S202607-001',
        sampleName: '钢板 A 型',
        source: '批次 B202607',
        project: '拉伸强度',
        result: '320 MPa',
        standard: '≥ 300 MPa',
        qualified: true,
        testDate: d(1),
        testerName: '赵敏',
        equipment: '万能试验机',
      ),
      LabTest(
        id: 'lab-002',
        sampleCode: 'S202607-002',
        sampleName: '涂料 B 型',
        source: '批次 T202607',
        project: '含水率',
        result: '8.2%',
        standard: '≤ 6.0%',
        qualified: false,
        testDate: d(1),
        testerName: '赵敏',
        equipment: '水分测定仪',
        remark: '含水率超标，建议复检',
      ),
      LabTest(
        id: 'lab-003',
        sampleCode: 'S202607-003',
        sampleName: '螺栓 M10',
        project: '硬度',
        result: 'HRC 28',
        standard: 'HRC 25-32',
        qualified: true,
        testDate: d(2),
        testerName: '钱杰',
        equipment: '硬度计',
      ),
      LabTest(
        id: 'lab-004',
        sampleCode: 'S202607-004',
        sampleName: '铝合金板材',
        source: '批次 AL202606',
        project: '成分分析',
        result: '合格',
        standard: 'GB/T 3190',
        qualified: true,
        testDate: d(3),
        testerName: '赵敏',
        equipment: '光谱仪',
      ),
      LabTest(
        id: 'lab-005',
        sampleCode: 'S202607-005',
        sampleName: '塑料颗粒',
        project: '熔融指数',
        result: '12.5 g/10min',
        standard: '10-15 g/10min',
        qualified: true,
        testDate: d(4),
        testerName: '钱杰',
        equipment: '熔指仪',
      ),
      LabTest(
        id: 'lab-006',
        sampleCode: 'S202607-006',
        sampleName: '钢管 焊缝',
        project: '无损探伤',
        result: '未发现缺陷',
        standard: 'GB/T 3323',
        qualified: true,
        testDate: d(5),
        testerName: '赵敏',
        equipment: 'X射线探伤机',
      ),
      LabTest(
        id: 'lab-007',
        sampleCode: 'S202607-007',
        sampleName: '橡胶密封圈',
        project: '拉伸强度',
        result: '14 MPa',
        standard: '≥ 16 MPa',
        qualified: false,
        testDate: d(6),
        testerName: '钱杰',
        equipment: '拉力机',
        remark: '强度不达标，已通知生产部',
      ),
      LabTest(
        id: 'lab-008',
        sampleCode: 'S202607-008',
        sampleName: '电线电缆',
        project: '绝缘电阻',
        result: '500 MΩ',
        standard: '≥ 100 MΩ',
        qualified: true,
        testDate: d(7),
        testerName: '赵敏',
        equipment: '绝缘电阻测试仪',
      ),
    ];
  }
}
