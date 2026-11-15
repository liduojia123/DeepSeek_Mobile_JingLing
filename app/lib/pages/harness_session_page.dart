import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/harness_session_provider.dart';
import '../models/harness_stream.dart';
import '../widgets/markdown_view.dart';
import '../widgets/thinking_block.dart';

/// 会话页:手机与电脑共用同一个 dsh 会话。
/// 历史与实时渲染同一套时间线;跑的时候输入 = 插话,空闲时输入 = 追加一轮。
class HarnessSessionPage extends ConsumerStatefulWidget {
  const HarnessSessionPage({super.key, required this.sessionId, this.title = ''});

  final String sessionId;
  final String title;

  @override
  ConsumerState<HarnessSessionPage> createState() => _HarnessSessionPageState();
}

class _HarnessSessionPageState extends ConsumerState<HarnessSessionPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  HarnessSessionController? _controller;
  int _lastRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller = ref.read(harnessSessionProvider.notifier);
      _controller!.open(widget.sessionId, title: widget.title);
    });
  }

  @override
  void dispose() {
    // dispose 里不能再碰 ref:controller 在 initState 后缓存下来
    _controller?.leave();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await ref.read(harnessSessionProvider.notifier).send(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(harnessSessionProvider);
    final timeline = state.view;

    if (state.revision != _lastRevision) {
      _lastRevision = state.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title.isEmpty ? '会话' : widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              state.running ? '电脑上正在跑' : (state.connecting ? '连接中…' : '空闲'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: state.running ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '权限:${_permissionLabel(state.permission)}',
            icon: Icon(
              state.permission == 'danger-full-access' ? Icons.lock_open : Icons.lock_outline,
            ),
            onPressed: () => _pickPermission(state.permission),
          ),
          if (state.running)
            IconButton(
              tooltip: '停止电脑上的当前回合',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => ref.read(harnessSessionProvider.notifier).stop(),
            ),
        ],
      ),
      body: Column(
        children: [
          if (state.error != null)
            Material(
              color: theme.colorScheme.errorContainer,
              child: InkWell(
                onTap: () => ref.read(harnessSessionProvider.notifier).clearError(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.error!,
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                      Text('知道了', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: timeline.isEmpty && timeline.pendingInput == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        state.connecting
                            ? '正在和电脑上的会话建立连接…'
                            : '这个会话还没有内容。\n在下面输入,电脑上的 dsh 会接着这个会话继续。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      for (final entry in timeline.entries) _entry(entry, theme),
                      if (timeline.pendingInput != null) _pendingBubble(timeline.pendingInput!, theme),
                      if (timeline.draftText.isNotEmpty || timeline.draftReasoning.isNotEmpty)
                        _draft(timeline, theme),
                    ],
                  ),
          ),
          _composer(theme, state),
        ],
      ),
    );
  }

  static String _permissionLabel(String? permission) {
    if (permission == 'danger-full-access') return '完全访问';
    if (permission == 'workspace-write') return '沙箱内';
    return permission == null || permission.isEmpty ? '未知' : permission;
  }

  Future<void> _pickPermission(String? current) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('会话权限'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'workspace-write'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('沙箱内(默认)'),
              subtitle: const Text('只能在会话目录里读写'),
              trailing: current == 'workspace-write' ? const Icon(Icons.check) : null,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'danger-full-access'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_open),
              title: const Text('完全访问'),
              subtitle: const Text('可越出目录;本地用户已授权时才用'),
              trailing: current == 'danger-full-access' ? const Icon(Icons.check) : null,
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(harnessSessionProvider.notifier).setPermission(picked);
  }

  Widget _entry(HarnessEntry entry, ThemeData theme) => switch (entry) {
        HarnessUserEntry() => _userBubble(entry, theme),
        HarnessAssistantEntry() => _assistantBlock(entry, theme),
      };

  Widget _userBubble(HarnessUserEntry entry, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (entry.fromPhone)
          Padding(
            padding: const EdgeInsets.only(bottom: 2, right: 4),
            child: Text('手机', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(entry.text, style: theme.textTheme.bodyLarge),
        ),
      ],
    );
  }

  Widget _pendingBubble(String text, ThemeData theme) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: theme.textTheme.bodyLarge),
            const SizedBox(width: 8),
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
      ),
    );
  }

  Widget _assistantBlock(HarnessAssistantEntry entry, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.reasoning.trim().isNotEmpty) ThinkingBlock(text: entry.reasoning),
        for (final tool in entry.tools) _toolCard(tool, theme),
        if (entry.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ChatMarkdown(data: entry.text),
          ),
        if (entry.interrupted)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '（这一轮被中断,已保留部分内容）',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _draft(HarnessTimeline timeline, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (timeline.draftReasoning.isNotEmpty)
          ThinkingBlock(text: timeline.draftReasoning, streaming: true),
        if (timeline.draftText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ChatMarkdown(data: timeline.draftText),
          ),
        Row(
          children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('电脑上正在输出…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ],
    );
  }

  Widget _toolCard(HarnessToolCall tool, ThemeData theme) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          tool.isError ? Icons.error_outline : (tool.done ? Icons.check_circle_outline : Icons.build_circle_outlined),
          size: 18,
          color: tool.isError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(tool.name, style: theme.textTheme.labelMedium),
        subtitle: Text(
          tool.done ? (tool.isError ? '执行失败' : '已完成') : '执行中…',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
        ),
        children: [
          if (tool.arguments.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tool.arguments,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          if (tool.result != null && tool.result!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tool.result!,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _composer(ThemeData theme, HarnessSessionState state) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: state.running ? '插话:改变当前这轮的方向' : '接着说,电脑上的会话会继续',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: state.sending ? null : _send,
              child: Text(state.running ? '插话' : '发送'),
            ),
          ],
        ),
      ),
    );
  }
}
