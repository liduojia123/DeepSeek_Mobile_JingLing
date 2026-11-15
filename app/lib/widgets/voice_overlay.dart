import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/voice_session.dart';

/// 语音模式全屏层:免按住连续对话。
/// 聆听时圆钮随音量脉冲;播报时点圆钮可打断;右上角退出。
class VoiceOverlay extends ConsumerStatefulWidget {
  const VoiceOverlay({super.key});

  @override
  ConsumerState<VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends ConsumerState<VoiceOverlay> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(voiceSessionProvider.notifier).start();
    });
  }

  Future<void> _close() async {
    await ref.read(voiceSessionProvider.notifier).stop();
    if (mounted) Navigator.of(context).pop();
  }

  static const _stageLabels = <VoiceStage, String>{
    VoiceStage.idle: '已退出语音模式',
    VoiceStage.listening: '我在听…',
    VoiceStage.recognizing: '正在识别…',
    VoiceStage.thinking: '正在思考…',
    VoiceStage.speaking: '正在回答(点圆钮可打断)',
    VoiceStage.error: '出错了',
  };

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(voiceSessionProvider);
    final theme = Theme.of(context);
    final isSpeaking = state.stage == VoiceStage.speaking;
    final pulse = state.stage == VoiceStage.listening ? 1 + state.volume * 0.25 : 1.0;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  tooltip: '退出语音模式',
                  onPressed: _close,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
            const Spacer(),
            AnimatedScale(
              scale: pulse,
              duration: const Duration(milliseconds: 120),
              child: GestureDetector(
                onTap: () {
                  if (isSpeaking) {
                    ref.read(voiceSessionProvider.notifier).interrupt();
                  }
                },
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.85),
                        theme.colorScheme.primary.withValues(alpha: 0.55),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.35),
                        blurRadius: 40 * (1 + state.volume),
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Icon(
                    switch (state.stage) {
                      VoiceStage.listening => Icons.mic,
                      VoiceStage.recognizing => Icons.graphic_eq,
                      VoiceStage.thinking => Icons.psychology_outlined,
                      VoiceStage.speaking => Icons.volume_up,
                      _ => Icons.mic_off,
                    },
                    size: 72,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _stageLabels[state.stage] ?? '',
              style: theme.textTheme.titleMedium,
            ),
            if (state.round > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '第 ${state.round} 轮对话',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            const SizedBox(height: 20),
            if (state.transcript != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  '你说:${state.transcript}',
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                child: Text(
                  state.error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Text(
                '免按住:说完停顿一下会自动发送;回答播报完后自动继续听。\n说「退出」或按右上角关闭。',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
