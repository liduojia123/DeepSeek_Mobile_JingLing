import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// M4 语音:录音(16kHz 单声道 WAV,DeepSeek ASR 要求)+ 播放(TTS 返回的 wav)。
class VoiceService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _recordPath;
  bool _playing = false;

  VoiceService() {
    _player.onPlayerComplete.listen((_) => _playing = false);
  }

  bool get isRecording => _recordPath != null;
  bool get isPlaying => _playing;

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

  Completer<void>? _playDone;

  /// 播放 TTS 音频;返回的 Future 在播完或被打断时完成。
  Future<void> play(Uint8List wav) async {
    await _player.stop();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/jingling-tts-${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(wav, flush: true);
    final done = Completer<void>();
    _playDone = done;
    _playing = true;
    _player.onPlayerComplete.listen((_) {
      _playing = false;
      if (!done.isCompleted) done.complete();
    });
    await _player.play(DeviceFileSource(path));
    await done.future;
  }

  /// 停止播放(打断)。
  Future<void> stop() async {
    _playing = false;
    final done = _playDone;
    _playDone = null;
    if (done != null && !done.isCompleted) done.complete();
    await _player.stop();
  }

  Future<void> dispose() async {
    await _recorder.dispose();
    await _player.dispose();
  }
}
