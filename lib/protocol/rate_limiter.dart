import 'dart:async';

/// 令牌桶限速，单位 MB/s；0 = 不限。
class RateLimiter {
  RateLimiter([this.maxMbps = 0]);

  double maxMbps;
  double _tokens = 0;
  double _bucket = 0;
  DateTime _last = DateTime.now();

  void updateLimit(double mbps) {
    maxMbps = mbps;
    if (mbps > 0) {
      _bucket = mbps * 1024 * 1024;
      _tokens = _tokens.clamp(0, _bucket);
      if (_tokens == 0) _tokens = _bucket;
    } else {
      _bucket = 0;
      _tokens = 0;
    }
  }

  Future<void> consume(int bytes) async {
    if (maxMbps <= 0 || bytes <= 0) return;
    final rate = maxMbps * 1024 * 1024;
    while (true) {
      final now = DateTime.now();
      final elapsed = now.difference(_last).inMicroseconds / 1e6;
      if (elapsed > 0) {
        _tokens = (_tokens + elapsed * rate).clamp(0, _bucket);
        _last = now;
      }
      if (_tokens >= bytes) {
        _tokens -= bytes;
        return;
      }
      final wait = ((bytes - _tokens) / rate).clamp(0.0, 0.05);
      await Future<void>.delayed(Duration(milliseconds: (wait * 1000).ceil()));
    }
  }
}
