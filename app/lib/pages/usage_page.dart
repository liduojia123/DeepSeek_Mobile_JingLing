import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../models/models.dart';

/// M5 用量看板:今日费用/预算、近 7 天趋势、按类型拆分、工具调用次数、Top 会话。
class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  UsageSummary? _usage;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final usage = await api.usage(days: 7);
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  static const _kindLabels = <String, String>{
    'model': '模型对话',
    'search': '联网搜索',
    'fetch': '网页抓取',
    'ocr': '文档解析',
    'asr': '语音识别',
    'tts': '语音合成',
  };

  static const _kindUnits = <String, String>{
    'model': 'tokens',
    'search': '次',
    'fetch': '次',
    'ocr': '页',
    'asr': '秒',
    'tts': '字符',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('用量看板'),
        actions: [
          IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildTodayCard(_usage!, theme),
                      const SizedBox(height: 16),
                      _buildTrend(_usage!, theme),
                      const SizedBox(height: 16),
                      _buildByKind(_usage!, theme),
                      const SizedBox(height: 16),
                      _buildTopConversations(_usage!, theme),
                    ],
                  ),
                ),
    );
  }

  Widget _buildTodayCard(UsageSummary usage, ThemeData theme) {
    final hasBudget = usage.budgetDaily > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('¥${usage.todayCost.toStringAsFixed(4)}', style: theme.textTheme.headlineMedium),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${usage.todayTokensIn + usage.todayTokensOut} tokens · 工具 ${usage.toolCalls} 次',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (hasBudget) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (usage.budgetUsedPercent / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  color: usage.budgetExceeded ? theme.colorScheme.error : theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                usage.budgetExceeded
                    ? '今日预算已用完(¥${usage.budgetUsedToday.toStringAsFixed(2)} / ¥${usage.budgetDaily.toStringAsFixed(2)}),对话已被熔断'
                    : '今日已用 ¥${usage.budgetUsedToday.toStringAsFixed(2)} / 预算 ¥${usage.budgetDaily.toStringAsFixed(2)}'
                        '${usage.budgetRemaining == null ? '' : ' · 剩余 ¥${usage.budgetRemaining!.toStringAsFixed(2)}'}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: usage.budgetExceeded ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrend(UsageSummary usage, ThemeData theme) {
    final days = usage.days;
    final maxCost = days.fold<double>(0.0001, (max, day) => day.cost > max ? day.cost : max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('近 7 天', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: days.isEmpty
                  ? Center(child: Text('暂无数据', style: theme.textTheme.bodySmall))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final day in days)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 3),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    day.cost > 0 ? day.cost.toStringAsFixed(3) : '',
                                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    height: (day.cost / maxCost) * 80 + 2,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary.withValues(alpha: 0.7),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(day.date.substring(5), style: theme.textTheme.labelSmall?.copyWith(fontSize: 9)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildByKind(UsageSummary usage, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('按类型', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (usage.byKind.isEmpty) Text('暂无数据', style: theme.textTheme.bodySmall),
            for (final row in usage.byKind)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_kindLabels[row.kind] ?? row.kind),
                subtitle: Text(
                  '${row.calls} 次 · ${row.quantity.toStringAsFixed(row.kind == 'model' ? 0 : 2)} '
                  '${_kindUnits[row.kind] ?? ''}',
                ),
                trailing: Text('¥${row.cost.toStringAsFixed(4)}', style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopConversations(UsageSummary usage, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('花费最多的会话', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (usage.topConversations.isEmpty) Text('暂无数据', style: theme.textTheme.bodySmall),
            for (final row in usage.topConversations)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.chat_bubble_outline, size: 18),
                title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${row.calls} 次调用'),
                trailing: Text('¥${row.cost.toStringAsFixed(4)}', style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}
