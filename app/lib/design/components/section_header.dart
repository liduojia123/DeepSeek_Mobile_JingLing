import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../tokens.dart';

/// 分组标题(今天/昨天/本周…)。用字距和颜色分层,不加分隔线。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpace.page,
        right: AppSpace.page,
        top: AppSpace.xxl,
        bottom: AppSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: type.meta.copyWith(
                color: colors.textMuted,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.08 * 12,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
