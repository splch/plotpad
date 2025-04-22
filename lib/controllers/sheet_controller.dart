import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:isar/isar.dart';
import '../models/sheet.dart';
import '../providers.dart';

/// A simple ChartSpec to drive fl_chart
class ChartSpec {
  final String title;
  final List<FlSpot> spots;
  ChartSpec(this.title, this.spots);
}

final sheetControllerProvider = Provider.autoDispose<SheetController>((ref) {
  final isar = ref.read(isarProvider);
  return SheetController(isar);
});

class SheetController {
  final Isar isar;
  SheetController(this.isar);

  Future<void> updateCsv(Sheet sheet, String csv) async {
    sheet.csvContent = csv;
    // Use synchronous write so we don't spawn an isolate
    isar.write((isar) {
      isar.sheets.put(sheet);
    });
  }

  Future<List<ChartSpec>> generateCharts(Sheet sheet) async {
    final rows = const CsvToListConverter().convert(sheet.csvContent);
    if (rows.length < 2) return [];

    final headers = rows.first.cast<String>();
    final data = rows.sublist(1);

    final specs = <ChartSpec>[];
    for (var col = 0; col < headers.length; col++) {
      final maybeNums =
          data.map((r) => num.tryParse(r[col].toString())).toList();
      if (maybeNums.every((n) => n != null)) {
        final spots = <FlSpot>[];
        for (var i = 0; i < maybeNums.length; i++) {
          spots.add(FlSpot(i.toDouble(), maybeNums[i]!.toDouble()));
        }
        specs.add(ChartSpec(headers[col], spots));
      }
    }

    // TODO: swap in llama_cpp_dart for richer chart suggestions
    return specs;
  }
}
