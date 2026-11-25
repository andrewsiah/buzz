part of 'channels_provider.dart';

extension _UnreadCatchUp on ChannelsNotifier {
  /// Backfills unread badges for the channels this refresh just installed.
  ///
  /// Runs detached from the refresh that starts it, so the lifecycle token
  /// captured below is what keeps a response that outlived its refresh from
  /// writing unread state into whatever the user is looking at now. Every
  /// refresh path starts a catch-up, including the initial load, the ordinary
  /// membership refresh a join performs and the reconnect backstop, so the
  /// token is unconditional rather than tied to discovery. A retired refresh
  /// returns instead of throwing: nothing awaits this future, so a thrown
  /// [_StaleChannelRefresh] would only surface as an unhandled error.
  ///
  /// The request fence and subscription generation are passed from the refresh
  /// that installed [channels], preserving request ownership after detachment.
  Future<void> _catchUpUnreadEvents(
    List<Channel> channels,
    _ChannelRefreshFence fence,
    int subscriptionGeneration,
  ) async {
    if (!_lifecycleRef.mounted) return;
    // A catch-up that misses channels is retried, as a list read.
    var incomplete = false;
    try {
      final myPk = _lifecycleRef.read(myPubkeyProvider);
      if (myPk == null) return;

      final session = _lifecycleRef.read(relaySessionProvider.notifier);
      final mutedChannelIds = _mutedChannelIds();
      final readState = _lifecycleRef.read(readStateProvider);
      final activeChannels = [
        for (final channel in channels)
          if (channel.isMember && !channel.isArchived) channel,
      ];
      final channelById = {
        for (final channel in activeChannels) channel.id: channel,
      };
      final readAtByChannel = {
        for (final channel in activeChannels)
          channel.id: readState.effectiveTimestamp(channel.id),
      };
      final requestedAt = currentUnixSeconds();
      // SNACK: the live coverage this catch-up starts from, per channel.
      final liveAtStart = {
        for (final channel in activeChannels)
          channel.id: _liveCoverageOf(channel.id),
      };
      final cursorsAtStart = {
        for (final channel in activeChannels)
          channel.id: _unreadCaughtUpByChannel[channel.id],
      };
      final filters = [
        for (final channel in activeChannels)
          for (final kinds in [
            EventKind.channelMessageEventKinds,
            [EventKind.deletion, EventKind.nip29DeleteEvent],
          ])
            NostrFilter(
              kinds: kinds,
              tags: {
                '#h': [channel.id],
              },
              since: _unreadCatchUpSince(
                channel.id,
                readAtByChannel[channel.id],
                muted: mutedChannelIds.contains(channel.id),
              ),
              limit: _unreadCatchUpLimit,
            ),
      ];

      final failedChannelIds = <String>{};
      final events = await _fetchChannelHistoryBatch(
        session,
        filters,
        operation: 'unread catch-up',
        failedChannelIds: failedChannelIds,
      );
      // Unavailable: keep the unread state already observed.
      if (events == null) {
        incomplete = true;
        return;
      }
      // The relay round-trip above is the window Jed's probes park in: a newer
      // refresh, a community switch or an identity switch here means every
      // write below belongs to a channel list the user has left.
      if (!_lifecycleRef.mounted ||
          _isCatchUpRetired(fence, subscriptionGeneration)) {
        return;
      }

      _recordUnreadCaughtUp(
        readAtByChannel,
        requestedAt,
        failedChannelIds,
        cursorsAtStart: cursorsAtStart,
        mutedChannelIds: mutedChannelIds,
        subscriptionGeneration: subscriptionGeneration,
        liveAtStart: liveAtStart,
      );
      incomplete = failedChannelIds.isNotEmpty;

      // Keep this response's deletion evidence independently of the bounded
      // cross-request tombstones: a large batch can evict its own early IDs.
      final batchDeletedIds = <String>{};
      var appliedDeletion = false;
      for (final event in events) {
        final channelId = event.channelId;
        if (channelById.containsKey(channelId) ||
            (channelId == null && event.kind == EventKind.deletion)) {
          if (_applyUnreadDeletion(event)) {
            appliedDeletion = true;
            batchDeletedIds.addAll(
              event.tags
                  .where((tag) => tag.length >= 2 && tag[0] == 'e')
                  .map((tag) => tag[1]),
            );
          }
        }
      }

      var threadInterestChanged = false;
      for (final event in events) {
        if (batchDeletedIds.contains(event.id)) continue;
        if (EventKind.channelMessageEventKinds.contains(event.kind) &&
            event.pubkey.toLowerCase() == myPk.toLowerCase() &&
            _addSelfThreadInterest(event)) {
          threadInterestChanged = true;
        }
      }
      if (threadInterestChanged) _writeThreadInterestStores(myPk);

      final recordedAtByChannel = <String, int>{};
      final windowSizeByChannel = <String, int>{};
      final oldestQuietByChannel = <String, NostrEvent>{};
      final oldestInWindowByChannel = <String, int>{};
      for (final event in events) {
        if (!EventKind.channelMessageEventKinds.contains(event.kind)) continue;
        final channelId = event.channelId;
        if (channelId == null) continue;
        final channel = channelById[channelId];
        if (channel == null) continue;
        windowSizeByChannel.update(channelId, (n) => n + 1, ifAbsent: () => 1);
        oldestInWindowByChannel.update(
          channelId,
          (at) => min(at, event.createdAt),
          ifAbsent: () => event.createdAt,
        );
        if (batchDeletedIds.contains(event.id) ||
            _unscopedUnreadDeletedIds.contains(event.id) ||
            _unreadDeletedIdsByChannel[channelId]?.contains(event.id) == true) {
          continue;
        }
        final readAt = readAtByChannel[channelId];
        if (event.pubkey.toLowerCase() == myPk.toLowerCase()) continue;
        if (readAt != null && event.createdAt <= readAt) continue;
        if (!shouldNotifyForEvent(
          event,
          myPk,
          participatedRootIds: _participatedRootIds,
          followedRootIds: _followedRootIds(),
          authoredRootIds: _authoredRootIds,
          mutedChannelIds: mutedChannelIds,
          channelId: channel.id,
        )) {
          _noteUncountedReply(channel, event);
          continue;
        }
        if (isQuietAgentMessage(event.tags)) {
          final oldest = oldestQuietByChannel[channelId];
          if (oldest == null || event.createdAt < oldest.createdAt) {
            oldestQuietByChannel[channelId] = event;
          }
          continue;
        }
        if (!_recordUnreadEvent(channel, event, myPk)) continue;
        recordedAtByChannel[channelId] = max(
          recordedAtByChannel[channelId] ?? 0,
          event.createdAt,
        );
      }
      // A full window can leave out older messages: until the channel is read
      // through its oldest one, this device's unread evidence is incomplete.
      for (final MapEntry(key: channelId, value: size)
          in windowSizeByChannel.entries) {
        if (size < _unreadCatchUpLimit) continue;
        final evidence = _unreadEvidence[this]?[channelId];
        if (evidence == null) continue;
        evidence.gapBefore = max(
          evidence.gapBefore ?? 0,
          oldestInWindowByChannel[channelId]!,
        );
      }
      // A full window of quiet agent messages can hide an older unread event,
      // and every refresh asks for the same window. Count its oldest quiet
      // message instead, so the channel stays unread until it is opened.
      for (final MapEntry(key: channelId, value: quiet)
          in oldestQuietByChannel.entries) {
        if (recordedAtByChannel.containsKey(channelId)) continue;
        if ((windowSizeByChannel[channelId] ?? 0) < _unreadCatchUpLimit) {
          continue;
        }
        if (_recordUnreadEvent(
          channelById[channelId]!,
          quiet,
          myPk,
          countQuiet: true,
        )) {
          recordedAtByChannel[channelId] = quiet.createdAt;
        }
      }
      // Republish only when this catch-up actually changed unread state. A
      // batch that recorded nothing has nothing to show, and a failed or
      // superseded batch must not repaint another refresh's list: the retired
      // check above already returned in that case, and no await separates it
      // from here, so a second check would be dead code.
      // Recorded events also advance `lastMessageAt`, as live events do: a
      // deadline-unavailable latest-message batch leaves it unset.
      if (recordedAtByChannel.isNotEmpty || appliedDeletion) {
        _publishUnreadCatchUp(recordedAtByChannel);
      }
    } catch (error) {
      incomplete = true;
      if (!_lifecycleRef.mounted) return;
      debugPrint('[ChannelsNotifier] unread catch-up failed: $error');
    } finally {
      // Optional history can terminate without data. Release this destination
      // with its retained unread state, but never settle a retired request.
      if (_lifecycleRef.mounted &&
          !_isCatchUpRetired(fence, subscriptionGeneration)) {
        _settledUnreadGeneration = subscriptionGeneration;
        _notifyUnreadReadinessChanged();
        if (incomplete) {
          _unreadCatchUpRetry.schedule(_retryUnreadCatchUp);
        } else {
          _unreadCatchUpRetry.cancel();
        }
      }
    }
  }

