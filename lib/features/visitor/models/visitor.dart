// 访客账号模型（对应后端 VisitorAccount / VisitorTokenResponse）。

class Visitor {
  const Visitor({
    required this.id,
    required this.visitorNo,
    required this.name,
    this.avatarSeed,
  });

  final String id;
  final String visitorNo;
  final String name;
  final String? avatarSeed;

  factory Visitor.fromJson(Map<String, dynamic> j) => Visitor(
    id: (j['visitorId'] ?? j['id'] ?? '').toString(),
    visitorNo: (j['visitorNo'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    avatarSeed: j['avatarSeed'] as String?,
  );
}
