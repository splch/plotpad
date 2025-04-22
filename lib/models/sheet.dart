import 'package:isar/isar.dart';

part 'sheet.g.dart';

@Collection()
class Sheet {
  @Id()
  int id = 0; // auto‑increment

  String name;
  String csvContent;
  bool isEncrypted;
  String? passwordKeyName;

  Sheet({
    this.id = 0,
    required this.name,
    this.csvContent = '',
    this.isEncrypted = false,
    this.passwordKeyName,
  });
}
