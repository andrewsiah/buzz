part of '../compose_bar.dart';

// The composer's mic, as on Snack web: an empty composer shows a mic where
// Send goes. Tapping it listens (X cancels, Stop types the words into the
// box, Send stops and sends them); Snack Cloud turns the speech into text.

enum _DictationStage { idle, starting, listening, transcribing }

class _ComposerDictation {
  const _ComposerDictation({required this.start, required this.strip});

  /// Starts listening; null while the mic can't be used.
  final VoidCallback? start;

  /// Takes the composer's place while listening or transcribing.
  final Widget? strip;

  bool get active => strip != null;
}

_ComposerDictation _useComposerDictation({
  required WidgetRef ref,
  required String channelId,
  required String draftKey,
  required TextEditingController controller,
  required FocusNode focusNode,
  required ValueNotifier<String?> uploadError,
  required ValueNotifier<_AttachmentSurface> attachmentSurface,
  required VoidCallback expand,
  required Future<void> Function() send,
  required bool enabled,
}) {
  final stage = useState(_DictationStage.idle);
  final session = useRef<VoiceDictation?>(null);
  // The conversation the recording belongs to.
  final sessionDraft = useRef<String?>(null);
  final limit = useRef<Timer?>(null);
  final latest = useRef((send: send, expand: expand))
    ..value = (send: send, expand: expand);

  // Ends the current recording, if any. Never touches widget state, so it is
  // safe while the composer is being torn down.
  void release() {
    limit.value?.cancel();
    limit.value = null;
    final current = session.value;
    session.value = null;
    if (current != null) unawaited(current.dispose());
  }

  void reset() {
    release();
    stage.value = _DictationStage.idle;
  }

  // A conversation switch or unmount throws an unfinished recording away.
  useEffect(() => release, [draftKey]);

  Future<void> finish({required bool andSend}) async {
    final current = session.value;
    if (current == null || stage.value != _DictationStage.listening) return;
    limit.value?.cancel();
    stage.value = _DictationStage.transcribing;
    String said;
    try {
      final wav = await current.stop();
      if (wav.length > voiceDictationMaxBytes) {
        throw const SnackAccountException(
          'That was too long. Keep it under a minute.',
        );
      }
      said = (await ref.read(voiceTranscriberProvider)(channelId, wav)).trim();
    } catch (error) {
      if (!identical(session.value, current)) return; // cancelled meanwhile
      reset();
      uploadError.value = switch (error) {
        SnackSignedOut() => 'Sign in to Snack to talk a message, or type it.',
        SnackAccountException(:final message) => message,
        _ => "Couldn't turn that into text. Try again, or type instead.",
      };
      return;
    }
    if (!identical(session.value, current)) return; // cancelled meanwhile
    reset();
    if (said.isEmpty) {
      uploadError.value = "Didn't catch that. Try again.";
      return;
    }
    final draft = controller.text;
    final joined = draft.isEmpty || RegExp(r'\s$').hasMatch(draft)
        ? '$draft$said'
        : '$draft $said';
    controller.value = TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
    if (andSend) {
      await latest.value.send();
    } else {
      latest.value.expand();
    }
  }

  Future<void> start() async {
    if (session.value != null) return;
    if (ref.read(huddleSessionProvider).isInSession) {
      uploadError.value = 'Leave the Huddle before talking a message.';
      return;
    }
    uploadError.value = null;
    attachmentSurface.value = _AttachmentSurface.closed;
    _dismissComposerKeyboard(focusNode);
    final current = ref.read(voiceDictationFactoryProvider)();
    session.value = current;
    sessionDraft.value = draftKey;
    stage.value = _DictationStage.starting;
    try {
      await current.start();
    } catch (error) {
      if (!identical(session.value, current)) return;
      reset();
      uploadError.value = error is VoiceDictationMicDenied
          ? 'Allow microphone access in Settings to talk a message.'
          : "Couldn't start the microphone.";
      return;
    }
    if (!identical(session.value, current)) return; // cancelled meanwhile
    stage.value = _DictationStage.listening;
    limit.value = Timer(
      voiceDictationMaxDuration,
      () => unawaited(finish(andSend: false)),
    );
  }

  // Leaving the app while the mic is open throws the recording away, so a
  // pocketed phone never sends what it overheard. Words already on their way
  // to text still land.
  useOnAppLifecycleStateChange((_, state) {
    if (state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive &&
        session.value != null &&
        stage.value != _DictationStage.transcribing) {
      reset();
    }
  });

  // After a conversation switch the recording is gone; show the composer.
  final current = session.value == null || sessionDraft.value != draftKey
      ? _DictationStage.idle
      : stage.value;
  return _ComposerDictation(
    start: enabled && current == _DictationStage.idle
        ? () => unawaited(start())
        : null,
    strip: current == _DictationStage.idle
        ? null
        : _DictationStrip(
            stage: current,
            dictation: session.value!,
            onCancel: reset,
            onStop: () => unawaited(finish(andSend: false)),
            onSend: () => unawaited(finish(andSend: true)),
          ),
  );
}

