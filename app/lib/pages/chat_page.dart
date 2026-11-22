import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../core/voice_session.dart';
import '../design/components/empty_state.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/models.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_menu.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    this.focusMessageId,
    this.initialText,
    this.initialFileIds,
    this.initialSearch,
    this.initialThinking,
    this.autoStartVoice = false,
  });

  final String conversationId;

  /// 全局搜索跳转:加载完成后滚动定位到这条消息(必须在活跃路径上)。
  final String? focusMessageId;

  /// 首页直达(v1.6.0):打开后自动把首条消息发出去、带上附件与开关,或直接进语音模式。
  final String? initialText;
  final List<String>? initialFileIds;
  final bool? initialSearch;
  final bool? initialThinking;
  final bool autoStartVoice;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _focusHandled = false;
  String? _highlightId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openWithInitial());
    });
  }

  /// 打开会话,并处理首页带过来的首条消息 / 开关 / 语音模式(v1.6.0)。
  Future<void> _openWithInitial() async {
    final chat = ref.read(chatProvider.notifier);
    await chat.open(widget.conversationId);
    if (!mounted) return;
    if (widget.initialSearch != null) chat.setSearchEnabled(widget.initialSearch!);
    if (widget.initialThinking != null) chat.setThinkingEnabled(widget.initialThinking!);
    final text = widget.initialText ?? '';
    final fileIds = widget.initialFileIds ?? const <String>[];
    if (text.isNotEmpty || fileIds.isNotEmpty) {
      await chat.send(text, fileIds: fileIds);
    }
    if (widget.autoStartVoice && mounted) {
      await ref.read(voiceSessionProvider.notifier).start();
    }
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

  /// 全局搜索跳转(HANDOFF-SEARCH §4.3):加载完成后定位到命中消息并短暂高亮。
  /// 消息不在活跃路径上(搜完又切了分支/已删除)就静默放弃,按原行为停底部。
  void _tryFocus(ChatState chat) {
    if (_focusHandled || widget.focusMessageId == null) return;
    if (chat.loading || chat.detail == null) return;
    _focusHandled = true;
    final targetId = widget.focusMessageId!;
    final onPath = chat.pathNodes.any((node) => node.id == targetId);
    final noAnimation = MediaQuery.disableAnimationsOf(context);
    if (!onPath) {
      _scrollToBottom();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = GlobalObjectKey(targetId).currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.3,
        duration: noAnimation ? Duration.zero : const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      if (noAnimation) return;
      setState(() => _highlightId = targetId);
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted && _highlightId == targetId) setState(() => _highlightId = null);
      });
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

  /// 从相册多选图片 → 逐张上传解析 → 附加到当前消息。
  Future<void> _pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickMultiImage(
        imageQuality: 85,
        maxWidth: 2200,
        limit: 6,
      );
      if (picked.isEmpty) return;
      var added = 0;
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        await ref.read(chatProvider.notifier).attachFile(name: file.name, bytes: bytes);
        added += 1;
      }
      if (!mounted || added == 0) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加 $added 张图片,可以补充问题后点发送')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择图片失败:$error')));
    }
  }

  /// 拍照提问:拍一张 → 上传解析 → 附加到当前消息(不自动发送)。
  Future<void> _takePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2200,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('照片内容为空,再拍一张？')));
        return;
      }
      await ref.read(chatProvider.notifier).attachFile(name: picked.name, bytes: bytes);
      if (!mounted) return;
      // 只附图,不自动发送:给用户补充文字的机会,确认后再点发送
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('照片已添加,可以补充问题后点发送;直接发送也可以')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍照失败:$error')));
    }
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
    // 带搜索定位来的页面不再自动回底部,避免和 ensureVisible 抢滚动
    if (widget.focusMessageId == null) _scrollToBottom();
    _tryFocus(chat);

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '更多',
            onPressed: () => _showChatMenu(chat),
            icon: const Icon(Icons.more_horiz),
          ),
          const SizedBox(width: AppSpace.xs),
        ],
      ),
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

  /// 对话页的「⋯」:重命名 / 置顶 / 删除(M8 §4.2;朗读已随声音回答移除)。
  Future<void> _showChatMenu(ChatState chat) async {
    final colors = colorsOf(context);
    final conversationId = chat.conversationId;
    final conversation = chat.detail?.conversation;
    if (conversationId == null) return;

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
              leading: Icon(conversation?.pinned == true ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(conversation?.pinned == true ? '取消置顶' : '置顶'),
              onTap: () => Navigator.pop(sheetContext, 'pin'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.danger),
              title: Text('删除', style: TextStyle(color: colors.danger)),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    final api = ref.read(apiProvider);
    switch (action) {
      case 'rename':
        final controller = TextEditingController(text: conversation?.title ?? '');
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
        if (title != null && title.isNotEmpty && api != null) {
          await api.patchConversation(conversationId, title: title);
          ref.invalidate(chatProvider);
          ref.invalidate(conversationsProvider);
        }
        return;
      case 'pin':
        if (api == null) return;
        await api.patchConversation(conversationId, pinned: !(conversation?.pinned ?? false));
        ref.invalidate(chatProvider);
        ref.invalidate(conversationsProvider);
        return;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除会话'),
            content: const Text('会话及其全部消息会被永久删除,确定吗?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true && api != null) {
          await api.deleteConversation(conversationId);
          ref.invalidate(conversationsProvider);
          if (mounted) Navigator.of(context).pop();
        }
        return;
    }
  }

  Widget _buildMessageList(ChatState chat, ThemeData theme) {
    final detail = chat.detail;
    final nodes = chat.pathNodes;
    final streaming = chat.streaming;
    final hasStreaming = chat.generating || streaming.hasContent;

    if (nodes.isEmpty && chat.pendingUserText == null && !hasStreaming) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        title: '和鲸灵说点什么吧',
        body: '长按消息可以复制、编辑或删除',
      );
    }

    final items = <Widget>[];
    for (final node in nodes) {
      final siblings = detail?.siblingsOf(node.id) ?? <MessageNode>[node];
      final index = siblings.indexWhere((item) => item.id == node.id);
      items.add(
        MessageBubble(
          key: GlobalObjectKey(node.id),
          node: node,
          position: index < 0 ? 1 : index + 1,
          count: siblings.length,
          interactive: !chat.generating,
          highlighted: node.id == _highlightId,
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

  /// 语音模式状态条:不遮住对话,只占输入框上方一行。
  Widget _buildVoiceStatus(VoiceSessionState voice, ThemeData theme) {
    final label = switch (voice.stage) {
      VoiceStage.listening => voice.heard ? '我在听,说完停顿一下' : '我在听…请说话',
      VoiceStage.recognizing => '正在识别…',
      VoiceStage.thinking => '正在思考…',
      VoiceStage.error => voice.error ?? '语音出错了',
      VoiceStage.idle => '',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            switch (voice.stage) {
              VoiceStage.listening => Icons.mic,
              VoiceStage.recognizing => Icons.graphic_eq,
              VoiceStage.thinking => Icons.psychology_outlined,
              _ => Icons.error_outline,
            },
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          if (voice.stage == VoiceStage.listening)
            SizedBox(
              width: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: voice.volume.clamp(0.0, 1.0),
                  minHeight: 4,
                  color: theme.colorScheme.error,
                  backgroundColor: theme.colorScheme.errorContainer,
                ),
              ),
            ),
          IconButton(
            tooltip: '退出语音模式',
            visualDensity: VisualDensity.compact,
            onPressed: () => ref.read(voiceSessionProvider.notifier).stop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
  /// Composer 上的开关:一行小字 + 状态点,选中用品牌色,不选中用灰。
  Widget _composerToggle(String label, bool on, ValueChanged<bool>? onChanged) {
    final colors = colorsOf(context);
    final type = typeOf(context);
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
      onTap: onChanged == null ? null : () => onChanged(!on),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs, horizontal: AppSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.check_circle : Icons.circle_outlined,
              size: 14,
              color: onChanged == null
                  ? colors.textMuted.withValues(alpha: 0.5)
                  : on
                      ? colors.accent
                      : colors.textMuted,
            ),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: type.meta.copyWith(
                color: on ? colors.accent : colors.textMuted,
                fontWeight: on ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Composer 上的圆钮:统一 44×44、filled 时用 accent。
  Widget _composerIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    bool filled = false,
  }) {
    final colors = colorsOf(context);
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: filled ? colors.accent : Colors.transparent,
        foregroundColor: filled ? scheme.onPrimary : colors.textSecondary,
        disabledBackgroundColor: filled ? colors.surfaceSunken : Colors.transparent,
        disabledForegroundColor: colors.textMuted,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 20),
    );
  }

  /// 语音模式开/关(v1.6.1:入口在输入框右侧的麦克风)。
  Future<void> _toggleVoiceMode(VoiceSessionState voice) async {
    if (voice.active) {
      await ref.read(voiceSessionProvider.notifier).stop();
    } else {
      await ref.read(voiceSessionProvider.notifier).start();
    }
  }

  /// 「＋」:拍照 / 相册 / 文件(语音已挪到输入框右侧)。
  Future<void> _showInputActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(sheetContext, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('相册'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('文件'),
              onTap: () => Navigator.pop(sheetContext, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'photo':
        await _takePhoto();
        return;
      case 'gallery':
        await _pickFromGallery();
        return;
      case 'file':
        await _pickFile();
        return;
    }
  }

  Widget _buildComposer(ChatState chat, ThemeData theme) {
    final voice = ref.watch(voiceSessionProvider);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.sm, AppSpace.page, AppSpace.sm),
        decoration: BoxDecoration(
          color: colorsOf(context).bg,
          border: Border(top: BorderSide(color: colorsOf(context).border)),
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
            // 两个开关压成一行小字,不再用整块 chip 抢注意力(M8 §4.3)
            Row(
              children: [
                _composerToggle(
                  '联网搜索',
                  chat.searchEnabled,
                  chat.generating ? null : (value) => ref.read(chatProvider.notifier).setSearchEnabled(value),
                ),
                const SizedBox(width: AppSpace.lg),
                _composerToggle(
                  '深度思考',
                  chat.thinkingEnabled,
                  chat.generating ? null : (value) => ref.read(chatProvider.notifier).setThinkingEnabled(value),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 6),
            if (voice.active) _buildVoiceStatus(voice, theme),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _composerIconButton(
                  icon: Icons.add,
                  tooltip: '拍照 / 相册 / 文件',
                  onPressed: chat.generating ? null : () => _showInputActions(),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    enabled: !chat.generating,
                    onChanged: (_) => setState(() {}),
                    style: typeOf(context).body,
                    decoration: InputDecoration(
                      hintText: chat.generating ? '鲸灵正在回答…' : '给鲸灵发消息…',
                      // Web 语音输入 v1 不做(录音管道依赖移动端临时文件),隐藏麦克风
                      suffixIcon: kIsWeb
                          ? null
                          : IconButton(
                              tooltip: voice.active ? '退出语音模式' : '语音模式',
                              onPressed: () => _toggleVoiceMode(voice),
                              icon: Icon(
                                voice.active ? Icons.mic : Icons.mic_none,
                                size: 20,
                                color: voice.active ? colorsOf(context).accent : colorsOf(context).textMuted,
                              ),
                            ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 40),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                if (chat.generating)
                  _composerIconButton(
                    icon: Icons.stop,
                    tooltip: '停止生成',
                    filled: true,
                    onPressed: () => ref.read(chatProvider.notifier).stop(),
                  )
                else
                  _composerIconButton(
                    icon: Icons.arrow_upward,
                    tooltip: '发送',
                    filled: true,
                    onPressed: _input.text.trim().isEmpty ? null : _send,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}



