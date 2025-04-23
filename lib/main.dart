import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:csv/csv.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:isar/isar.dart';
import 'package:llama_sdk/llama_sdk.dart'
    if (dart.library.html) 'package:llama_sdk/llama_sdk.web.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/sheet.dart';

/// Wrapper around `developer.log` so we can tweak from one place.
void _log(
  String msg, {
  Object? error,
  StackTrace? st,
  int lvl = 0, // 0-info, 500-warning, 1000-error
}) =>
    dev.log(
      msg,
      name: 'PlotPad',
      level: lvl,
      error: error,
      stackTrace: st,
      time: DateTime.now(),
    );

/* ───── Riverpod providers ───── */

final dbP = Provider<Isar>((_) => throw UnimplementedError());
final sheetsP = StreamProvider.autoDispose(
  (r) => r.watch(dbP).sheets.where().watch(fireImmediately: true),
);
final queryP = StateProvider.autoDispose((_) => '');
final viewP = Provider.autoDispose((r) {
  final q = r.watch(queryP).toLowerCase();
  final l = r.watch(sheetsP).value ?? const <Sheet>[];
  return q.isEmpty
      ? l
      : l
          .where(
            (s) =>
                s.name.toLowerCase().contains(q) ||
                s.tags.any((t) => t.toLowerCase().contains(q)),
          )
          .toList();
});
final ctrlP = Provider.autoDispose((r) => Ctrl(r.read(dbP)));

/* ───── ChartSpec ───── */

class ChartSpec {
  final String title;
  final Widget view;
  const ChartSpec._(this.title, this.view);

  factory ChartSpec.scatter(String t, List<FlSpot> pts) {
    _log('Created scatter "$t" with ${pts.length} pts');
    return ChartSpec._(
      t,
      ScatterChart(
        ScatterChartData(
          scatterSpots: [for (final p in pts) ScatterSpot(p.x, p.y)],
        ),
      ),
    );
  }

  factory ChartSpec.line(String t, List<FlSpot> pts) {
    _log('Created line "$t" with ${pts.length} pts');
    return ChartSpec._(
      t,
      LineChart(LineChartData(lineBarsData: [LineChartBarData(spots: pts)])),
    );
  }

  factory ChartSpec.bar(String t, List<BarChartRodData> rods) {
    _log('Created bar "$t" with ${rods.length} bars');
    return ChartSpec._(
      t,
      BarChart(
        BarChartData(
          barGroups: [
            for (var i = 0; i < rods.length; i++)
              BarChartGroupData(x: i, barRods: [rods[i]]),
          ],
        ),
      ),
    );
  }

  factory ChartSpec.histogram(String t, List<FlSpot> pts) =>
      ChartSpec.line(t, pts);

  factory ChartSpec.pie(String t, List<PieChartSectionData> slices) {
    _log('Created pie "$t" with ${slices.length} slices');
    return ChartSpec._(
      t,
      PieChart(PieChartData(sections: slices, sectionsSpace: 2)),
    );
  }

  factory ChartSpec.radar(
    String t,
    List<RadarEntry> entries,
    List<String> labels,
  ) {
    _log('Created radar "$t" (${labels.length} axes)');
    return ChartSpec._(
      t,
      RadarChart(
        RadarChartData(
          dataSets: [RadarDataSet(dataEntries: entries)],
          getTitle: (i, a) => RadarChartTitle(text: labels[i], angle: a),
        ),
      ),
    );
  }
}

/* ───── Controller (Persistence, Crypto, LLM) ───── */

class Ctrl {
  Ctrl(this.db) : storage = const FlutterSecureStorage() {
    _log('Ctrl instantiated');
  }

  final Isar db;
  final FlutterSecureStorage storage;

/* ---------- cryptography ---------- */

  static const _rounds = 10000;
  Future<Uint8List> _key(String pwd, List<int> salt) async {
    _log('Deriving PBKDF2 key');
    return Uint8List.fromList(
      await crypto.Pbkdf2(
        macAlgorithm: crypto.Hmac.sha256(),
        iterations: _rounds,
        bits: 256,
      ).deriveKey(secretKey: crypto.SecretKey(utf8.encode(pwd)), nonce: salt)
          .then((k) => k.extractBytes()),
    );
  }

