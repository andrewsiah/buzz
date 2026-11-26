// Replying from Catch-up without leaving the stack: a typed reply and a
// spoken one go to the card's conversation or thread and bring up the next
// card; X throws a recording away; an empty transcript sends nothing; a
// failed send keeps the draft and the card.
import 'dart:async';

import 'package:buzz/features/catch_up/catch_up_page.dart';
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:buzz/features/catch_up/catch_up_reader.dart';
import 'package:buzz/features/catch_up/catch_up_reply.dart';
import 'package:buzz/shared/dictation/voice_dictation.dart';
import 'package:buzz/features/catch_up/catch_up_sources.dart';
import 'package:buzz/features/catch_up/catch_up_state.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/widget_helpers.dart';
import 'catch_up_card_test.dart' show cardOverrides;
import 'catch_up_page_test.dart' show channel, entry;
import 'catch_up_read_test.dart' show FakeReader;

typedef Sent = ({String channelId, String? rootId, String content});

class FakeDictation implements VoiceDictation {
  final log = <String>[];
  final _levels = StreamController<double>.broadcast();

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> start() async {
    log.add('start');
    _levels.add(0.5);
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

void main() {
  testWidgets('replies from the stack, typed and spoken', (tester) async {
    final reader = FakeReader();
    final sent = <Sent>[];
    Object? sendError;
    final dictations = <FakeDictation>[];
    var transcript = '';
    Completer<void>? gate;
    final heard = <(String, int)>[];
    await tester.pumpWidget(
      WidgetHelpers.testable(
        overrides: [
          ...cardOverrides(),
          catchUpEntriesProvider.overrideWithValue([
            entry('alice', 300, dm: true),
            const CatchUpEntry(
              key: 'launch:root1',
              channelId: 'launch',
              rootId: 'root1',
              latestMessageId: 'r2',
              dm: false,
              attention: true,
              count: 1,
              manual: false,
              latest: 250,
            ),
          ]),
          catchUpLoadingProvider.overrideWithValue(false),
          catchUpChannelsProvider.overrideWithValue([
            channel('alice', type: 'dm'),
            channel('launch'),
          ]),
          catchUpStateProvider.overrideWith((ref) => CatchUpState()),
          catchUpReaderProvider.overrideWithValue(reader),
          myPubkeyProvider.overrideWithValue('a' * 64),
          catchUpReplySenderProvider.overrideWithValue(({
            required channelId,
            required channel,
            rootId,
            required content,
          }) async {
            if (sendError != null) throw sendError;
            sent.add((channelId: channelId, rootId: rootId, content: content));
          }),
          voiceDictationFactoryProvider.overrideWithValue(() {
            final dictation = FakeDictation();
            dictations.add(dictation);
            return dictation;
          }),
          voiceTranscriberProvider.overrideWithValue((channelId, wav) async {
            heard.add((channelId, wav.length));
            await gate?.future;
            return transcript;
          }),
        ],
        child: const CatchUpPage(),
      ),
    );
    await tester.pump();
    expect(find.text('2 Left'), findsOneWidget);
    expect(find.text('Direct message'), findsOneWidget);

    final field = find.byKey(const ValueKey('catch-up-reply-field'));
    final sendButton = find.byKey(const ValueKey('catch-up-reply-send'));
    final mic = find.byKey(const ValueKey('catch-up-reply-mic'));

    // Empty box: the round mic, no send button.
    expect(mic, findsOneWidget);
    expect(sendButton, findsNothing);

    // A failed send keeps the draft and the card, and says so.
    sendError = StateError('Reconnect first.');
    await tester.enterText(field, 'see you at 3');
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pump();
    expect(sent, isEmpty);
    expect(find.text('Not sent. Reconnect first.'), findsOneWidget);
    expect(find.text('2 Left'), findsOneWidget);
    expect(find.text('see you at 3'), findsOneWidget);
    expect(reader.calls, isEmpty);

    // Typed: posts in the DM, reads the card, the next one comes up.
    sendError = null;
    await tester.tap(sendButton);
    await tester.pump();
    expect(sent, [(channelId: 'alice', rootId: null, content: 'see you at 3')]);
    expect(reader.calls['markChannelRead'], ['alice']);
    expect(find.text('1 Left'), findsOneWidget);
    expect(find.text('New replies in a thread'), findsOneWidget);
    expect(find.text('see you at 3'), findsNothing);

    // A hardware key typed into the reply is text, not Catch-up's Undo.
    await tester.tap(field);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(find.text('1 Left'), findsOneWidget);

    // Mic, then X: the recording is thrown away and nothing is sent.
    await tester.tap(mic);
    await tester.pump();
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Recording'), findsOneWidget);
    expect(find.byTooltip('Discard recording'), findsOneWidget);
    semantics.dispose();
    await tester.tap(find.byKey(const ValueKey('catch-up-reply-discard')));
    await tester.pump();
    expect(dictations.single.log, ['start', 'cancel', 'dispose']);
    expect(heard, isEmpty);
    expect(mic, findsOneWidget);

    // Nothing heard: "Didn't catch that", nothing sent, the card stays.
    await tester.tap(mic);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('catch-up-reply-mic-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(dictations[1].log, ['start', 'stop', 'dispose']);
    expect(heard, [('launch', 3244)]);
    expect(find.text("Didn't catch that"), findsOneWidget);
    expect(sent, hasLength(1));
    expect(find.text('1 Left'), findsOneWidget);

    // Spoken: the transcript goes straight into the thread, no edit step,
    // even when the card was marked read while it was being transcribed.
    transcript = 'on it';
    gate = Completer();
    await tester.tap(mic);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('catch-up-reply-mic-send')));
    await tester.pump();
    expect(find.text('Transcribing…'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Mark as read'));
    await tester.pump();
    expect(find.text("You're all caught up"), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(sent.last, (channelId: 'launch', rootId: 'root1', content: 'on it'));
    expect(reader.calls['readThread'], ['launch', 'root1']);
    expect(find.text("You're all caught up"), findsOneWidget);
  });
}
