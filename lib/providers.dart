import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'models/sheet.dart';

// 1) Provide the opened Isar instance
final isarProvider = Provider<Isar>((_) => throw UnimplementedError());

// 2) Stream all sheets
final sheetListProvider = StreamProvider<List<Sheet>>((ref) {
  final isar = ref.watch(isarProvider);
  return isar.sheets.where().watch(fireImmediately: true);
});