/// Owns the level bars, so only the strip redraws while listening.
class _DictationStrip extends HookWidget {
  const _DictationStrip({
    required this.stage,
    required this.dictation,
    required this.onCancel,
    required this.onStop,
    required this.onSend,
  });

  final _DictationStage stage;
  final VoiceDictation dictation;
  final VoidCallback onCancel;
  final VoidCallback onStop;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final shown = useState<List<double>>(const []);
    useEffect(() {
      final subscription = dictation.levels.listen((level) {
        final next = [...shown.value, level];
        shown.value = next.length > 48 ? next.sublist(next.length - 48) : next;
      });
      return subscription.cancel;
    }, [dictation]);
    final colors = context.colors;
    final listening = stage == _DictationStage.listening;
    return Row(
      key: const ValueKey('composer-dictation'),
      children: [
        IconButton(
          key: const ValueKey('composer-dictation-cancel'),
          tooltip: 'Cancel voice typing',
          icon: const Icon(BuzzIcons.x, size: 20),
          onPressed: onCancel,
        ),
        Expanded(
          child: Semantics(
            container: true,
            liveRegion: true,
            label: switch (stage) {
              _DictationStage.starting => 'Waiting for the microphone',
              _DictationStage.transcribing => 'Turning speech into text',
              _ => 'Listening',
            },
            child: SizedBox(
              height: 32,
              child: CustomPaint(
                painter: DictationLevelsPainter(shown.value, colors.primary),
              ),
            ),
          ),
        ),
        const SizedBox(width: Grid.half),
        if (stage == _DictationStage.transcribing)
          const SizedBox.square(
            dimension: 36,
            child: Padding(
              padding: EdgeInsets.all(Grid.xxs),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          IconButton(
            key: const ValueKey('composer-dictation-stop'),
            tooltip: 'Stop and turn into text',
            icon: const Icon(BuzzIcons.square, size: 18),
            onPressed: listening ? onStop : null,
          ),
          const SizedBox(width: Grid.half),
          SizedBox.square(
            dimension: 36,
            child: IconButton.filled(
              key: const ValueKey('composer-dictation-send'),
              tooltip: 'Stop and send',
              padding: EdgeInsets.zero,
              icon: const Icon(BuzzIcons.arrowUp, size: 18),
              onPressed: listening ? onSend : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// Where Send goes while the composer is empty: talk instead of typing.
class _DictationMicButton extends StatelessWidget {
  const _DictationMicButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 36,
    child: IconButton.filledTonal(
      key: const ValueKey('composer-mic'),
      tooltip: 'Voice typing',
      padding: EdgeInsets.zero,
      icon: const Icon(BuzzIcons.mic, size: 18),
      onPressed: () => _runComposerAction(onTap),
    ),
  );
}