  enc.Encrypter _aes(Uint8List k) =>
      enc.Encrypter(enc.AES(enc.Key(k), mode: enc.AESMode.cbc));

/* ---------- lock / unlock ---------- */

  Future<void> lock(Sheet s, String pwd) async {
    if (s.csv.trim().isEmpty) return;
    _log('Locking sheet id=${s.id}');
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final iv = enc.IV.fromSecureRandom(16);
    final cipher = _aes(await _key(pwd, salt)).encrypt(s.csv, iv: iv).base64;
    final id = 'sec-${s.id}-${DateTime.now().millisecondsSinceEpoch}';
    await storage.write(
      key: id,
      value: jsonEncode({'salt': base64Encode(salt), 'iv': iv.base64}),
    );
    db.write(
      (i) => i.sheets.put(
        s
          ..enc = true
          ..csv = cipher
          ..secretId = id,
      ),
    );
    _log('Sheet ${s.id} locked');
  }

  Future<String?> unlock(Sheet s, String pwd) async {
    if (!s.enc) return s.csv;
    _log('Unlocking sheet id=${s.id}');
    final meta = await storage.read(key: s.secretId!);
    if (meta == null) {
      _log('Secure-store meta missing for ${s.secretId}', lvl: 900);
      return null;
    }
    final j = jsonDecode(meta);
    final key = await _key(pwd, base64Decode(j['salt']));
    try {
      final plain = _aes(key).decrypt(
        enc.Encrypted.fromBase64(s.csv),
        iv: enc.IV(base64Decode(j['iv'])),
      );
      _log('Unlock OK for id=${s.id}');
      return plain;
    } on ArgumentError catch (e, st) {
      _log('Unlock FAILED id=${s.id}', error: e, st: st, lvl: 1000);
      return null;
    }
  }

  void setCsv(Sheet s, String csv) {
    _log('Updating CSV for id=${s.id} (len=${csv.length})');
    db.write((i) => i.sheets.put(s..csv = csv));
  }

/* ---------- LLM-driven chart generation ---------- */

  Future<List<ChartSpec>> charts(Sheet s) async {
    _log('charts() start for id=${s.id}');
    // 1. parse CSV
    final rows = const CsvToListConverter(eol: '\n')
        .convert(s.csv.replaceAll(r'\n', '\n'));
    if (rows.length < 2) {
      _log('Not enough rows for charting', lvl: 500);
      return [];
    }
    final header = rows.first.cast<String>();
    final types = _profile(rows);

    // 2. prompt Llama
    final llama = await _llama();
    final prompt = _buildPrompt(header, types);
    _log('Prompting Llama (${prompt.length} chars)');
    final resp = await llama
        .prompt([UserLlamaMessage(prompt)])
        .fold<String>('', (a, b) => a + b);
    llama.reload(); // reset KV-cache
    _log('LLM response chars=${resp.length}');

    // 3. extract JSON
    final jsonTxt = _extractJson(resp);
    if (jsonTxt == null) {
      _log('No JSON found from LLM', lvl: 900);
      return [];
    }
    _log('LLM JSON: $jsonTxt');

    // 4. build chart specs
    final specs = <ChartSpec>[];
    for (final m in jsonDecode(jsonTxt) as List) {
      try {
        switch (m['type']) {
          case 'scatter':
            final d = _scatter(rows, m['x'], m['y']);
            if (d.isNotEmpty) {
              specs.add(
                ChartSpec.scatter(m['title'] ?? '${m['y']} vs ${m['x']}', d),
              );
            }
            break;
          case 'line':
            final d = _line(rows, m['x'], m['y']);
            if (d.isNotEmpty) {
              specs.add(
                ChartSpec.line(m['title'] ?? '${m['y']} over ${m['x']}', d),
              );
            }
            break;
          case 'bar':
            final d = _bars(rows, m['x'], m['y'], m['agg']);
            if (d.isNotEmpty) specs.add(ChartSpec.bar(m['title'] ?? m['x'], d));
            break;
          case 'histogram':
            final d = _hist(rows, m['x']);
            if (d.isNotEmpty) {
              specs.add(ChartSpec.histogram(m['title'] ?? m['x'], d));
            }
            break;
          case 'pie':
            final d = _pie(rows, m['x'], m['y'], m['agg']);
            if (d.isNotEmpty) specs.add(ChartSpec.pie(m['title'] ?? m['x'], d));
            break;
          case 'radar':
            final cols = (m['cols'] as List?)?.cast<String>() ?? [];
            final res = _radar(rows, cols);
            if (res != null) {
              specs.add(
                ChartSpec.radar(m['title'] ?? 'Radar', res.entries, res.labels),
              );
            }
        }
      } catch (e, st) {
        _log('Chart build error for spec $m', error: e, st: st, lvl: 1000);
      }
    }
    _log('charts() produced ${specs.length} specs');
    return specs;
  }

/* ---------- helpers ---------- */

