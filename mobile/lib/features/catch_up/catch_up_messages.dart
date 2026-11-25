import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import '../channels/channel_messages_provider.dart';
import '../channels/thread_replies_provider.dart';

/// One message as a Catch-up card shows it.
class CatchUpMessage {
  const CatchUpMessage({
    required this.id,
    required this.pubkey,
    required this.content,
    required this.createdAt,
    this.replyCount = 0,
  });

  final String id;
  final String pubkey;
  final String content;
  final int createdAt;

  /// Replies in this message's thread, for a conversation card's rows.
  final int replyCount;
}

CatchUpMessage _messageOf(_Shown shown, {int replyCount = 0}) => CatchUpMessage(
  id: shown.event.id,
  pubkey: shown.event.pubkey,
  content: shown.content,
  createdAt: shown.event.createdAt,
  replyCount: replyCount,
);

/// A message event and the content it shows after edits.
typedef _Shown = ({NostrEvent event, String content});

String? _target(NostrEvent event) => event.tags
    .lastWhere(
      (tag) => tag.length >= 2 && tag[0] == 'e',
      orElse: () => const [],
    )
    .elementAtOrNull(1);

/// [events]' messages, oldest first, as the channel and thread pages show
/// them: deleted ones dropped and each showing its latest edit by its author.
/// Edits, reactions and deletions are not rows. Progress cards update by
/// editing, so a raw list would show one row per update.
List<_Shown> _folded(Iterable<NostrEvent> events) {
  final deleted = <String>{
    for (final event in events)
      if (event.kind == EventKind.deletion ||
          event.kind == EventKind.nip29DeleteEvent)
        for (final tag in event.tags)
          if (tag.length >= 2 && tag[0] == 'e') tag[1],
  };
  final authors = <String, String>{
    for (final event in events)
      if (EventKind.channelMessageEventKinds.contains(event.kind))
        event.id: event.pubkey,
  };
  // Only the author's own edits count.
  final edits = <String, NostrEvent>{};
  for (final event in events) {
    if (event.kind != EventKind.streamMessageEdit) continue;
    if (deleted.contains(event.id)) continue;
    final target = _target(event);
    if (target == null || authors[target] != event.pubkey) continue;
    final existing = edits[target];
    // Greatest (created_at, id) wins, as in formatTimeline.
    if (existing == null ||
        event.createdAt > existing.createdAt ||
        (event.createdAt == existing.createdAt &&
            event.id.compareTo(existing.id) > 0)) {
      edits[target] = event;
    }
  }
  final seen = <String>{};
  final messages = [
    for (final event in events)
      if (EventKind.channelMessageEventKinds.contains(event.kind) &&
          !deleted.contains(event.id) &&
          seen.add(event.id))
        (event: event, content: edits[event.id]?.content ?? event.content),
  ]..sort((a, b) => a.event.createdAt.compareTo(b.event.createdAt));
  return messages;
}

/// [_folded] as Catch-up rows, for tests of the fold itself.
@visibleForTesting
List<CatchUpMessage> foldCatchUpMessages(Iterable<NostrEvent> events) => [
  for (final shown in _folded(events)) _messageOf(shown),
];

bool _isTimelineMessage(NostrEvent event) {
  if (!EventKind.channelMessageEventKinds.contains(event.kind)) return false;
  if (event.threadReference.parentId == null) return true;
  // A broadcast reply also shows in the channel's timeline.
  return event.tags.any(
    (tag) => tag.length >= 2 && tag[0] == 'broadcast' && tag[1] == '1',
  );
}

/// A conversation card's timeline: the channel's own (top-level) messages,
/// oldest first, from the same window the channel page shows. Watching it
/// loads the window as opening the channel would (web: `channels.ensure`).
final catchUpTimelineProvider = Provider.autoDispose
    .family<AsyncValue<List<CatchUpMessage>>, String>((ref, channelId) {
      final window = ref.watch(channelMessagesProvider(channelId));
      final summaries = ref
          .read(channelMessagesProvider(channelId).notifier)
          .threadSummaries;
      return window.whenData((events) {
        final ids = {
          for (final event in events)
            if (_isTimelineMessage(event)) event.id,
        };
        return [
          for (final shown in _folded(events))
            if (ids.contains(shown.event.id))
              _messageOf(
                shown,
                replyCount: summaries[shown.event.id]?.replyCount ?? 0,
              ),
        ];
      });
    });

/// A thread card's thread: its root (when the channel window holds it) and
/// its replies, oldest first, from the thread page's own source.
final catchUpThreadProvider = Provider.autoDispose
    .family<AsyncValue<List<CatchUpMessage>>, ThreadRepliesArgs>((ref, args) {
      final replies = ref.watch(threadRepliesWithLocalProvider(args));
      final window = ref.watch(channelMessagesProvider(args.channelId)).value;
      return replies.whenData((events) {
        final ids = {for (final event in events) event.id};
        final messages = _folded([
          ...events,
          // The root and its edits come from the channel window.
          ...?window?.where(
            (event) =>
                !ids.contains(event.id) &&
                (event.id == args.rootId ||
                    event.kind == EventKind.streamMessageEdit ||
                    event.kind == EventKind.deletion ||
                    event.kind == EventKind.nip29DeleteEvent),
          ),
        ]);
        final root = messages
            .where((shown) => shown.event.id == args.rootId)
            .firstOrNull;
        return [
          if (root != null) _messageOf(root),
          for (final shown in messages)
            if (shown.event.id != args.rootId) _messageOf(shown),
        ];
      });
    });
