/// Replying from a Catch-up card without leaving the stack: a reply box at
/// the bottom of the card and a round mic that records, transcribes and
/// sends straight away. Sending handles the card, so the next one comes up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/dictation/voice_dictation.dart';
import '../../shared/snack/snack_account.dart';
import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/feedback_snackbar.dart';
import '../channels/channel.dart';
import '../channels/send_message_provider.dart';

/// Sends [content] to [channelId], inside the thread [rootId] when given.
typedef CatchUpReplySender =
    Future<void> Function({
      required String channelId,
      required Channel channel,
      String? rootId,
      required String content,
    });

/// Sends with the same path as the conversation and thread composers.
final catchUpReplySenderProvider = Provider<CatchUpReplySender>((ref) {
  final send = ref.watch(sendMessageProvider);
  return ({
    required String channelId,
    required Channel channel,
    String? rootId,
    required String content,
  }) => send.call(
    channelId: channelId,
    content: content,
    channel: channel,
    parentEventId: rootId,
    rootEventId: rootId,
  );
});

enum _Mode { idle, recording, transcribing, sending }

/// The reply box at the bottom of a Catch-up card. Typing shows a send
/// button; empty, a round mic. The mic records until the send button (or a
/// minute), then transcribes and sends with no edit step; X throws the
/// recording away. A reply that lands calls [onSent].
class CatchUpReplyBar extends HookConsumerWidget {
  const CatchUpReplyBar({
    super.key,
    required this.channel,
    required this.rootId,
    required this.hintText,
    required this.onSent,
  });

  final Channel channel;

  /// The thread the reply goes in; null posts in the conversation.
  final String? rootId;
  final String hintText;
  final VoidCallback onSent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    useListenable(controller);
    final mode = useState(_Mode.idle);
    final levels = useState<List<double>>(const []);
    final dictation = useRef<VoiceDictation?>(null);
    final levelSub = useRef<StreamSubscription<double>?>(null);
    final limit = useRef<Timer?>(null);
    final mounted = useRef(true);

    Future<void> release() async {
      limit.value?.cancel();
      limit.value = null;
      unawaited(levelSub.value?.cancel());
      levelSub.value = null;
      final current = dictation.value;
      dictation.value = null;
      await current?.dispose();
    }

    useEffect(
      () => () {
        mounted.value = false;
        unawaited(release());
      },
      const [],
    );

    // Read up front: a reply already on its way still lands, and still says
    // when it didn't, after its card has left the stack.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sendReply = ref.read(catchUpReplySenderProvider);
    final transcribe = ref.read(voiceTranscriberProvider);
    final makeDictation = ref.read(voiceDictationFactoryProvider);

    // The newest outcome replaces an older toast rather than queueing.
    void toast(String message) => messenger
      ?..hideCurrentSnackBar()
      ..showFeedbackSnackBar(
        SnackBar(content: Text(message)),
        kind: ToastKind.error,
      );

    void setMode(_Mode value) {
      if (mounted.value) mode.value = value;
    }

    Future<bool> deliver(String content) async {
      setMode(_Mode.sending);
      try {
        await sendReply(
          channelId: channel.id,
          channel: channel,
          rootId: rootId,
          content: content,
        );
      } catch (error) {
        setMode(_Mode.idle);
        toast(_notSent(error));
        return false;
      }
      setMode(_Mode.idle);
      if (mounted.value) onSent();
      return true;
    }

    Future<void> sendTyped() async {
      final text = controller.text.trim();
      if (text.isEmpty || mode.value != _Mode.idle) return;
      if (await deliver(text) && mounted.value) controller.clear();
    }

    Future<void> finishRecording() async {
      final current = dictation.value;
      if (current == null || mode.value != _Mode.recording) return;
      limit.value?.cancel();
      setMode(_Mode.transcribing);
      String text;
      try {
        final wav = await current.stop();
        if (wav.length > voiceDictationMaxBytes) {
          throw const SnackAccountException(
            'That was too long. Keep a spoken reply under a minute.',
          );
        }
        text = (await transcribe(channel.id, wav)).trim();
      } catch (error) {
        await release();
        setMode(_Mode.idle);
        toast(_transcribeFailed(error));
        return;
      }
      await release();
      if (text.isEmpty) {
        setMode(_Mode.idle);
        toast("Didn't catch that");
        return;
      }
      await deliver(text);
    }