  String _buildPrompt(List<String> header, List<String> types) => '''
You are an expert data-visualisation assistant.
Choose up to 3 charts that best reveal patterns.
Return ONLY JSON array, no prose, no markdown.

Columns:
${[for (var i = 0; i < header.length; i++) '- ${header[i]} (${types[i]})'].join('\n')}

Schema:
{"type":"scatter|line|bar|histogram|pie|radar",
 "x":"col","y":"col|NULL","cols":[col], "agg":"sum|avg|count|NULL","title":"string"}

Example:
[{"type":"histogram","x":"Height","title":"Height distribution"},
 {"type":"scatter","x":"Height","y":"Weight","title":"Height vs Weight"}]
''';

  List<String> _profile(List<List> rows) {
    final len = rows.first.length;
    final out = List<String>.filled(len, 'cat');
    for (final r in rows.skip(1)) {
      for (var i = 0; i < len; i++) {
        if (out[i] == 'cat' && num.tryParse('${r[i]}') != null) out[i] = 'num';
      }
    }
    return out;
  }

  String? _extractJson(String s) {
    final a = s.indexOf('['), b = s.lastIndexOf(']');
    return a >= 0 && b > a ? s.substring(a, b + 1) : null;
  }

/* scatter / line */
  List<FlSpot> _scatter(List<List> r, String x, String y) {
    final h = r.first.cast<String>();
    final xi = h.indexOf(x), yi = h.indexOf(y);
    if (xi < 0 || yi < 0) return [];
    return [
      for (final row in r.skip(1))
        if (num.tryParse('${row[xi]}') != null &&
            num.tryParse('${row[yi]}') != null)
          FlSpot(double.parse('${row[xi]}'), double.parse('${row[yi]}')),
    ];
  }

