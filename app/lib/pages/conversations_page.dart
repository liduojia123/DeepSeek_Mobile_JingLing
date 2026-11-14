import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../models/models.dart';
import 'chat_page.dart';
import 'settings_page.dart';

class ConversationsPage extends ConsumerWidget {
  const ConversationsPage({super.key});

  Future<void> _openChat(BuildContext context, WidgetRef ref, String conversationId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatPage(conversationId: conversationId)),
    );
    ref.invalidate(conversationsProvider);
  }

  Future<void> _createConversation(
    BuildContext context,
    WidgetRef ref, {
    bool ephemeral = false,
  }) async {
    try {
      final conversation = await ref.read(conversationsProvider.notifier).create(ephemeral: ephemeral);
      if (!context.mounted) return;
      await _openChat(context, ref, conversation.id);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _showMenu(BuildContext context, WidgetRef ref, Conversation conversation) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: Icon(conversation.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(conversation.pinned ? '取消置顶' : '置顶'),
              onTap: () => Navigator.pop(sheetContext, 'pin'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;

    switch (action) {
      case 'rename':
        final controller = TextEditingController(text: conversation.title);
        final title = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '会话标题'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        controller.dispose();
        if (title != null && title.isNotEmpty) {
          await ref.read(conversationsProvider.notifier).rename(conversation.id, title);
        }
        return;
      case 'pin':
        await ref.read(conversationsProvider.notifier).togglePin(conversation);
        return;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除会话'),
            content: const Text('会话及其全部消息会被永久删除，确定吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await ref.read(conversationsProvider.notifier).remove(conversation.id);
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('鲸灵'),
        actions: [
          IconButton(
            tooltip: '临时对话',
            icon: const Icon(Icons.bolt_outlined),
            onPressed: () => _createConversation(context, ref, ephemeral: true),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: conversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('加载会话失败\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.read(conversationsProvider.notifier).refresh(),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        data: (items) => RefreshIndicator(
          onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
          child: items.isEmpty
              ? ListView(
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                    Icon(Icons.water, size: 48, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        '还没有对话\n点右下角「新对话」开始',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final conversation = items[index];
                    return ListTile(
                      leading: Icon(
                        conversation.ephemeral ? Icons.bolt_outlined : Icons.chat_bubble_outline,
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              conversation.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (conversation.pinned)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(Icons.push_pin, size: 14, color: theme.colorScheme.outline),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        conversation.preview.isEmpty ? '暂无消息' : conversation.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openChat(context, ref, conversation.id),
                      onLongPress: () => _showMenu(context, ref, conversation),
                    );
                  },
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createConversation(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('新对话'),
      ),
    );
  }
}