  /// Where a channel's catch-up starts.
  ///
  /// The first catch-up in a session starts after the read timestamp. Every
  /// refresh path catches up again (resume, reconnect, join), and on a slow
  /// link re-downloading up to [_unreadCatchUpLimit] messages per channel each
  /// time keeps the batch from ever finishing. A later catch-up therefore
  /// starts [relayCrossDeviceSkewSeconds] before an earlier one was sent. The
  /// earlier one returned every message stored before it was sent, and the
  /// relay stores no event with a `created_at` more than 900s from its own
  /// clock, so anything stored since then is newer than that start, however
  /// late it arrived and however far this phone's clock is from the sender's. A read timestamp that moved back since then, or a mute
  /// change (which changes what counts as unread), makes the full window apply
  /// again.
  int _unreadCatchUpSince(
    String channelId,
    int? readAt, {
    required bool muted,
  }) {
    final afterRead = (readAt ?? -1) + 1;
    final caughtUp = _unreadCaughtUpByChannel[channelId];
    if (caughtUp == null ||
        caughtUp.muted != muted ||
        (readAt ?? -1) < (caughtUp.readAt ?? -1)) {
      return afterRead;
    }
    return max(afterRead, caughtUp.sentAt - relayCrossDeviceSkewSeconds);
  }