  List<FlSpot> _line(List<List> r, String x, String y) =>
      _scatter(r, x, y)..sort((a, b) => a.x.compareTo(b.x));

/* bars */
  List<BarChartRodData> _bars(List<List> r, String x, String? y, String? agg) {
    final h = r.first.cast<String>();
    final xi = h.indexOf(x);
    final yi = y != null ? h.indexOf(y) : -1;
    if (xi < 0) return [];

    final bucket = <String, List<double>>{};
    for (final row in r.skip(1)) {
      final key = '${row[xi]}';
      bucket.putIfAbsent(key, () => []);
      if (yi >= 0 && num.tryParse('${row[yi]}') != null) {
        bucket[key]!.add(double.parse('${row[yi]}'));
      }
    }

    final keys = bucket.keys.toList()..sort();
    return [
      for (final k in keys)
        BarChartRodData(
          toY: switch (agg) {
            'sum' => bucket[k]!.fold(0.0, (a, b) => a + b),
            'avg' => bucket[k]!.isEmpty
                ? 0
                : bucket[k]!.reduce((a, b) => a + b) / bucket[k]!.length,
            _ => bucket[k]!.isEmpty ? 1 : bucket[k]!.length.toDouble(),
          },
        ),
    ];
  }

/* histogram */
  List<FlSpot> _hist(List<List> r, String c) {
    final idx = r.first.cast<String>().indexOf(c);
    if (idx < 0) return [];
    final nums = r
        .skip(1)
        .map((e) => num.tryParse('${e[idx]}'))
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList()
      ..sort();
    if (nums.isEmpty) return [];
    final bins = max(5, sqrt(nums.length).round());
    final minV = nums.first, step = (nums.last - minV) / bins;
    final cnt = List<int>.filled(bins, 0);
    for (final n in nums) {
      cnt[min(((n - minV) / step).floor(), bins - 1)]++;
    }
    return [
      for (var i = 0; i < bins; i++)
        FlSpot(minV + i * step + step / 2, cnt[i].toDouble()),
    ];
  }

/* pie */
  List<PieChartSectionData> _pie(
    List<List> r,
    String x,
    String? y,
    String? agg,
  ) {
    final h = r.first.cast<String>();
    final xi = h.indexOf(x), yi = y != null ? h.indexOf(y) : -1;
    if (xi < 0) return [];
    final bucket = <String, List<double>>{};
    for (final row in r.skip(1)) {
      final k = '${row[xi]}';
      bucket.putIfAbsent(k, () => []);
      if (yi >= 0 && num.tryParse('${row[yi]}') != null) {
        bucket[k]!.add(double.parse('${row[yi]}'));
      }
    }
    final keys = bucket.keys.toList()..sort();
    return [
      for (final k in keys)
        PieChartSectionData(
          title: k,
          value: switch (agg) {
            'sum' => bucket[k]!.fold(0.0, (a, b) => a! + b),
            'avg' => bucket[k]!.isEmpty
                ? 0
                : bucket[k]!.reduce((a, b) => a + b) / bucket[k]!.length,
            _ => bucket[k]!.isEmpty ? 1 : bucket[k]!.length.toDouble(),
          },
          radius: 50,
        ),
    ];
  }

/* radar */
  _RadarRes? _radar(List<List> r, List<String> cols) {
    if (cols.length < 3 || cols.length > 6) return null;
    final h = r.first.cast<String>();
    final idx = [for (final c in cols) h.indexOf(c)];
    if (idx.any((i) => i < 0)) return null;

    final sums = List<double>.filled(idx.length, 0);
    var count = 0;
    for (final row in r.skip(1)) {
      if (idx.every((i) => num.tryParse('${row[i]}') != null)) {
        for (var j = 0; j < idx.length; j++) {
          sums[j] += double.parse('${row[idx[j]]}');
        }
        count++;
      }
    }
    if (count == 0) return null;
    final entries = [for (final s in sums) RadarEntry(value: s / count)];
    return _RadarRes(entries, cols);
  }

/* llama loader */
  Llama? _ll;
  Future<Llama> _llama() async {
    if (_ll != null) return _ll!;
    _log('Loading model…');
    _ll = Llama(
      LlamaController(modelPath: await _modelPath(), nCtx: 1024, greedy: true),
    );
    _log('Model ready');
    return _ll!;
  }

  static Future<String> _modelPath() async {
    final bytes = await rootBundle.load('assets/models/llama-3b.gguf');
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'llama-3b.gguf'));
    if (!await file.exists()) {
      _log('Copying model to ${file.path}');
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    return file.path;
  }
}

class _RadarRes {
  final List<RadarEntry> entries;
  final List<String> labels;
  _RadarRes(this.entries, this.labels);
}

/* ───── Application entry / UI ───── */

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('Starting PlotPad');
  final dir = await getApplicationDocumentsDirectory();
  final isar = await Isar.openAsync(
    schemas: [SheetSchema],
    directory: dir.path,
  );
  _log('Isar opened at ${dir.path}');
  runApp(
    ProviderScope(
      overrides: [dbP.overrideWithValue(isar)],
      child: const _App(),
    ),
  );
}

class _App extends ConsumerWidget {
  const _App();
  @override
  Widget build(ctx, ref) {
    _log('Building _App');
    return MaterialApp(
      title: 'PlotPad',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const _Home(),
    );
  }
}

