import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../tokens.dart';

/// 空状态:一个图标 + 一句主文案 + 一句说明。全 App 统一这一个。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: colors.textMuted),
            const SizedBox(height: AppSpace.md),
            Text(title, textAlign: TextAlign.center, style: type.subtitle),
            if (body != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: type.meta.copyWith(color: colors.textMuted),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpace.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