  /// Remembers when a catch-up over [readAtByChannel] was sent, and the read
  /// timestamps and mute state it used, for every channel except
  /// [failedChannelIds]: their filters failed, so the next catch-up still needs
  /// their earlier window. A channel whose cursor changed while the request was
  /// out, such as a live deletion of its marker, keeps that change: this
  /// response only covered the window the old cursor asked for.
  void _recordUnreadCaughtUp(
    Map<String, int?> readAtByChannel,
    int sentAt,
    Set<String> failedChannelIds, {
    required Map<String, ({int sentAt, int? readAt, bool muted})?>
    cursorsAtStart,
    required Set<String> mutedChannelIds,
    required int subscriptionGeneration,
    required Map<
      String,
      ({_LiveChunkSubscription? live, int interruptions, int connections})
    >
    liveAtStart,
  }) {
    final evidence = _unreadEvidence[this] ??= {};
    for (final MapEntry(key: channelId, value: readAt)
        in readAtByChannel.entries) {
      if (failedChannelIds.contains(channelId)) continue;
      final atStart = cursorsAtStart[channelId];
      if (atStart != null && _unreadCaughtUpByChannel[channelId] != atStart) {
        continue;
      }
      _unreadCaughtUpByChannel[channelId] = (
        sentAt: sentAt,
        readAt: readAt,
        muted: mutedChannelIds.contains(channelId),
      );
      (evidence[channelId] ??= _UnreadEvidence())
        ..generation = subscriptionGeneration
        ..live = liveAtStart[channelId]?.live
        ..interruptions = liveAtStart[channelId]?.interruptions ?? 0
        ..connections = liveAtStart[channelId]?.connections ?? -1;
    }
  }
}

/// SNACK: how complete one channel's unread evidence is, per notifier. Kept
/// beside the notifier because `channels_provider.dart` sits at the file-size
/// ceiling.
final _unreadEvidence = Expando<Map<String, _UnreadEvidence>>();

/// SNACK: how many times each notifier's relay connection came back.
final _unreadConnections = Expando<int>();

class _UnreadEvidence {
  /// The live-subscription generation whose catch-up last covered the channel.
  int? generation;

  /// The live chunk that catch-up started from, and how often it had been
  /// interrupted then: one dropped and reopened since may have missed events.
  _LiveChunkSubscription? live;
  int interruptions = 0;
  int connections = 0;

  /// A full catch-up window began here, or an uncounted reply this new was
  /// dropped: older unread messages may be missing until the channel's read
  /// passes this.
  int? gapBefore;

  /// Replies from others this device does not count (a thread it neither
  /// wrote in nor follows) that another device may count, by id.
  final uncounted = <String, ObservedUnreadEvent>{};
}

/// How many uncounted replies a channel keeps; the oldest are kept.
const _uncountedReplyLimit = 200;

extension _UnreadEvidenceRecording on ChannelsNotifier {
  /// Records a live [event] the way catch-up does: counted, or noted as a
  /// reply another device may count. Returns whether it was recorded.
  bool _recordLiveUnreadEvent(
    Channel channel,
    NostrEvent event,
    String? myPk,
    Set<String> mutedChannelIds,
  ) {
    if (myPk == null) return false;
    if (shouldNotifyForEvent(
      event,
      myPk,
      participatedRootIds: _participatedRootIds,
      followedRootIds: _followedRootIds(),
      authoredRootIds: _authoredRootIds,
      mutedChannelIds: mutedChannelIds,
      channelId: channel.id,
    )) {
      return _recordUnreadEvent(channel, event, myPk);
    }
    if (event.pubkey.toLowerCase() != myPk.toLowerCase()) {
      _noteUncountedReply(channel, event);
    }
    return false;
  }

