import 'package:flutter/material.dart';

/// 保存目录一行：路径 +「更改」。
class SaveDirTile extends StatelessWidget {
  const SaveDirTile({super.key, required this.path, required this.onTap});

  final String path;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final empty = path.isEmpty;
    return Material(
      color: const Color(0xFFF5F7FA),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD9E2EC)),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, size: 20, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  empty ? '点击选择保存目录' : path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: empty
                        ? const Color(0xFF9FB3C8)
                        : const Color(0xFF102A43),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '更改',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: onTap == null ? const Color(0xFF9FB3C8) : cs.primary,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: onTap == null
                    ? const Color(0xFF9FB3C8)
                    : const Color(0xFF486581),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
