import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../models/models.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_menu.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatProvider.notifier).open(widget.conversationId);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final files = ref.read(chatProvider).files;
    if (text.isEmpty && files.isEmpty) return;
    _input.clear();
    await ref.read(chatProvider.notifier).send(
          text,
          fileIds: files.map((file) => file.id).toList(growable: false),
        );
  }

  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const [
          'pdf', 'doc', 'docx', 'ppt', 'pptx',
          'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'tif', 'tiff',
          'txt', 'md', 'csv', 'json', 'xlsx', 'xls', 'epub',
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件内容为空')));
        return;
      }
      await ref.read(chatProvider.notifier).attachFile(name: file.name, bytes: bytes);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择文件失败:$error')));
    }
  }

  Future<void> _switchToSibling(List<MessageNode> siblings, int index) async {
    if (index < 0 || index >= siblings.length) return;
    await ref.read(chatProvider.notifier).switchBranch(siblings[index].id);
  }

  Future<void> _openMenu(MessageNode node) async {
    final action = await showMessageMenu(
      context,
      isUser: node.isUser,
      canRegenerate: node.isAssistant && node.parentId != null,
      canEdit: node.isUser,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case MessageMenuAction.copy:
        await Clipboard.setData(ClipboardData(text: node.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
      case MessageMenuAction.edit:
        final editor = TextEditingController(text: node.text);
        final result = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('编辑并重新发送'),
            content: TextField(
              controller: editor,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, editor.text.trim()),
                child: const Text('发送'),
              ),
            ],
          ),
        );
        editor.dispose();
        if (result != null && result.isNotEmpty) {
          await ref.read(chatProvider.notifier).editResend(node, result);
        }
      case MessageMenuAction.regenerate:
        await ref.read(chatProvider.notifier).regenerate(node);
      case MessageMenuAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除这条消息？'),
            content: const Text('该消息之后的整条分支都会一起删除，无法恢复。'),
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
          await ref.read(chatProvider.notifier).deleteMessage(node.id);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final theme = Theme.of(context);

    ref.listen<ChatState>(chatProvider, (previous, next) {
      final message = next.error ?? next.info;
      if (message != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
        ref.read(chatProvider.notifier).clearBanner();
      }
    });

    final title = chat.title ?? chat.detail?.conversation.displayTitle ?? '对话';
    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Expanded(
            child: chat.loading
                ? const Center(child: CircularProgressIndicator())
                : _buildMessageList(chat, theme),
          ),
          _buildComposer(chat, theme),
        ],
      ),
    );
  }

  Widget _buildMessageList(ChatState chat, ThemeData theme) {
    final detail = chat.detail;
    final nodes = chat.pathNodes;
    final streaming = chat.streaming;
    final hasStreaming = chat.generating || streaming.hasContent;

    if (nodes.isEmpty && chat.pendingUserText == null && !hasStreaming) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '和鲸灵说点什么吧\n长按消息可以复制、编辑或删除',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final items = <Widget>[];
    for (final node in nodes) {
      final siblings = detail?.siblingsOf(node.id) ?? <MessageNode>[node];
      final index = siblings.indexWhere((item) => item.id == node.id);
      items.add(
        MessageBubble(
          key: ValueKey(node.id),
          node: node,
          position: index < 0 ? 1 : index + 1,
          count: siblings.length,
          interactive: !chat.generating,
          onBranchSelected: (selected) => _switchToSibling(siblings, selected),
          onLongPress: () => _openMenu(node),
        ),
      );
    }
    if (chat.pendingUserText != null) {
      items.add(PendingUserBubble(text: chat.pendingUserText!));
    }
    if (chat.toolStatus != null) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text(
                chat.toolStatus!,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    if (hasStreaming) {
      items.add(StreamingAnswerBubble(answer: streaming, generating: chat.generating));
    }

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: items,
    );
  }

  Widget _buildComposer(ChatState chat, ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (chat.files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final file in chat.files)
                      InputChip(
                        avatar: const Icon(Icons.description_outlined, size: 16),
                        label: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onDeleted: () => ref.read(chatProvider.notifier).removeFile(file.id),
                      ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '添加文件',
                  onPressed: chat.generating ? null : _pickFile,
                  icon: const Icon(Icons.attach_file),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    enabled: !chat.generating,
                    decoration: InputDecoration(
                      hintText: chat.generating ? '鲸灵正在回答…' : '给鲸灵发消息…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                chat.generating
                    ? IconButton.filledTonal(
                        tooltip: '停止生成',
                        onPressed: () => ref.read(chatProvider.notifier).stop(),
                        icon: const Icon(Icons.stop),
                      )
                    : IconButton.filled(
                        tooltip: '发送',
                        onPressed: _send,
                        icon: const Icon(Icons.arrow_upward),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