  /// Notes a reply from someone else that [shouldNotifyForEvent] left out
  /// here, so Catch-up's synced channel mark never reads it.
  void _noteUncountedReply(Channel channel, NostrEvent event) {
    if (!EventKind.channelMessageEventKinds.contains(event.kind) ||
        event.threadReference.parentId == null ||
        _isBroadcastReply(event) ||
        isQuietAgentMessage(event.tags) ||
        _unscopedUnreadDeletedIds.contains(event.id) ||
        _unreadDeletedIdsByChannel[channel.id]?.contains(event.id) == true) {
      return;
    }
    final rootId = event.threadReference.rootId;
    if (rootId == null) return;
    final evidence = (_unreadEvidence[this] ??= {})[channel.id] ??=
        _UnreadEvidence();
    final uncounted = evidence.uncounted;
    final readAt = _lifecycleRef
        .read(readStateProvider)
        .effectiveTimestamp(channel.id);
    if (readAt != null && event.createdAt <= readAt) return;
    if (readAt != null) {
      uncounted.removeWhere((_, reply) => reply.createdAt <= readAt);
    }
    uncounted[event.id] = makeObservedUnreadEvent(
      id: event.id,
      createdAt: event.createdAt,
      rootId: rootId,
      highPriority: false,
      channelType: channel.channelType,
      isThreadedReply: true,
    );
    if (uncounted.length <= _uncountedReplyLimit) return;
    final newest = uncounted.values.reduce(
      (a, b) => a.createdAt >= b.createdAt ? a : b,
    );
    uncounted.remove(newest.id);
    evidence.gapBefore = max(evidence.gapBefore ?? 0, newest.createdAt);
  }

  /// The live chunk covering [channelId] now, and its interruptions so far.
  /// None while it is down: catch-up then covers nothing after it is sent.
  ({_LiveChunkSubscription? live, int interruptions, int connections})
  _liveCoverageOf(String channelId) {
    final connections = _unreadConnections[this] ?? 0;
    if (_lifecycleRef.read(relaySessionProvider).status ==
        SessionStatus.connected) {
      for (final MapEntry(:key, :value) in _liveSubscriptionsByChunk.entries) {
        if (!value.interrupted && key.split('\u0000').contains(channelId)) {
          return (
            live: value,
            interruptions: value.interruptions,
            connections: connections,
          );
        }
      }
    }
    return (live: null, interruptions: 0, connections: connections);
  }

  /// A connection that dropped and came back may have missed live events,
  /// which are not replayed.
  void _noteUnreadReconnect() =>
      _unreadConnections[this] = (_unreadConnections[this] ?? 0) + 1;
}

/// Whether this device holds every unread message of a channel.
extension ChannelUnreadEvidence on ChannelsNotifier {
  /// SNACK: whether [channelId]'s observed unread events are every message
  /// after its read [channelReadAt] that this device counts: its live
  /// subscription is up, uninterrupted since the catch-up started with it
  /// covered the channel, that window was not full, the registry evicted
  /// nothing, and the channel is not muted (a muted channel keeps only its
  /// mentions). A read that would answer for the whole channel waits for this.
  bool unreadEvidenceComplete(String channelId, int? channelReadAt) {
    final caughtUp = _unreadCaughtUpByChannel[channelId];
    final evidence = _unreadEvidence[this]?[channelId];
    final gap = evidence?.gapBefore;
    final live = _liveCoverageOf(channelId);
    return _settledUnreadGeneration == _subscriptionVersion &&
        evidence?.generation == _subscriptionVersion &&
        live.live != null &&
        identical(live.live, evidence?.live) &&
        !live.live!.interrupted &&
        live.interruptions == evidence?.interruptions &&
        live.connections == evidence?.connections &&
        caughtUp != null &&
        !caughtUp.muted &&
        !_mutedChannelIds().contains(channelId) &&
        (caughtUp.readAt ?? -1) <= (channelReadAt ?? -1) &&
        (gap == null || (channelReadAt ?? -1) >= gap) &&
        (_observedUnreadEventsByChannel[channelId]?.length ?? 0) <
            _unreadCatchUpLimit;
  }

  /// SNACK: replies from others in [channelId] that this device does not
  /// count but another may (a thread written in or followed elsewhere).
  Iterable<ObservedUnreadEvent> uncountedReplies(String channelId) =>
      _unreadEvidence[this]?[channelId]?.uncounted.values ??
      const <ObservedUnreadEvent>[];
}

Channel _advanceLastMessageAt(Channel channel, int? createdAt) {
  if (createdAt == null) return channel;
  final at = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
  final current = channel.lastMessageAt;
  if (current != null && !at.isAfter(current)) return channel;
  return channel.copyWith(lastMessageAt: at);
}
