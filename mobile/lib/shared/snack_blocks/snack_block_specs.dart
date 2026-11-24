import 'dart:convert';
import 'dart:math' as math;

/// Fenced code block languages Snack draws as cards instead of code:
/// `snack-progress` (a background job's live card), `snack-choices` (a
/// question with tap-to-answer options) and `buzz-chart` (a chart).
///
/// The grammar follows Snack's web app (src/bundled/snack-progress,
/// snack-goals and charts), so both clients read the same blocks.
const snackBlockLanguages = {'snack-progress', 'snack-choices', 'buzz-chart'};

/// Whether [language] names a Snack card block.
bool isSnackBlockLanguage(String language) =>
    snackBlockLanguages.contains(language.trim().toLowerCase());

const _maxItems = 50;

String _text(Object? value, int max) {
  if (value is! String) return '';
  final squashed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return squashed.length > max ? squashed.substring(0, max) : squashed;
}

int _seconds(Object? value) =>
    value is num && value.isFinite && value > 0 ? value.floor() : 0;

List<Object?> _list(Object? value) {
  if (value is! List) return const [];
  return value.length > _maxItems
      ? value.sublist(value.length - _maxItems)
      : value;
}

String _pick(Object? value, List<String> allowed, String fallback) =>
    value is String && allowed.contains(value) ? value : fallback;

Map<String, Object?>? _object(String code) {
  try {
    final raw = jsonDecode(code);
    return raw is Map<String, Object?> ? raw : null;
  } on FormatException {
    return null;
  }
}

/// One step of a background job.
class SnackProgressStep {
  const SnackProgressStep({
    required this.kind,
    required this.text,
    required this.state,
  });

  /// shell, web, read, edit, search, think, agent or tool.
  final String kind;
  final String text;

  /// running, done or failed.
  final String state;
}

/// A `snack-progress` block: an agent's background job, updated as it runs.
class SnackProgress {
  const SnackProgress({
    required this.title,
    required this.status,
    required this.startedAt,
    required this.updatedAt,
    required this.finishedAt,
    required this.steps,
    required this.count,
    required this.planDone,
    required this.planTotal,
    required this.activePlan,
    required this.agent,
  });

  final String title;

  /// running, done, failed or stopped.
  final String status;

  /// Unix seconds.
  final int startedAt;
  final int updatedAt;
  final int? finishedAt;
  final List<SnackProgressStep> steps;

  /// How many steps the job has taken, including ones no longer listed.
  final int count;
  final int planDone;
  final int planTotal;

  /// The plan item being worked on, if any.
  final String? activePlan;
  final String? agent;

  /// A running card that hasn't changed for this long has lost its worker.
  static const staleSeconds = 6 * 60;

  /// Parses a block's JSON, or returns null when it can't be read (for
  /// example while the agent is still writing it).
  static SnackProgress? parse(String code) {
    final value = _object(code);
    if (value == null) return null;
    final title = _text(value['title'], 200);
    final startedAt = _seconds(value['startedAt']);
    if (title.isEmpty || startedAt == 0) return null;
    final steps = <SnackProgressStep>[];
    for (final step in _list(value['steps'])) {
      if (step is! Map) continue;
      final kind = _pick(step['kind'], const [
        'shell',
        'web',
        'read',
        'edit',
        'search',
        'think',
        'agent',
        'tool',
      ], 'tool');
      final label = _text(step['text'], 300);
      final detail = _text(step['detail'], 1000);
      // Older cards name a shell step by its raw command.
      final raw =
          kind == 'shell' &&
          (detail.isNotEmpty ? label == detail : isShellCommand(label));
      final text = raw ? shellCommandLabel(label) : label;
      if (text.isEmpty) continue;
      steps.add(
        SnackProgressStep(
          kind: kind,
          text: text,
          state: _pick(step['state'], const [
            'running',
            'done',
            'failed',
          ], 'done'),
        ),
      );
    }
    var planDone = 0;
    var planTotal = 0;
    String? activePlan;
    for (final item in _list(value['plan'])) {
      if (item is! Map) continue;
      final text = _text(item['text'], 200);
      if (text.isEmpty) continue;
      planTotal++;
      final state = item['state'];
      if (state == 'done') planDone++;
      if (state == 'active') activePlan ??= text;
    }
    final finishedAt = _seconds(value['finishedAt']);
    final agent = _text(value['agent'], 100);
    return SnackProgress(
      title: title,
      status: _pick(value['status'], const [
        'running',
        'done',
        'failed',
        'stopped',
      ], 'running'),
      startedAt: startedAt,
      updatedAt: math.max(_seconds(value['updatedAt']), startedAt),
      finishedAt: finishedAt == 0 ? null : finishedAt,
      steps: steps,
      count: math.max(_seconds(value['count']), steps.length),
      planDone: planDone,
      planTotal: planTotal,
      activePlan: activePlan,
      agent: agent.isEmpty ? null : agent,
    );
  }

