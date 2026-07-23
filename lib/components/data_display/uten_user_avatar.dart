import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

/// 统一的圆形用户头像；暂无照片时显示姓名首字或用户图标。
class UtenUserAvatar extends StatelessWidget {
  const UtenUserAvatar({super.key, this.size = 48, this.name});

  final double size;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final characters = name?.trim().characters;
    final initial = characters == null || characters.isEmpty
        ? null
        : characters.first;

    return Semantics(
      image: true,
      label: name == null ? 'User avatar' : '$name avatar',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [UtenColors.deepGreen, UtenColors.teal700],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Theme.of(context).colorScheme.surface,
            width: 2,
          ),
        ),
        child: initial == null
            ? Icon(Icons.person_rounded, color: Colors.white, size: size * 0.5)
            : Text(
                initial,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}
