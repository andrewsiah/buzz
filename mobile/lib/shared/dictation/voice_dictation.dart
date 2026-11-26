/// Talking instead of typing: records a short 16 kHz mono WAV (as Snack web
/// records) and turns it into text with Snack Cloud's speech to text. Used by
/// the chat composer's mic and the Catch-up reply box.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../snack/snack_account.dart';

/// Longest spoken message. Snack Cloud takes about 3 MB of base64 WAV, and
/// 16 kHz mono 16-bit is ~43 kB/s once encoded, so a minute fits.
const voiceDictationMaxDuration = Duration(seconds: 60);

/// The most WAV sent for one message (base64 then stays under Snack Cloud's
/// 3 MB body), in case a device records above 16 kHz.
const voiceDictationMaxBytes = 2200000;

/// Speech to text for a recorded WAV, through Snack Cloud.
typedef VoiceTranscriber =
    Future<String> Function(String channelId, Uint8List wav);

/// One spoken message: 16 kHz mono WAV, as Snack web records.
abstract interface class VoiceDictation {
  /// Input level, 0..1, while recording.
  Stream<double> get levels;

  /// Throws [VoiceDictationMicDenied] without microphone access.
  Future<void> start();

  /// The finished recording's WAV bytes.
  Future<Uint8List> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  Future<void> dispose();
}

class VoiceDictationMicDenied implements Exception {
  const VoiceDictationMicDenied();
}

/// Text the e2e test "says" into the mic on the simulator, which has no
/// microphone and no speech to text on its test stack. Empty in real builds.
const _e2eDictation = String.fromEnvironment('SNACK_E2E_DICTATION');

final voiceDictationFactoryProvider = Provider<VoiceDictation Function()>(
  (ref) => _e2eDictation.isNotEmpty
      ? _ScriptedVoiceDictation.new
      : DeviceVoiceDictation.new,
);

final voiceTranscriberProvider = Provider<VoiceTranscriber>((ref) {
  if (_e2eDictation.isNotEmpty) return (_, _) async => _e2eDictation;
  final account = ref.read(snackAccountProvider);
  return account.transcribe;
});

/// Records with the `record` plugin to a temporary WAV file.
class DeviceVoiceDictation implements VoiceDictation {
  DeviceVoiceDictation({AudioRecorder? recorder})
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
    if (!await _recorder.hasPermission()) throw const VoiceDictationMicDenied();
    final directory = await getTemporaryDirectory();
    if (_disposed) throw StateError('Recording was cancelled.');
    final path =
        '${directory.path}${Platform.pathSeparator}'
        'voice-dictation-${DateTime.now().microsecondsSinceEpoch}.wav';
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
class _ScriptedVoiceDictation implements VoiceDictation {
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

class DictationLevelsPainter extends CustomPainter {
  DictationLevelsPainter(this.levels, this.color);
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
  bool shouldRepaint(DictationLevelsPainter old) =>
      old.levels != levels || old.color != color;
}
