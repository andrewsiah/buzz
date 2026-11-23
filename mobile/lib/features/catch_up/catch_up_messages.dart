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

CatchUpMessage _messageOf(NostrEvent event, {int replyCount = 0}) =>
    CatchUpMessage(
      id: event.id,
      pubkey: event.pubkey,
      content: event.content,
      createdAt: event.createdAt,
      replyCount: replyCount,
    );

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
        final rows = events.where(_isTimelineMessage).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        return [
          for (final event in rows)
            _messageOf(event, replyCount: summaries[event.id]?.replyCount ?? 0),
        ];
      });
    });

/// A thread card's thread: its root (when the channel window holds it) and
/// its replies, oldest first, from the thread page's own source.
final catchUpThreadProvider = Provider.autoDispose
    .family<AsyncValue<List<CatchUpMessage>>, ThreadRepliesArgs>((ref, args) {
      final replies = ref.watch(threadRepliesWithLocalProvider(args));
      final window = ref.watch(channelMessagesProvider(args.channelId)).value;
      final root = window?.where((e) => e.id == args.rootId).firstOrNull;
      return replies.whenData((events) {
        final sorted = [...events]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        return [
          if (root != null) _messageOf(root),
          for (final event in sorted)
            if (event.id != args.rootId) _messageOf(event),
        ];
      });
    });
