part of 'relay_session.dart';

extension on RelaySessionNotifier {
  Future<NostrEvent> _publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = _now().add(timeout);
    final context = _contextGeneration;
    var generation = _connectionGeneration;
    if (_rateLimitGate.isActive) await _rateLimitGate.wait();
    // A send right after the app resumes, or during a network blip, lands
    // while the socket is re-authenticating. Wait for that reconnect rather
    // than fail, but never let the event cross into another community.
    if (_isActiveConnection(generation) && !_socketConnected) {
      await _awaitConnected(deadline.difference(_now()));
      if (context == _contextGeneration) generation = _connectionGeneration;
    }
    if (context != _contextGeneration) {
      throw CommunityChangedError(
        'Message delivery cancelled because the active community changed',
      );
    }
    if (!_isActiveConnection(generation) || !_socketConnected) {
      throw StateError('Not connected. Check your connection and try again.');
    }

    final completer = Completer<NostrEvent>();

    // The whole send, reconnect wait included, stays within [timeout]; the
    // ack still gets a short floor so a late reconnect isn't failed at once.
    final left = deadline.difference(_now());
    const ackFloor = Duration(seconds: 2);
    final timer = Timer(left < ackFloor ? ackFloor : left, () {
      final pending = _pendingEvents.remove(event.id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          TimeoutException(
            'Event ${event.id} not acknowledged within $timeout',
          ),
        );
      }
    });

    _pendingEvents[event.id] = _PendingEvent(
      completer: completer,
      timeout: timer,
    );

    _socket?.send(['EVENT', event.toJson()]);
    return completer.future;
  }

  /// Completes once the socket is authenticated, once no reconnect is coming
  /// (paused, refused), or after [timeout].
  Future<void> _awaitConnected(Duration timeout) async {
    if (_socketConnected ||
        _disposed ||
        _paused ||
        _ageRestricted ||
        timeout <= Duration.zero) {
      return;
    }
    final signal = _connectedSignal ??= Completer<void>();
    await signal.future.timeout(timeout, onTimeout: () {});
  }

  /// Wakes publishes waiting in [_awaitConnected]; they recheck the fence.
  /// Also called when a reconnect stops being expected, so they fail fast.
  void _signalConnected() {
    _connectedSignal?.complete();
    _connectedSignal = null;
  }
}