    Future<void> startRecording() async {
      if (mode.value != _Mode.idle) return;
      FocusScope.of(context).unfocus();
      final current = makeDictation();
      dictation.value = current;
      levels.value = const [];
      setMode(_Mode.recording);
      try {
        await current.start();
      } catch (error) {
        // Discarded meanwhile: X already put things back.
        if (!identical(dictation.value, current)) return;
        await release();
        setMode(_Mode.idle);
        toast(
          error is VoiceDictationMicDenied
              ? 'Allow microphone access in Settings to talk a reply.'
              : "Couldn't start the microphone.",
        );
        return;
      }
      if (!identical(dictation.value, current)) return; // discarded meanwhile
      levelSub.value = current.levels.listen((level) {
        if (!mounted.value) return;
        final next = [...levels.value, level];
        levels.value = next.length > 40 ? next.sublist(next.length - 40) : next;
      });
      limit.value = Timer(
        voiceDictationMaxDuration,
        () => unawaited(finishRecording()),
      );
    }

    Future<void> discard() async {
      final current = dictation.value;
      if (current == null || mode.value != _Mode.recording) return;
      limit.value?.cancel();
      try {
        await current.cancel();
      } catch (_) {}
      await release();
      if (mounted.value) levels.value = const [];
      setMode(_Mode.idle);
    }

    // Leaving the app while recording throws the recording away, so a
    // pocketed phone never sends what it overheard.
    useOnAppLifecycleStateChange((_, state) {
      if (state != AppLifecycleState.resumed &&
          state != AppLifecycleState.inactive) {
        unawaited(discard());
      }
    });

    final busy =
        mode.value == _Mode.transcribing || mode.value == _Mode.sending;
    final hasText = controller.text.trim().isNotEmpty;
    final colors = context.colors;

    final Widget field;
    if (mode.value == _Mode.recording) {
      field = Row(
        children: [
          IconButton(
            key: const ValueKey('voice-dictation-discard'),
            tooltip: 'Discard recording',
            icon: const Icon(BuzzIcons.x, size: 20),
            onPressed: () => unawaited(discard()),
          ),
          Expanded(
            child: Semantics(
              container: true,
              label: 'Recording',
              liveRegion: true,
              child: SizedBox(
                height: 32,
                child: CustomPaint(
                  painter: DictationLevelsPainter(levels.value, colors.primary),
                ),
              ),
            ),
          ),
        ],
      );
    } else if (busy) {
      field = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Grid.twelve),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: Grid.xxs),
            Semantics(
              liveRegion: true,
              child: Text(
                mode.value == _Mode.transcribing ? 'Transcribing…' : 'Sending…',
                style: context.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      field = TextField(
        key: const ValueKey('voice-dictation-field'),
        controller: controller,
        minLines: 1,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => unawaited(sendTyped()),
        decoration: InputDecoration(
          hintText: hintText,
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Grid.twelve,
            vertical: Grid.xxs,
          ),
        ),
      );
    }

    final Widget action;
    if (mode.value == _Mode.recording) {
      action = IconButton.filled(
        key: const ValueKey('voice-dictation-mic-send'),
        tooltip: 'Send voice reply',
        icon: const Icon(BuzzIcons.arrowUp, size: 20),
        onPressed: () => unawaited(finishRecording()),
      );
    } else if (hasText && !busy) {
      action = IconButton.filled(
        key: const ValueKey('voice-dictation-send'),
        tooltip: 'Send reply',
        icon: const Icon(BuzzIcons.arrowUp, size: 20),
        onPressed: () => unawaited(sendTyped()),
      );
    } else {
      action = IconButton.filledTonal(
        key: const ValueKey('voice-dictation-mic'),
        tooltip: 'Talk a reply',
        icon: const Icon(BuzzIcons.mic, size: 20),
        onPressed: busy ? null : () => unawaited(startRecording()),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Grid.xxs,
        Grid.xxs,
        Grid.xxs,
        Grid.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(Radii.full),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: field,
            ),
          ),
          const SizedBox(width: Grid.xxs),
          SizedBox.square(dimension: 44, child: action),
        ],
      ),
    );
  }
}

String _notSent(Object error) {
  final text = error is StateError ? error.message : '';
  return text.isNotEmpty ? 'Not sent. $text' : 'Not sent. Try again.';
}

String _transcribeFailed(Object error) => switch (error) {
  SnackSignedOut() => 'Sign in to Snack to talk a reply, or type it.',
  SnackAccountException(:final message) => message,
  _ => "Couldn't turn that into text. Try again, or type.",
};
