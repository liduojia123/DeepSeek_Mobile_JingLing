import 'package:material_ui/material_ui.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

/// 批量管理底部操作栏(v1.5.2):全选 / 重命名(恰好 1 个)/ 置顶 / 取消置顶 / 删除。
///
/// 无选中时置顶/取消置顶/删除禁用;`busy` 期间全部禁用,防连点。
class BatchActionBar extends StatelessWidget {
  const BatchActionBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onDelete,
    required this.onPin,
    required this.onUnpin,
    required this.onToggleAll,
    this.onRename,
    this.busy = false,
  });

  final int selectedCount;
  final int totalCount;
  final VoidCallback onDelete;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final VoidCallback onToggleAll;
  final VoidCallback? onRename;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    final hasSelection = selectedCount > 0;
    final allSelected = totalCount > 0 && selectedCount >= totalCount;

    Widget action({
      required IconData icon,
      required String label,
      required bool enabled,
      required VoidCallback onTap,
      bool danger = false,
    }) {
      final color = danger ? colors.danger : colors.accent;
      final content = Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(label, style: type.meta.copyWith(color: color)),
          ],
        ),
      );
      return InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
          child: content,
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Material(
        color: colors.surface,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.border))),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          child: Row(
            children: [
              action(
                icon: allSelected ? Icons.deselect : Icons.select_all_outlined,
                label: allSelected ? '取消全选' : '全选',
                enabled: totalCount > 0 && !busy,
                onTap: onToggleAll,
              ),
              const Spacer(),
              if (onRename != null && selectedCount == 1)
                action(
                  icon: Icons.drive_file_rename_outline,
                  label: '重命名',
                  enabled: !busy,
                  onTap: onRename!,
                ),
              action(
                icon: Icons.push_pin_outlined,
                label: '置顶',
                enabled: hasSelection && !busy,
                onTap: onPin,
              ),
              action(
                icon: Icons.push_pin,
                label: '取消置顶',
                enabled: hasSelection && !busy,
                onTap: onUnpin,
              ),
              action(
                icon: Icons.delete_outline,
                label: '删除',
                enabled: hasSelection && !busy,
                onTap: onDelete,
                danger: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
