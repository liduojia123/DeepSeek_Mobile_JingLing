import 'package:material_ui/material_ui.dart';

/// 兄弟分支切换器 `‹ n/m ›`。
class BranchSwitcher extends StatelessWidget {
  const BranchSwitcher({
    super.key,
    required this.position,
    required this.count,
    required this.onSelected,
    this.enabled = true,
  });

  /// 当前是第几个(1 起)
  final int position;
  final int count;

  /// 传回 0 起的兄弟索引
  final ValueChanged<int> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canGoPrev = enabled && position > 1;
    final canGoNext = enabled && position < count;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: '上一个版本',
          onPressed: canGoPrev ? () => onSelected(position - 2) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          '$position/$count',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: '下一个版本',
          onPressed: canGoNext ? () => onSelected(position) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}