  /// Whether a running job has gone quiet for too long at [now] (Unix s).
  bool isStale(int now) =>
      status == 'running' && now - updatedAt > staleSeconds;

  /// The header's status word at [now], as on the web card.
  String label(int now) => isStale(now)
      ? 'No update for ${snackDuration(now - updatedAt)}'
      : switch (status) {
          'done' => 'Done',
          'failed' => "Couldn't finish",
          'stopped' => 'Stopped',
          _ => 'Working',
        };

  /// How long the job ran (or has been running) at [now].
  String elapsed(int now) {
    final end = status == 'running' ? now : (finishedAt ?? updatedAt);
    return snackDuration(math.max(0, end - startedAt));
  }

  /// "13 steps", or "1 step".
  String get stepCount => count == 1 ? '1 step' : '$count steps';

  /// One line for previews, which don't tick: a running job shows no
  /// status word, since it could go quiet unseen ("Ship · 13 steps").
  String get summary => status == 'running'
      ? '$title · $stepCount'
      : '${label(0)} · $title · $stepCount';
}

/// "42s", "3m 5s" or "2h 4m".
String snackDuration(int total) {
  final s = math.max(0, total);
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ${s % 60}s';
  return '${m ~/ 60}h ${m % 60}m';
}

/// Whether a shell step's text is a command rather than a description.
bool isShellCommand(String line) =>
    RegExp(r'^[a-z0-9_.~/$({]').hasMatch(line) ||
    RegExp(r'\s(&&|\|\||;|\|)\s?').hasMatch(line);

final _skip = RegExp(r'^(cd|export|set|source|\.|true|:|unset|pushd|popd)$');
const _verbs = {
  'cat': 'Read a file',
  'head': 'Read a file',
  'tail': 'Read a file',
  'less': 'Read a file',
  'ls': 'Looked through files',
  'find': 'Looked through files',
  'tree': 'Looked through files',
  'grep': 'Searched files',
  'rg': 'Searched files',
  'mkdir': 'Made a folder',
  'rm': 'Removed files',
  'cp': 'Copied files',
  'mv': 'Moved files',
  'echo': 'Printed a note',
  'chmod': 'Changed permissions',
  'tar': 'Packed files',
  'unzip': 'Unpacked files',
  'ps': 'Checked running programs',
  'kill': 'Stopped a program',
  'pkill': 'Stopped a program',
  'jq': 'Read some JSON',
};

/// A short, plain label for a shell command, as the web card shows it:
/// `cd ~ && buzz channels list` is "Ran buzz channels".
String shellCommandLabel(String command) {
  final loop = RegExp(
    r'(?:^|&&|;)\s*(for|while|until)\b[^;]*;\s*do\s+(.*?)(;\s*done.*)?$',
  ).firstMatch(command);
  if (loop != null && (loop[2] ?? '').isNotEmpty) {
    final inner = shellCommandLabel(loop[2]!);
    return inner == 'Ran a command' ? 'Ran a loop' : inner;
  }
  final parts = command
      .split(RegExp(r'\s*(?:&&|\|\||;|\|)\s*'))
      .map(
        (part) => part
            .trim()
            .replaceFirst(RegExp(r'^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+'), '')
            .replaceFirst(
              RegExp(r'^(?:sudo|time|nohup|exec|env|npx|timeout\s+\S+)\s+'),
              '',
            )
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty)
            .toList(),
      )
      .where(
        (words) =>
            words.isNotEmpty &&
            !_skip.hasMatch(words.first) &&
            !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words.first),
      )
      .toList();
  final work = parts.where((words) => words.first != 'sleep').toList();
  final chosen = work.isNotEmpty
      ? work.first
      : (parts.isNotEmpty ? parts.first : const <String>[]);
  if (chosen.isEmpty) return 'Ran a command';
  final program = chosen.first;
  final args = chosen.sublist(1);
  if (program == 'sleep') {
    return args.isNotEmpty && RegExp(r'^\d+$').hasMatch(args.first)
        ? 'Waited ${args.first}s'
        : 'Waited';
  }
  final name = program.split('/').last;
  if (name == 'curl' || name == 'wget') {
    final url = args.firstWhere(
      (arg) => RegExp(r'^https?://').hasMatch(arg),
      orElse: () => '',
    );
    final host = RegExp(r'^https?://([^/:?#]+)').firstMatch(url)?[1];
    return host != null ? 'Fetched $host' : 'Made a web request';
  }
  final verb = _verbs[name];
  if (verb != null) return verb;
  final sub = args.firstWhere((arg) => !arg.startsWith('-'), orElse: () => '');
  return RegExp(r'^[a-z][a-z0-9:-]{0,24}$').hasMatch(sub)
      ? 'Ran $name $sub'
      : 'Ran $name';
}

