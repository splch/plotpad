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
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:isar/isar.dart';
import 'package:llama_sdk/llama_sdk.dart'
    if (dart.library.html) 'package:llama_sdk/llama_sdk.web.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/sheet.dart';

/* ───── logging helper ───── */
void _log(
  String msg, {
  int lvl = 0,
  Object? err,
  StackTrace? st,
  String tag = '',
}) => dev.log(
  '[${tag.isEmpty ? 'PlotPad' : tag}] $msg',
  name: 'PlotPad',
  level: lvl,
  error: err,
  stackTrace: st,
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
    final title = t.isEmpty ? 'Scatter' : t;
    return ChartSpec._(
      title,
      ScatterChart(
        ScatterChartData(
          scatterSpots: [for (final p in pts) ScatterSpot(p.x, p.y)],
        ),
      ),
    );
  }

  factory ChartSpec.line(String t, List<FlSpot> pts) {
    final title = t.isEmpty ? 'Line' : t;
    return ChartSpec._(
      title,
      LineChart(LineChartData(lineBarsData: [LineChartBarData(spots: pts)])),
    );
  }

  factory ChartSpec.bar(String t, List<BarChartRodData> rods) {
    final title = t.isEmpty ? 'Bar' : t;
    return ChartSpec._(
      title,
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

  factory ChartSpec.histogram(String t, List<FlSpot> pts) {
    final title = t.isEmpty ? 'Histogram' : t;
    return ChartSpec.line(title, pts);
  }

  factory ChartSpec.pie(String t, List<PieChartSectionData> slices) {
    final title = t.isEmpty ? 'Pie' : t;
    return ChartSpec._(
      title,
      PieChart(PieChartData(sections: slices, sectionsSpace: 2)),
    );
  }

  factory ChartSpec.radar(
    String t,
    List<RadarEntry> entries,
    List<String> labels,
  ) {
    final title = t.isEmpty ? 'Radar' : t;
    return ChartSpec._(
      title,
      RadarChart(
        RadarChartData(
          dataSets: [RadarDataSet(dataEntries: entries)],
          getTitle: (i, a) => RadarChartTitle(text: labels[i], angle: a),
        ),
      ),
    );
  }
}

/* ───── Controller ───── */

class Ctrl {
  Ctrl(this.db) : storage = const FlutterSecureStorage();
  final Isar db;
  final FlutterSecureStorage storage;

  /* ---------- crypto ---------- */

  static const _rounds = 10000;
  Future<Uint8List> _key(String pwd, List<int> salt) async =>
      Uint8List.fromList(
        await crypto.Pbkdf2(
              macAlgorithm: crypto.Hmac.sha256(),
              iterations: _rounds,
              bits: 256,
            )
            .deriveKey(
              secretKey: crypto.SecretKey(utf8.encode(pwd)),
              nonce: salt,
            )
            .then((k) => k.extractBytes()),
      );

  enc.Encrypter _aes(Uint8List k) =>
      enc.Encrypter(enc.AES(enc.Key(k), mode: enc.AESMode.cbc));

  Future<void> lock(Sheet s, String pwd) async {
    if (s.enc || s.csv.trim().isEmpty) return;
    _log('Locking id=${s.id}', tag: 'crypto');
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
  }

  Future<String?> unlock(Sheet s, String pwd) async {
    if (!s.enc) return s.csv;
    _log('Unlock attempt id=${s.id}', tag: 'crypto');
    final meta = await storage.read(key: s.secretId!);
    if (meta == null) {
      _log('meta missing', tag: 'crypto', lvl: 800);
      return null;
    }
    final j = jsonDecode(meta);
    final key = await _key(pwd, base64Decode(j['salt']));
    try {
      final plain = _aes(key).decrypt(
        enc.Encrypted.fromBase64(s.csv),
        iv: enc.IV(base64Decode(j['iv'])),
      );
      _log('Unlock OK', tag: 'crypto');
      return plain;
    } on ArgumentError catch (e, st) {
      _log('Unlock failed', tag: 'crypto', err: e, st: st, lvl: 1000);
      return null;
    }
  }

  /* ---------- CSV persistence ---------- */

  void setCsv(Sheet s, String csv) {
    _log('DB write len=${csv.length} id=${s.id}', tag: 'db');
    db.write((i) => i.sheets.put(s..csv = csv));
  }

  /* ---------- chart helpers ---------- */

  Future<List<ChartSpec>> charts(Sheet s) => _chartsOnCsv(s.csv);
  Future<List<ChartSpec>> chartsOnCsv(String csv) => _chartsOnCsv(csv);

  Future<List<ChartSpec>> _chartsOnCsv(String csv) async {
    _log('CSV length=${csv.length}', tag: 'charts');
    final rows = const CsvToListConverter(
      eol: '\n',
    ).convert(csv.replaceAll(r'\n', '\n'));
    _log('Rows parsed=${rows.length}', tag: 'charts');
    if (rows.length < 2) return [];

    final header = rows.first.cast<String>();
    final types = _profile(rows);
    _log('Header=$header', tag: 'charts');
    _log('Types =$types', tag: 'charts');

    final llama = await _llama();
    final prompt = _buildPrompt(header, types);
    _log('Prompt chars=${prompt.length}', tag: 'charts');
    final resp = await llama
        .prompt([UserLlamaMessage(prompt)])
        .fold<String>('', (a, b) => a + b);
    llama.reload();
    _log(
      'LLM raw (first 500)=${resp.substring(0, min(500, resp.length))}',
      tag: 'charts',
    );

    final jsonTxt = _extractJson(resp);
    _log('JSON slice=${jsonTxt ?? 'null'}', tag: 'charts');
    if (jsonTxt == null) return _fallbackCharts(rows, header);

    final specs = <ChartSpec>[];
    for (final m in jsonDecode(jsonTxt) as List) {
      try {
        switch (m['type']) {
          case 'scatter':
            final d = _scatter(rows, m['x'], m['y']);
            if (d.isNotEmpty) specs.add(ChartSpec.scatter(m['title'] ?? '', d));
            break;
          case 'line':
            final d = _line(rows, m['x'], m['y']);
            if (d.isNotEmpty) specs.add(ChartSpec.line(m['title'] ?? '', d));
            break;
          case 'bar':
            final d = _bars(rows, m['x'], m['y'], m['agg']);
            if (d.isNotEmpty) specs.add(ChartSpec.bar(m['title'] ?? '', d));
            break;
          case 'histogram':
            final d = _hist(rows, m['x']);
            if (d.isNotEmpty)
              specs.add(ChartSpec.histogram(m['title'] ?? '', d));
            break;
          case 'pie':
            final d = _pie(rows, m['x'], m['y'], m['agg']);
            if (d.isNotEmpty) specs.add(ChartSpec.pie(m['title'] ?? '', d));
            break;
          case 'radar':
            final res = _radar(rows, (m['cols'] as List).cast<String>());
            if (res != null)
              specs.add(
                ChartSpec.radar(m['title'] ?? '', res.entries, res.labels),
              );
        }
      } catch (e, st) {
        _log('Bad spec=$m', tag: 'charts', err: e, st: st, lvl: 800);
      }
    }
    _log('Specs produced=${specs.length}', tag: 'charts');
    return specs.isEmpty ? _fallbackCharts(rows, header) : specs;
  }

  /* ----- fallback if LLM fails ----- */
  List<ChartSpec> _fallbackCharts(List<List> rows, List<String> header) {
    _log('Fallback chart invoked', tag: 'charts', lvl: 600);
    final idx = header.indexWhere(
      (c) => rows
          .skip(1)
          .any((r) => num.tryParse('${r[header.indexOf(c)]}') != null),
    );
    if (idx < 0) return [];
    final colName = header[idx];
    final pts = _hist(rows, colName);
    return pts.isEmpty
        ? []
        : [ChartSpec.histogram('$colName distribution', pts)];
  }

  /* ----- helpers (identical to previous) ----- */

  String _buildPrompt(List<String> h, List<String> t) => '''
You are an expert data-visualisation assistant.
Choose up to 3 charts that best reveal patterns.
Return ONLY JSON array, no prose, no markdown.

Columns:
${[for (var i = 0; i < h.length; i++) '- ${h[i]} (${t[i]})'].join('\n')}

Schema:
{"type":"scatter|line|bar|histogram|pie|radar",
 "x":"col","y":"col|NULL","cols":[col],
 "agg":"sum|avg|count|NULL","title":"string"}

Example:
[{"type":"histogram","x":"Height","title":"Height distribution"},
 {"type":"scatter","x":"Height","y":"Weight","title":"Height vs Weight"}]
''';

  List<String> _profile(List<List> r) {
    final len = r.first.length;
    final out = List<String>.filled(len, 'cat');
    for (final row in r.skip(1)) {
      for (var i = 0; i < len; i++) {
        if (out[i] == 'cat' && num.tryParse('${row[i]}') != null)
          out[i] = 'num';
      }
    }
    return out;
  }

  String? _extractJson(String s) {
    final a = s.indexOf('['), b = s.lastIndexOf(']');
    return (a >= 0 && b > a) ? s.substring(a, b + 1) : null;
  }

  List<FlSpot> _scatter(List<List> r, String x, String y) {
    final h = r.first.cast<String>(), xi = h.indexOf(x), yi = h.indexOf(y);
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

  List<BarChartRodData> _bars(List<List> r, String x, String? y, String? agg) {
    final h = r.first.cast<String>(),
        xi = h.indexOf(x),
        yi = y != null ? h.indexOf(y) : -1;
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
        BarChartRodData(
          toY: switch (agg) {
            'sum' => bucket[k]!.fold(0.0, (a, b) => a + b),
            'avg' =>
              bucket[k]!.isEmpty
                  ? 0
                  : bucket[k]!.reduce((a, b) => a + b) / bucket[k]!.length,
            _ => bucket[k]!.isEmpty ? 1 : bucket[k]!.length.toDouble(),
          },
        ),
    ];
  }

  List<FlSpot> _hist(List<List> r, String c) {
    final idx = r.first.cast<String>().indexOf(c);
    if (idx < 0) return [];
    final nums =
        r
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

  List<PieChartSectionData> _pie(
    List<List> r,
    String x,
    String? y,
    String? agg,
  ) {
    final h = r.first.cast<String>(),
        xi = h.indexOf(x),
        yi = y != null ? h.indexOf(y) : -1;
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
            'avg' =>
              bucket[k]!.isEmpty
                  ? 0
                  : bucket[k]!.reduce((a, b) => a + b) / bucket[k]!.length,
            _ => bucket[k]!.isEmpty ? 1 : bucket[k]!.length.toDouble(),
          },
          radius: 50,
        ),
    ];
  }

  _RadarRes? _radar(List<List> r, List<String> cols) {
    if (cols.length < 3 || cols.length > 6) return null;
    final h = r.first.cast<String>(), idx = [for (var c in cols) h.indexOf(c)];
    if (idx.any((i) => i < 0)) return null;
    final sums = List<double>.filled(idx.length, 0);
    var count = 0;
    for (final row in r.skip(1)) {
      if (idx.every((i) => num.tryParse('${row[i]}') != null)) {
        for (var j = 0; j < idx.length; j++)
          sums[j] += double.parse('${row[idx[j]]}');
        count++;
      }
    }
    if (count == 0) return null;
    final entries = [for (final s in sums) RadarEntry(value: s / count)];
    return _RadarRes(entries, cols);
  }

  /* ---------- Llama loader ---------- */

  Llama? _ll;
  Future<Llama> _llama() async {
    if (_ll != null) return _ll!;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'llama-3b.gguf');
    if (!await File(path).exists()) {
      _log('Copying model to $path', tag: 'llama');
      final bytes = await rootBundle.load('assets/models/llama-3b.gguf');
      await File(path).writeAsBytes(bytes.buffer.asUint8List());
    }
    _ll = Llama(LlamaController(modelPath: path, nCtx: 1024, greedy: true));
    _log('Llama ready', tag: 'llama');
    return _ll!;
  }
}

