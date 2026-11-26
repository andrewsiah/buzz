part of '../compose_bar_test.dart';

class _FakeVoiceDictation implements VoiceDictation {
  _FakeVoiceDictation({this.denied = false});

  final bool denied;
  final log = <String>[];
  final _levels = StreamController<double>.broadcast();

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> start() async {
    log.add('start');
    if (denied) throw const VoiceDictationMicDenied();
    _levels.add(0.6);
  }

  @override
  Future<Uint8List> stop() async {
    log.add('stop');
    return silentWav(const Duration(milliseconds: 100));
  }

  @override
  Future<void> cancel() async => log.add('cancel');

  @override
  Future<void> dispose() async {
    log.add('dispose');
    await _levels.close();
  }
}

void dictationTests() {
  testWidgets('the mic types or sends what was said, like Snack web', (
    tester,
  ) async {
    final sent = <String>[];
    final dictations = <_FakeVoiceDictation>[];
    final heard = <String>['hello there', 'ship it', '', 'never', 'kept'];
    final transcribed = <String>[];
    var denyNext = false;
    Completer<void>? hold;

    Widget composer({String? threadHeadId}) => _buildComposeBar(
      threadHeadId: threadHeadId,
      uploadService: _testUploadService(nostr.Keys.generate().nsec),
      onSend: (content, mentionPubkeys, {mediaTags = const []}) async =>
          sent.add(content),
      overrides: [
        voiceDictationFactoryProvider.overrideWithValue(() {
          final dictation = _FakeVoiceDictation(denied: denyNext);
          dictations.add(dictation);
          return dictation;
        }),
        voiceTranscriberProvider.overrideWithValue((channelId, wav) async {
          if (hold != null) await hold.future;
          transcribed.add(channelId);
          return heard.removeAt(0);
        }),
      ],
    );
    await tester.pumpWidget(composer());
    final mic = find.byKey(const ValueKey('composer-mic')).hitTestable();
    final send = find.ancestor(
      of: find.byIcon(BuzzIcons.arrowUp),
      matching: find.byType(IconButton),
    );

    // Empty composer: the mic sits where Send goes, with a spoken label.
    expect(mic, findsOneWidget);
    expect(find.byTooltip('Voice typing').hitTestable(), findsOneWidget);
    expect(send, findsNothing);

    // X throws the recording away and brings the mic back.
    await tester.tap(mic);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-dictation')), findsOneWidget);
    expect(find.bySemanticsLabel('Listening'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel voice typing'));
    await tester.pumpAndSettle();
    expect(dictations.single.log, ['start', 'dispose']);
    expect(mic, findsOneWidget);
    expect(transcribed, isEmpty);

    // Stop types the words into the box for editing; then Send sends them.
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and turn into text'));
    await tester.pumpAndSettle();
    expect(transcribed, ['channel-1']);
    expect(dictations[1].log, ['start', 'stop', 'dispose']);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'hello there');
    expect(mic, findsNothing);
    expect(sent, isEmpty);
    await tester.tap(send.hitTestable().first);
    await tester.pumpAndSettle();
    expect(sent, ['hello there']);

    // The strip's Send stops and sends in one tap.
    expect(mic, findsOneWidget);
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and send'));
    await tester.pumpAndSettle();
    expect(sent, ['hello there', 'ship it']);

    // Hearing nothing sends nothing and says so.
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and send'));
    await tester.pumpAndSettle();
    expect(find.text("Didn't catch that. Try again."), findsOneWidget);
    expect(sent, hasLength(2));

    // Cancelling while transcribing drops the words when they arrive.
    hold = Completer<void>();
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and send'));
    await tester.pump();
    expect(find.bySemanticsLabel('Turning speech into text'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel voice typing'));
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(find.textContaining('never'), findsNothing);

    // Words already on their way to text still land if the app goes to the
    // background; an open mic is thrown away.
    hold = Completer<void>();
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and send'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    hold.complete();
    hold = null;
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(sent, ['hello there', 'ship it', 'kept']);

    await tester.tap(mic);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(dictations.last.log, ['start', 'dispose']);
    expect(mic, findsOneWidget);

    // Switching conversations throws an open recording away too.
    await tester.tap(mic);
    await tester.pumpAndSettle();
    await tester.pumpWidget(composer(threadHeadId: 'thread-1'));
    await tester.pumpAndSettle();
    expect(dictations.last.log, ['start', 'dispose']);
    expect(find.byKey(const ValueKey('composer-dictation')), findsNothing);
    expect(sent, hasLength(3));

    // No microphone access: a clear message, and the mic is back.
    denyNext = true;
    await tester.tap(mic);
    await tester.pumpAndSettle();
    expect(
      find.text('Allow microphone access in Settings to talk a message.'),
      findsOneWidget,
    );
    expect(mic, findsOneWidget);
  });
}