/// A `snack-choices` block: a question and up to six options.
class SnackChoices {
  const SnackChoices({required this.question, required this.options});

  final String question;
  final List<String> options;

  static SnackChoices? parse(String code) {
    final value = _object(code);
    if (value == null) return null;
    final raw = value['options'];
    final options = (raw is List ? raw : const [])
        .map((option) => _text(option, 120))
        .where((option) => option.isNotEmpty)
        .take(6)
        .toList();
    if (options.isEmpty) return null;
    return SnackChoices(
      question: _text(value['question'], 300),
      options: options,
    );
  }

  String get summary => question.isNotEmpty ? question : options.join(' / ');
}

/// One point of a simple chart.
typedef SnackChartPoint = ({String label, double x, double y});

/// A `buzz-chart` block. Version 1 bar, line and scatter plots without a
/// series field are drawn natively ([points] is non-empty); anything else
/// keeps just its title.
class SnackChart {
  const SnackChart({
    required this.title,
    required this.type,
    required this.points,
  });

  final String title;

  /// bar, line or scatter; empty when not drawn natively.
  final String type;
  final List<SnackChartPoint> points;

  static const maxPoints = 200;

  /// Never null: a chart that can't be read still has a label.
  static SnackChart parse(String code) {
    final value = _object(code);
    if (value == null) {
      return const SnackChart(title: '', type: '', points: []);
    }
    final title = _text(value['title'], 120);
    final type = value['type'];
    final x = value['x'];
    final y = value['y'];
    final data = value['data'];
    if (value['version'] != 1 ||
        !const ['bar', 'line', 'scatter'].contains(type) ||
        x is! String ||
        y is! String ||
        value['series'] != null ||
        data is! List ||
        data.isEmpty ||
        data.length > maxPoints) {
      return SnackChart(title: title, type: '', points: const []);
    }
    final points = <SnackChartPoint>[];
    for (final (index, row) in data.indexed) {
      if (row is! Map) continue;
      final yv = row[y];
      if (yv is! num || !yv.isFinite) continue;
      final xv = row[x];
      final label = xv is String ? xv : (xv is num ? _number(xv) : '');
      final xNum = type == 'scatter' && xv is num && xv.isFinite
          ? xv.toDouble()
          : index.toDouble();
      points.add((label: label, x: xNum, y: yv.toDouble()));
    }
    return SnackChart(
      title: title,
      type: points.isEmpty ? '' : type as String,
      points: points,
    );
  }

  String get summary => title.isEmpty ? 'Chart' : 'Chart: $title';
}

String _number(num value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

/// The one-line stand-in for a Snack card block in a preview, or null when
/// [language] is an ordinary code block.
String? snackBlockSummary(String language, String code) {
  switch (language.trim().toLowerCase()) {
    case 'snack-progress':
      return SnackProgress.parse(code)?.summary ?? 'Progress';
    case 'snack-choices':
      return SnackChoices.parse(code)?.summary ?? 'Choices';
    case 'buzz-chart':
      return SnackChart.parse(code).summary;
  }
  return null;
}

/// [content] with each Snack card block replaced by its one-line summary,
/// for places that show a message as plain text.
String snackBlocksAsText(String content) => !content.contains('```')
    ? content
    : [
        for (final segment in splitSnackBlocks(content))
          switch (segment.language) {
            final language? => snackBlockSummary(language, segment.text)!,
            null => segment.text,
          },
      ].join('\n');

/// A piece of message text: plain Markdown, or a Snack card block.
typedef SnackBlockSegment = ({String text, String? language});

final _fence = RegExp(r'^[ \t]*```[ \t]*([A-Za-z0-9_-]+)[^\n]*$');

/// Splits [content] into text and Snack card blocks, keeping every other
/// fenced block inside the text around it. An unclosed card block (an agent
/// still writing it) runs to the end.
List<SnackBlockSegment> splitSnackBlocks(String content) {
  if (!content.contains('```')) return [(text: content, language: null)];
  final lines = content.split('\n');
  final segments = <SnackBlockSegment>[];
  final text = StringBuffer();
  var otherFence = false;
  void flushText() {
    final value = text.toString();
    if (value.trim().isNotEmpty) {
      segments.add((text: value.trimRight(), language: null));
    }
    text.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (otherFence) {
      if (trimmed == '```') otherFence = false;
      text.writeln(line);
      continue;
    }
    final open = _fence.firstMatch(line);
    if (open != null && isSnackBlockLanguage(open[1]!)) {
      flushText();
      final code = StringBuffer();
      var j = i + 1;
      while (j < lines.length && lines[j].trim() != '```') {
        code.writeln(lines[j]);
        j++;
      }
      segments.add((
        text: code.toString().trimRight(),
        language: open[1]!.toLowerCase(),
      ));
      i = j;
      continue;
    }
    if (trimmed.startsWith('```')) otherFence = true;
    text.writeln(line);
  }
  flushText();
  return segments;
}
