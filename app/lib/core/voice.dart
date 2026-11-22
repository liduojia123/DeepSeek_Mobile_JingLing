import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// M4 语音输入:录音(16kHz 单声道 WAV,DeepSeek ASR 要求)。
/// v1.7.0 起回答只出文字,TTS 播放已移除。
class VoiceService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordPath;

  bool get isRecording => _recordPath != null;

  /// 录音音量流(dBFS,约 -60..0),用于静音检测自动断句。
  Stream<Amplitude> amplitudeStream([Duration interval = const Duration(milliseconds: 100)]) =>
      _recorder.onAmplitudeChanged(interval);

  /// 开始录音;返回 false 表示麦克风不可用/被拒绝。
  Future<bool> startRecording() async {
    if (await _recorder.hasPermission() == false) return false;
    final dir = await getTemporaryDirectory();
    _recordPath = '${dir.path}/jingling-${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _recordPath!,
    );
    return true;
  }

  /// 结束录音并返回 wav 字节;没有录音返回 null。
  Future<Uint8List?> stopRecording() async {
    final path = await _recorder.stop();
    final target = path ?? _recordPath;
    _recordPath = null;
    if (target == null) return null;
    final file = File(target);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // 临时文件清理失败不影响使用
    }
    return bytes.isEmpty ? null : bytes;
  }

  /// 放弃当前录音(手指上滑取消)。
  Future<void> cancelRecording() async {
    await _recorder.cancel();
    _recordPath = null;
  }

  Future<void> dispose() async {
    await _recorder.dispose();
  }
}