class _RadarRes {
  final List<RadarEntry> entries;
  final List<String> labels;
  _RadarRes(this.entries, this.labels);
}

/* ───── App bootstrap ───── */

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  Widget build(ctx, ref) => MaterialApp(
    title: 'PlotPad',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
    home: const _Home(),
  );
}

/* ───── Home page ───── */

class _Home extends ConsumerWidget {
  const _Home();
  @override
  Widget build(ctx, ref) {
    final list = ref.watch(viewP);
    final ctrl = ref.read(ctrlP);

    Future<void> _rename(Sheet s) async {
      final tc = TextEditingController(text: s.name);
      final name = await showDialog<String>(
        context: ctx,
        builder:
            (_) => AlertDialog(
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
      if (name != null && name.isNotEmpty) {
        _log('Rename id=${s.id} → $name', tag: 'ui');
        ref.read(dbP).write((i) => i.sheets.put(s..name = name));
      }
    }

    Future<void> _delete(Sheet s) async {
      final ok = await showDialog<bool>(
        context: ctx,
        builder:
            (_) => AlertDialog(
              title: const Text('Delete sheet?'),
              content: Text('Delete "${s.name}" permanently?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
      );
      if (ok == true) {
        _log('Delete id=${s.id}', tag: 'ui');
        if (s.enc && s.secretId != null)
          await ctrl.storage.delete(key: s.secretId!);
        ref.read(dbP).write((i) => i.sheets.delete(s.id));
      }
    }

    Future<void> _encrypt(Sheet s) async {
      final pwd = await showDialog<String>(
        context: ctx,
        builder: (_) {
          final t = TextEditingController();
          return AlertDialog(
            title: const Text('Set password'),
            content: TextField(
              controller: t,
              obscureText: true,
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, t.text),
                child: const Text('Encrypt'),
              ),
            ],
          );
        },
      );
      if (pwd != null && pwd.isNotEmpty) {
        _log('Encrypt id=${s.id}', tag: 'ui');
        await ctrl.lock(s, pwd);
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
              onChanged: (v) => ref.read(queryP.notifier).state = v,
            ),
          ),
          Expanded(
            child:
                list.isEmpty
                    ? const Center(child: Text('No sheets yet'))
                    : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final s = list[i];
                        return Slidable(
                          key: ValueKey(s.id),
                          endActionPane: ActionPane(
                            motion: const DrawerMotion(),
                            extentRatio: s.enc ? 0.50 : 0.75,
                            children: [
                              SlidableAction(
                                icon: Icons.edit,
                                label: 'Rename',
                                onPressed: (_) => _rename(s),
                              ),
                              if (!s.enc)
                                SlidableAction(
                                  icon: Icons.lock,
                                  label: 'Encrypt',
                                  onPressed: (_) => _encrypt(s),
                                ),
                              SlidableAction(
                                backgroundColor:
                                    Theme.of(ctx).colorScheme.errorContainer,
                                foregroundColor:
                                    Theme.of(ctx).colorScheme.onErrorContainer,
                                icon: Icons.delete,
                                label: 'Delete',
                                onPressed: (_) => _delete(s),
                              ),
                            ],
                          ),
                          child: ListTile(
                            title: Text(s.name),
                            subtitle: Wrap(
                              spacing: 4,
                              children: [
                                for (var t in s.tags) Chip(label: Text(t)),
                              ],
                            ),
                            onTap: () {
                              _log('Open id=${s.id}', tag: 'ui');
                              Navigator.push(
                                ctx,
                                MaterialPageRoute(builder: (_) => _Sheet(s)),
                              );
                            },
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () {
          final id = ref.read(dbP).sheets.autoIncrement();
          _log('Create new id=$id', tag: 'ui');
          ref
              .read(dbP)
              .write((i) => i.sheets.put(Sheet(name: 'Untitled $id')..id = id));
        },
      ),
    );
  }
}

/* ───── Sheet page ───── */

class _Sheet extends ConsumerStatefulWidget {
  const _Sheet(this.sheet);
  final Sheet sheet;
  @override
  ConsumerState<_Sheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_Sheet> {
  late final _csvCtl = TextEditingController(
    text: widget.sheet.enc ? '' : widget.sheet.csv,
  );
  final _tagCtl = TextEditingController();
  bool _unlocked = false;
  String _plainCsv = '';

  @override
  void initState() {
    super.initState();
    if (widget.sheet.enc) Future.microtask(() => _promptPw(false));
  }

  @override
  void dispose() {
    _csvCtl.dispose();
    _tagCtl.dispose();
    super.dispose();
  }

  Future<bool> _promptPw(bool set) async {
    final ctrl = ref.read(ctrlP);
    final pwd = await showDialog<String>(
      context: context,
      builder: (_) {
        final t = TextEditingController();
        return AlertDialog(
          content: TextField(controller: t, obscureText: true, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, t.text),
              child: Text(set ? 'Save' : 'Unlock'),
            ),
          ],
        );
      },
    );
    if (pwd == null || pwd.isEmpty) return false;

    if (set) {
      _log('Encrypt via lock icon', tag: 'ui');
      await ctrl.lock(widget.sheet, pwd);
      setState(() {
        _unlocked = false;
        _csvCtl.text = '';
        _plainCsv = '';
      });
      return true;
    } else {
      final raw = await ctrl.unlock(widget.sheet, pwd);
      if (raw == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Wrong password')));
        return false;
      }
      _log('Unlock success', tag: 'ui');
      setState(() {
        _unlocked = true;
        _plainCsv = raw;
        _csvCtl.text = raw;
      });
      return true;
    }
  }

  @override
  Widget build(ctx) {
    final ctrl = ref.read(ctrlP);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sheet.name),
        actions: [
          IconButton(
            icon: Icon(
              widget.sheet.enc && !_unlocked ? Icons.lock : Icons.lock_open,
            ),
            onPressed: () => _promptPw(widget.sheet.enc && !_unlocked),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _csvCtl,
            maxLines: 5,
            readOnly: widget.sheet.enc && !_unlocked,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              label: Text('CSV'),
            ),
            onChanged: (v) {
              _log('CSV edit len=${v.length}', tag: 'ui');
              if (widget.sheet.enc && _unlocked) {
                _plainCsv = v;
              } else {
                ctrl.setCsv(widget.sheet, v);
              }
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: [
              for (var t in widget.sheet.tags)
                Chip(
                  label: Text(t),
                  onDeleted: () {
                    _log('Remove tag=$t', tag: 'ui');
                    ref.read(dbP).write((i) => widget.sheet.tags.remove(t));
                    setState(() {});
                  },
                ),
              InputChip(
                label: const Text('+'),
                onPressed: () async {
                  final tag = await showDialog<String>(
                    context: ctx,
                    builder:
                        (_) => AlertDialog(
                          content: TextField(
                            controller: _tagCtl,
                            autofocus: true,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed:
                                  () => Navigator.pop(ctx, _tagCtl.text.trim()),
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                  );
                  if (tag != null && tag.isNotEmpty) {
                    _log('Add tag=$tag', tag: 'ui');
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
              if (widget.sheet.enc && !_unlocked) {
                final ok = await _promptPw(false);
                if (!ok) return;
              }
              _log('Generate charts tapped', tag: 'ui');
              final specs =
                  widget.sheet.enc
                      ? await ctrl.chartsOnCsv(_plainCsv)
                      : await ctrl.charts(widget.sheet);
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

/* ───── Charts page ───── */

class _Charts extends StatelessWidget {
  const _Charts(this.specs);
  final List<ChartSpec> specs;

  @override
  Widget build(ctx) => Scaffold(
    appBar: AppBar(title: const Text('Charts')),
    body:
        specs.isEmpty
            ? const Center(child: Text('No numeric data'))
            : PageView.builder(
              itemCount: specs.length,
              itemBuilder:
                  (_, i) => Padding(
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
