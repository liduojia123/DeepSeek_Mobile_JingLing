/// SSE 行解析器。
///
/// 必须处理:CRLF、事件块跨 chunk 切断、多行 data、`:` 开头的注释行(服务端心跳)。
/// 规格见 docs/DESIGN.md §5.1。
library;

class SseEvent {
  const SseEvent({required this.event, required this.data});

  final String event;
  final String data;
}

class SseStreamParser {
  String _buffer = '';
  String _eventName = '';
  final List<String> _dataLines = [];

  /// 喂入任意切分的文本块,返回本次凑齐的完整事件。
  Iterable<SseEvent> addChunk(String chunk) {
    _buffer += chunk;
    final completed = <SseEvent>[];
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline < 0) break;
      var line = _buffer.substring(0, newline);
      _buffer = _buffer.substring(newline + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final event = _handleLine(line);
      if (event != null) completed.add(event);
    }
    return completed;
  }

  /// 流结束时调用:数据行不以空行收尾时也要把最后一个事件吐出来。
  Iterable<SseEvent> flush() {
    if (_buffer.isNotEmpty) {
      var line = _buffer;
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _buffer = '';
      _handleLine(line);
    }
    final event = _dispatch();
    return event == null ? const [] : [event];
  }

  SseEvent? _handleLine(String line) {
    if (line.isEmpty) return _dispatch();
    if (line.startsWith(':')) return null; // 心跳/注释
    if (line.startsWith('event:')) {
      _eventName = _valueAfterColon(line);
      return null;
    }
    if (line.startsWith('data:')) {
      _dataLines.add(_valueAfterColon(line));
      return null;
    }
    return null;
  }

  String _valueAfterColon(String line) {
    final value = line.substring(line.indexOf(':') + 1);
    return value.startsWith(' ') ? value.substring(1) : value;
  }

  SseEvent? _dispatch() {
    if (_eventName.isEmpty && _dataLines.isEmpty) return null;
    final event = SseEvent(event: _eventName, data: _dataLines.join('\n'));
    _eventName = '';
    _dataLines.clear();
    if (event.data.trim().isEmpty) return null;
    return event;
  }
}
