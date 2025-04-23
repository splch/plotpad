import 'package:isar/isar.dart';

part 'sheet.g.dart';

@collection
class Sheet {
  @Id()
  late int id; // autoIncrement() on insert
  String name; // display name
  String csv = ''; // raw CSV (encrypted when [enc]=true)
  bool enc = false; // is encrypted?
  String? secretId; // secure-storage payload key
  List<String> tags = []; // free-form tags

  Sheet({required this.name});
}
