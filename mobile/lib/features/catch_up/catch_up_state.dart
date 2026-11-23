import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/community/community_provider.dart';
import '../../shared/relay/relay.dart';
import 'catch_up_queue.dart';

enum CatchUpAction { read, keep }

/// What the reader did with one card, newest last, so Undo can step back
/// (web `CatchUpStep`).
class CatchUpStep {
  const CatchUpStep({
    required this.key,
    required this.action,
    required this.latest,
    this.undo,
    this.noop = false,
  });

  /// The card's [cardKey].
  final String key;
  final CatchUpAction action;

  /// The card's newest activity when the reader decided. Anything newer
  /// brings the card back.
  final int latest;

  /// The read's own inverse, when the read state offered one.
  final Future<void> Function()? undo;

  /// Nothing was read (it was already read elsewhere), so Undo marks nothing.
  final bool noop;

  CatchUpStep copyWith({Future<void> Function()? undo, bool? noop}) =>
      CatchUpStep(
        key: key,
        action: action,
        latest: latest,
        undo: undo ?? this.undo,
        noop: noop ?? this.noop,
      );
}

/// One run through the stack (web `CatchUpState`). Mutable on purpose, like
/// the web's: the page settles it while building so a new arrival never
/// shows on top for a moment.
class CatchUpState {
  /// Stack order as first shown, by card key; see [stackOrder].
  List<String> order = [];
  List<CatchUpStep> steps = [];

  /// Cards Undo brought back, shown even before their unread evidence returns.
  final Set<String> restored = {};

  /// Where each conversation card's New line went when it first showed.
  final Map<String, String?> newLines = {};

  /// The card on top stays until the reader decides it, even when reading or
  /// replying in it clears its unread before then.
  String? shown;

  /// The card last on top, kept after leaving Catch-up so cards coming back
  /// meanwhile join the end rather than jumping above it.
  String? top;

  /// Each card as last listed, for a card that stays after its unread went.
  final Map<String, CatchUpEntry> seen = {};
}

/// One run through the stack per community and identity, so leaving
/// Catch-up to open a conversation and coming back keeps the place, the kept
/// cards and Undo. Another community or account starts afresh.
final catchUpStateProvider = Provider<CatchUpState>((ref) {
  ref.watch(activeCommunityProvider.select((value) => value.value?.id));
  ref.watch(myPubkeyProvider);
  return CatchUpState();
});
