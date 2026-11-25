/// Replying from a Catch-up card without leaving the stack: a reply box at
/// the bottom of the card and a round mic that records, transcribes and
/// sends straight away. Sending handles the card, so the next one comes up.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../shared/snack/snack_account.dart';
import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/feedback_snackbar.dart';
import '../channels/channel.dart';
import '../channels/send_message_provider.dart';

/// Longest spoken reply. Snack Cloud takes about 3 MB of base64 WAV, and
/// 16 kHz mono 16-bit is ~43 kB/s once encoded, so a minute fits.
const catchUpDictationMaxDuration = Duration(seconds: 60);

/// Sends [content] to [channelId], inside the thread [rootId] when given.
typedef CatchUpReplySender =
    Future<void> Function({
      required String channelId,
      required Channel channel,
      String? rootId,
      required String content,
    });

/// Speech to text for a recorded WAV, through Snack Cloud.
typedef CatchUpTranscriber =
    Future<String> Function(String channelId, Uint8List wav);

/// One spoken reply: 16 kHz mono WAV, as Snack web records.
abstract interface class CatchUpDictation {
  /// Input level, 0..1, while recording.
  Stream<double> get levels;

  /// Throws [CatchUpMicDenied] without microphone access.
  Future<void> start();

  /// The finished recording's WAV bytes.
  Future<Uint8List> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  Future<void> dispose();
}

class CatchUpMicDenied implements Exception {
  const CatchUpMicDenied();
}

/// Text the e2e test "says" into the mic on the simulator, which has no
/// microphone and no speech to text on its test stack. Empty in real builds.
const _e2eDictation = String.fromEnvironment('SNACK_E2E_DICTATION');

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

final catchUpDictationFactoryProvider = Provider<CatchUpDictation Function()>(
  (ref) => _e2eDictation.isNotEmpty
      ? _ScriptedDictation.new
      : DeviceCatchUpDictation.new,
);

final catchUpTranscriberProvider = Provider<CatchUpTranscriber>((ref) {
  if (_e2eDictation.isNotEmpty) return (_, _) async => _e2eDictation;
  final account = ref.read(snackAccountProvider);
  return account.transcribe;
});

/// Records with the `record` plugin to a temporary WAV file.
class DeviceCatchUpDictation implements CatchUpDictation {
  DeviceCatchUpDictation({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final _levels = StreamController<double>.broadcast();
  StreamSubscription<Amplitude>? _amplitude;
  String? _path;
  bool _disposed = false;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> start() async {
    if (!await _recorder.hasPermission()) throw const CatchUpMicDenied();
    final directory = await getTemporaryDirectory();
    if (_disposed) throw StateError('Recording was cancelled.');
    final path =
        '${directory.path}${Platform.pathSeparator}'
        'catch-up-reply-${DateTime.now().microsecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: path,
    );
    _path = path;
    if (_disposed) {
      await _recorder.cancel();
      throw StateError('Recording was cancelled.');
    }
    _amplitude = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 80))
        .listen((amplitude) {
          final level =
              (math.pow(10, amplitude.current.clamp(-60.0, 0.0) / 20) * 4)
                  .clamp(0.04, 1.0)
                  .toDouble();
          if (!_levels.isClosed) _levels.add(level);
        });
  }

  @override
  Future<Uint8List> stop() async {
    await _amplitude?.cancel();
    final path = await _recorder.stop() ?? _path;
    if (path == null) throw StateError('Nothing was recorded.');
    final file = File(path);
    try {
      return await file.readAsBytes();
    } finally {
      unawaited(file.delete().then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  Future<void> cancel() async {
    await _amplitude?.cancel();
    await _recorder.cancel();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _amplitude?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {}
    await _recorder.dispose();
    await _levels.close();
  }
}

/// The e2e stand-in for the mic: plays levels and returns a short silent WAV.
class _ScriptedDictation implements CatchUpDictation {
  final _levels = StreamController<double>.broadcast();
  Timer? _timer;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> start() async {
    var tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (_levels.isClosed) return;
      _levels.add(0.2 + 0.6 * (math.sin(tick++) + 1) / 2);
    });
  }

  @override
  Future<Uint8List> stop() async {
    _timer?.cancel();
    return silentWav(const Duration(milliseconds: 500));
  }

  @override
  Future<void> cancel() async => _timer?.cancel();

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _levels.close();
  }
}

