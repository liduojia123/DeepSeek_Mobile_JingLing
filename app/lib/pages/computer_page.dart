import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/harness_providers.dart';
import '../models/harness.dart';
import '../widgets/thinking_block.dart';

/// 电脑页:查看电脑上的 dsh 工作区/会话,远程派任务、看实时输出、逐条确认工具调用。
class ComputerPage extends ConsumerStatefulWidget {
  const ComputerPage({super.key});

  @override
  ConsumerState<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends ConsumerState<ComputerPage> {
  final TextEditingController _prompt = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(harnessProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    _prompt.clear();
    await ref.read(harnessProvider.notifier).startTask(text);
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(harnessProvider);
    final theme = Theme.of(context);

    ref.listen<HarnessState>(harnessProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next.error!)));
        ref.read(harnessProvider.notifier).clearError();
      }
      _scrollToBottom();
    });

    // 任务视图下,系统返回键先回到会话列表,而不是直接退出电脑页
    return PopScope(
      canPop: !state.viewingTask,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && state.viewingTask) ref.read(harnessProvider.notifier).showList();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: state.viewingTask
              ? IconButton(
                  tooltip: '会话列表',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => ref.read(harnessProvider.notifier).showList(),
                )
              : null,
          title: const Text('电脑'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: () => ref.read(harnessProvider.notifier).load(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            _buildNodeBar(state, theme),
            Expanded(
              child: state.viewingTask ? _buildTaskView(state, theme) : _buildBody(state, theme),
            ),
            _buildConfirmCard(state, theme),
            _buildPermissionBar(state, theme),
            _buildComposer(state, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeBar(HarnessState state, ThemeData theme) {
    final node = state.onlineNode;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          Icon(
            node?.online == true ? Icons.desktop_windows : Icons.desktop_access_disabled,
            size: 18,
            color: node?.online == true ? theme.colorScheme.primary : theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node == null
                  ? '未连接电脑'
                  : '${node.name} · ${node.online ? '在线' : '离线'}',
              style: theme.textTheme.labelMedium,
            ),
          ),
          if (state.running)
            Text('执行中…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _buildBody(HarnessState state, ThemeData theme) {
    if (state.loading) return const Center(child: CircularProgressIndicator());


    final banner = state.taskId == null ? const SizedBox.shrink() : _buildTaskBanner(state, theme);
    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.sessions.isEmpty) {
      return Column(
        children: [
          banner,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '电脑上没有可用的 dsh 会话。\n先在电脑上打开一个会话,再回来刷新。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final selectedId = state.selectedSessionId;
    final groupedIds = <String>{
      for (final workspace in snapshot.workspaces) ...workspace.sessionIds,
    };
    final ungrouped =
        snapshot.sessions.where((session) => !groupedIds.contains(session.id)).toList(growable: false);
    return Column(
      children: [
        banner,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
        for (final workspace in snapshot.workspaces)
          ExpansionTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(workspace.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(workspace.path, maxLines: 1, overflow: TextOverflow.ellipsis),
            initiallyExpanded: workspace.sessionIds.contains(selectedId),
            children: [
              for (final session in snapshot.sessions)
                if (workspace.sessionIds.contains(session.id))
                  _sessionTile(session, session.id == selectedId),
            ],
          ),
        if (ungrouped.isNotEmpty)
          ExpansionTile(
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('未加入工作区的会话'),
            subtitle: Text('${ungrouped.length} 个(常见于刚新建的会话)'),
            initiallyExpanded: ungrouped.any((session) => session.id == selectedId),
            children: [
              for (final session in ungrouped)
                _sessionTile(session, session.id == selectedId),
            ],
          ),
            ],
          ),
        ),
      ],
    );
  }

  /// 列表顶部的「任务进行中」横幅:点击回到任务视图(任务不会因为返回列表而中断)。
  Widget _buildTaskBanner(HarnessState state, ThemeData theme) {
    final running = state.running;
    return Material(
      color: running
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: () => ref.read(harnessProvider.notifier).openTask(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (running)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.check_circle_outline, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  running ? '电脑正在执行任务…点击查看' : '上一个任务已结束 · 点击查看',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Text('查看', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }

  /// 把毫秒时间戳/ISO 字符串显示成 月-日 时:分。
  String _formatTime(String raw) {
    final value = int.tryParse(raw);
    final time = value == null
        ? DateTime.tryParse(raw)
        : DateTime.fromMillisecondsSinceEpoch(value);
    if (time == null) return '';
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _sessionTile(HarnessSession session, bool selected) {
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
      ),
      title: Text(session.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if ((session.cwd ?? '').isNotEmpty) session.cwd!,
          if (session.live) '运行中',
          if (session.createdAt != null) _formatTime(session.createdAt!),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => ref.read(harnessProvider.notifier).selectSession(session.id),
    );
  }

  Widget _buildTaskView(HarnessState state, ThemeData theme) {
    final selected = state.selectedSession;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      children: [
        if (selected != null)
          Text(
            '会话:${selected.displayName}',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
          ),
        const SizedBox(height: 8),
        if (state.thinking.trim().isNotEmpty)
          ThinkingBlock(text: state.thinking, streaming: state.running && state.output.isEmpty),
        for (final event in state.toolEvents)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.build_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '工具调用:${(event.payload['tool'] as String?) ?? 'tool'}',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        if (state.output.isNotEmpty)
          SelectableText(state.output, style: theme.textTheme.bodyMedium),
        if (state.running)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('电脑正在执行…', style: theme.textTheme.labelSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => ref.read(harnessProvider.notifier).stop(),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('停止'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildConfirmCard(HarnessState state, ThemeData theme) {
    final confirm = state.confirm;
    if (confirm == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '电脑请求执行敏感操作(${state.confirmRemaining}s 后自动拒绝)',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('工具:${confirm.tool}', style: theme.textTheme.bodySmall),
          if (confirm.reason.isNotEmpty)
            Text('理由:${confirm.reason}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => ref.read(harnessProvider.notifier).answerConfirm(true),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('批准'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => ref.read(harnessProvider.notifier).answerConfirm(false),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('拒绝'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 远程会话的沙箱权限:决定「手机批准后」操作能否真正执行。
  Widget _buildPermissionBar(HarnessState state, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Text('权限', style: theme.textTheme.labelSmall),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('沙箱内', style: TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            selected: state.permissionMode == 'workspace-write',
            onSelected: state.running
                ? null
                : (_) => ref.read(harnessProvider.notifier).setPermissionMode('workspace-write'),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('完全访问', style: TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            selected: state.permissionMode == 'danger-full-access',
            onSelected: state.running
                ? null
                : (_) => ref.read(harnessProvider.notifier).setPermissionMode('danger-full-access'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.permissionMode == 'danger-full-access'
                  ? '可写工作区外文件(仍需逐条确认)'
                  : '越界操作会被 dsh 沙箱拒绝',
              maxLines: 2,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(HarnessState state, ThemeData theme) {
    final canSend = !state.running && state.selectedSessionId != null;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _prompt,
                minLines: 1,
                maxLines: 4,
                enabled: canSend,
                decoration: InputDecoration(
                  hintText: state.running
                      ? '电脑正在执行…'
                      : state.selectedSessionId == null
                          ? '先选一个会话'
                          : '给电脑上的 dsh 派任务…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '派任务',
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
