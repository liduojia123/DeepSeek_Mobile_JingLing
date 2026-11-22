import 'package:material_ui/material_ui.dart';

enum MessageMenuAction { copy, edit, regenerate, delete }

/// 长按菜单。返回 null 表示取消。
Future<MessageMenuAction?> showMessageMenu(
  BuildContext context, {
  required bool isUser,
  required bool canRegenerate,
  required bool canEdit,
}) {
  return showModalBottomSheet<MessageMenuAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('复制'),
            onTap: () => Navigator.pop(sheetContext, MessageMenuAction.copy),
          ),
          if (isUser && canEdit)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑重发'),
              subtitle: const Text('生成一条新的兄弟分支,旧回答保留'),
              onTap: () => Navigator.pop(sheetContext, MessageMenuAction.edit),
            ),
          if (!isUser && canRegenerate)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重新生成'),
              subtitle: const Text('在同一问题下生成另一个版本'),
              onTap: () => Navigator.pop(sheetContext, MessageMenuAction.regenerate),
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(sheetContext, MessageMenuAction.delete),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