/// A 16 kHz mono 16-bit WAV of silence.
Uint8List silentWav(Duration length) {
  final samples = 16000 * length.inMilliseconds ~/ 1000;
  final data = ByteData(44 + samples * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return data.buffer.asUint8List();
}

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
    final dictation = useRef<CatchUpDictation?>(null);
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

    // The newest outcome replaces an older toast rather than queueing.
    void toast(String message) => ScaffoldMessenger.maybeOf(context)
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
        await ref.read(catchUpReplySenderProvider)(
          channelId: channel.id,
          channel: channel,
          rootId: rootId,
          content: content,
        );
      } catch (error) {
        setMode(_Mode.idle);
        if (mounted.value) toast(_notSent(error));
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
        text = (await ref.read(catchUpTranscriberProvider)(
          channel.id,
          wav,
        )).trim();
      } catch (error) {
        await release();
        setMode(_Mode.idle);
        if (mounted.value) toast(_transcribeFailed(error));
        return;
      }
      await release();
      if (text.isEmpty) {
        setMode(_Mode.idle);
        if (mounted.value) toast("Didn't catch that");
        return;
      }
      await deliver(text);
    }

    Future<void> startRecording() async {
      if (mode.value != _Mode.idle) return;
      FocusScope.of(context).unfocus();
      final current = ref.read(catchUpDictationFactoryProvider)();
      dictation.value = current;
      levels.value = const [];
      setMode(_Mode.recording);
      try {
        await current.start();
      } catch (error) {
        await release();
        setMode(_Mode.idle);
        if (mounted.value) {
          toast(
            error is CatchUpMicDenied
                ? 'Allow microphone access in Settings to talk a reply.'
                : "Couldn't start the microphone.",
          );
        }
        return;
      }
      if (!identical(dictation.value, current)) return; // discarded meanwhile
      levelSub.value = current.levels.listen((level) {
        if (!mounted.value) return;
        final next = [...levels.value, level];
        levels.value = next.length > 40 ? next.sublist(next.length - 40) : next;
      });
      limit.value = Timer(
        catchUpDictationMaxDuration,
        () => unawaited(finishRecording()),
      );
    }

    Future<void> discard() async {
      final current = dictation.value;
      if (current == null) return;
      limit.value?.cancel();
      try {
        await current.cancel();
      } catch (_) {}
      await release();
      levels.value = const [];
      setMode(_Mode.idle);
    }

    final busy =
        mode.value == _Mode.transcribing || mode.value == _Mode.sending;
    final hasText = controller.text.trim().isNotEmpty;
    final colors = context.colors;

    final Widget field;
    if (mode.value == _Mode.recording) {
      field = Row(
        children: [
          IconButton(
            key: const ValueKey('catch-up-reply-discard'),
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
                  painter: _LevelsPainter(levels.value, colors.primary),
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
            Text(
              mode.value == _Mode.transcribing ? 'Transcribing…' : 'Sending…',
              style: context.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    } else {
      field = TextField(
        key: const ValueKey('catch-up-reply-field'),
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
        key: const ValueKey('catch-up-reply-mic-send'),
        tooltip: 'Send voice reply',
        icon: const Icon(BuzzIcons.arrowUp, size: 20),
        onPressed: () => unawaited(finishRecording()),
      );
    } else if (hasText && !busy) {
      action = IconButton.filled(
        key: const ValueKey('catch-up-reply-send'),
        tooltip: 'Send reply',
        icon: const Icon(BuzzIcons.arrowUp, size: 20),
        onPressed: () => unawaited(sendTyped()),
      );
    } else {
      action = IconButton.filledTonal(
        key: const ValueKey('catch-up-reply-mic'),
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

class _LevelsPainter extends CustomPainter {
  _LevelsPainter(this.levels, this.color);
  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const bar = 3.0;
    const gap = 3.0;
    final count = (size.width / (bar + gap)).floor();
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = bar;
    final shown = levels.length > count
        ? levels.sublist(levels.length - count)
        : levels;
    final mid = size.height / 2;
    for (var i = 0; i < count; i++) {
      final at = i - (count - shown.length);
      final level = at >= 0 ? shown[at] : 0.04;
      final half = math.max(1.5, level * size.height / 2);
      final x = i * (bar + gap) + bar / 2;
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }
  }

  @override
  bool shouldRepaint(_LevelsPainter old) =>
      old.levels != levels || old.color != color;
}
