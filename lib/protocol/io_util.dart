import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 带缓冲的精确读，对接 Python `recv_exact` / `recv`。
/// 块队列 + 偏移，读出时不再把剩余字节拷回缓冲。
class SocketReader {
  SocketReader(this._sock) {
    _sub = _sock.listen(
      (data) {
        if (data.isEmpty) return;
        final bytes = Uint8List.fromList(data);
        _chunks.add(bytes);
        _length += bytes.length;
        _notify();
      },
      onError: (Object e) {
        _error = e;
        _notify();
      },
      onDone: () {
        _done = true;
        _notify();
      },
      cancelOnError: false,
    );
  }

  final Socket _sock;
  final Queue<Uint8List> _chunks = Queue();
  int _head = 0;
  int _length = 0;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _gate;
  Object? _error;
  bool _done = false;

  void _notify() {
    final g = _gate;
    if (g != null && !g.isCompleted) g.complete();
  }

  Future<void> _waitData() async {
    if (_length > 0 || _done || _error != null) return;
    _gate = Completer<void>();
    await _gate!.future;
    _gate = null;
  }

  Future<Uint8List?> readExact(int n) async {
    if (n <= 0) return Uint8List(0);
    while (_length < n) {
      if (_error != null) throw _error!;
      if (_done) return null;
      await _waitData();
    }
    return _take(n);
  }

  Future<Uint8List?> readUpTo(int n) async {
    if (n <= 0) return Uint8List(0);
    while (_length == 0) {
      if (_error != null) throw _error!;
      if (_done) return null;
      await _waitData();
    }
    return _take(min(_length, n));
  }

  Uint8List _take(int n) {
    final first = _chunks.first;
    final avail = first.length - _head;
    if (avail >= n) {
      final got = Uint8List.sublistView(first, _head, _head + n);
      _head += n;
      _length -= n;
      if (_head == first.length) {
        _chunks.removeFirst();
        _head = 0;
      }
      return got;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final chunk = _chunks.first;
      final have = chunk.length - _head;
      final take = have < n - filled ? have : n - filled;
      out.setRange(filled, filled + take, chunk, _head);
      filled += take;
      _head += take;
      _length -= take;
      if (_head == chunk.length) {
        _chunks.removeFirst();
        _head = 0;
      }
    }
    return out;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}

void writeUint32BE(BytesBuilder b, int v) {
  b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
}

void writeUint64BE(BytesBuilder b, int v) {
  writeUint32BE(b, (v >> 32) & 0xffffffff);
  writeUint32BE(b, v & 0xffffffff);
}

int readUint32BE(Uint8List b, [int o = 0]) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int readUint64BE(Uint8List b, [int o = 0]) =>
    (readUint32BE(b, o) << 32) | readUint32BE(b, o + 4);

Future<void> sendAll(Socket sock, List<int> data) async {
  sock.add(data);
  await sock.flush();
}