class _Home extends ConsumerWidget {
  const _Home();
  @override
  Widget build(ctx, ref) {
    _log('Building _Home');
    final list = ref.watch(viewP);
    final ctrl = ref.read(ctrlP);

    Future<void> _renameSheet(Sheet s) async {
      final tc = TextEditingController(text: s.name);
      final newName = await showDialog<String>(
        context: ctx,
        builder: (_) => AlertDialog(
          title: const Text('Rename sheet'),
          content: TextField(controller: tc, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, tc.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty && newName != s.name) {
        _log('Rename sheet id=${s.id} to "$newName"');
        ref.read(dbP).write((i) => i.sheets.put(s..name = newName));
      }
    }

    Future<void> _deleteSheet(Sheet s) async {
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (_) => AlertDialog(
          title: const Text('Delete sheet?'),
          content: Text('This will permanently delete "${s.name}".'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) {
        _log('Delete sheet id=${s.id}');
        if (s.enc && s.secretId != null) {
          await ctrl.storage.delete(key: s.secretId!);
        }
        ref.read(dbP).write((i) => i.sheets.delete(s.id));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('PlotPad')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search…',
              ),
              onChanged: (v) {
                _log('Search query="$v"');
                ref.read(queryP.notifier).state = v;
              },
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No sheets yet'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(list[i].name),
                      subtitle: Wrap(
                        spacing: 4,
                        children: [
                          for (var t in list[i].tags) Chip(label: Text(t)),
                        ],
                      ),
                      onTap: () {
                        _log('Open sheet id=${list[i].id}');
                        Navigator.push(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => _Sheet(list[i]),
                          ),
                        );
                      },
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            tooltip: 'Rename',
                            onPressed: () => _renameSheet(list[i]),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: 'Delete',
                            onPressed: () => _deleteSheet(list[i]),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () {
          final id = ref.read(dbP).sheets.autoIncrement();
          _log('Creating new sheet id=$id');
          ref
              .read(dbP)
              .write((i) => i.sheets.put(Sheet(name: 'Untitled')..id = id));
        },
      ),
    );
  }
}

class _Sheet extends ConsumerStatefulWidget {
  const _Sheet(this.sheet);
  final Sheet sheet;
  @override
  ConsumerState<_Sheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_Sheet> {
  late final _csvCtl = TextEditingController(text: widget.sheet.csv);
  final _tagCtl = TextEditingController();

  @override
  void dispose() {
    _csvCtl.dispose();
    _tagCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(ctx) {
    final c = ref.read(ctrlP);

    Future<void> _pwDialog(bool set) async {
      final pwd = await showDialog<String>(
        context: ctx,
        builder: (_) {
          final t = TextEditingController();
          return AlertDialog(
            content: TextField(controller: t, obscureText: true),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, t.text),
                child: Text(set ? 'Save' : 'Unlock'),
              ),
            ],
          );
        },
      );
      if (pwd == null || pwd.isEmpty) return;
      set
          ? await c.lock(widget.sheet, pwd)
          : await c.unlock(widget.sheet, pwd).then((raw) {
              if (raw == null) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Wrong password')));
              } else {
                setState(() => _csvCtl.text = raw);
              }
            });
      setState(() {});
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sheet.name),
        actions: [
          IconButton(
            icon: Icon(widget.sheet.enc ? Icons.lock : Icons.lock_open),
            onPressed: () => _pwDialog(!widget.sheet.enc),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _csvCtl,
            maxLines: 5,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              label: Text('CSV'),
            ),
            onChanged: (v) => c.setCsv(widget.sheet, v),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: [
              for (var t in widget.sheet.tags)
                Chip(
                  label: Text(t),
                  onDeleted: () {
                    _log('Remove tag "$t" from id=${widget.sheet.id}');
                    ref.read(dbP).write((i) => widget.sheet.tags.remove(t));
                    setState(() {});
                  },
                ),
              InputChip(
                label: const Text('+'),
                onPressed: () async {
                  final tag = await showDialog<String>(
                    context: ctx,
                    builder: (_) => AlertDialog(
                      content: TextField(controller: _tagCtl),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () =>
                              Navigator.pop(ctx, _tagCtl.text.trim()),
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                  );
                  if (tag != null && tag.isNotEmpty) {
                    _log('Add tag "$tag" to id=${widget.sheet.id}');
                    ref.read(dbP).write((i) => widget.sheet.tags.add(tag));
                    _tagCtl.clear();
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.insights),
            label: const Text('Generate charts'),
            onPressed: () async {
              _log('Generate charts for id=${widget.sheet.id}');
              final specs = await c.charts(widget.sheet);
              if (!mounted) return;
              Navigator.push(
                ctx,
                MaterialPageRoute(builder: (_) => _Charts(specs)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Charts extends StatelessWidget {
  const _Charts(this.specs);
  final List<ChartSpec> specs;
  @override
  Widget build(ctx) => Scaffold(
        appBar: AppBar(title: const Text('Charts')),
        body: specs.isEmpty
            ? const Center(child: Text('No numeric data'))
            : PageView.builder(
                itemCount: specs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        specs[i].title,
                        style: Theme.of(ctx).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      Expanded(child: specs[i].view),
                    ],
                  ),
                ),
              ),
      );
}
