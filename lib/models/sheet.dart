import 'package:isar/isar.dart';

part 'sheet.g.dart';

@collection
class Sheet {
  /// Primary key – assigned with `isar.sheets.autoIncrement()`
  @Id()
  late int id;

  /// Display name
  late String name;

  /// Raw CSV (may be AES-encrypted when [isEncrypted] is true)
  late String csvContent;

  /// If true, [csvContent] is encrypted and a key is stored in secure storage
  late bool isEncrypted;

  /// Secure-storage key name for the 32-byte AES key (null if not encrypted)
  String? passwordKeyName;

  /// Free-form tags (no element-wise index support in Isar v4)
  List<String> tags = [];

  Sheet({
    required this.name,
    this.csvContent = '',
    this.isEncrypted = false,
    this.passwordKeyName,
    List<String> tags = const [],
  }) : tags = List<String>.from(tags);
}
