import 'dart:io';

const String _sqliteHeader = 'SQLite format 3\u0000';

/// Whether [file] can be opened as SQLite. An empty file counts, since SQLite
/// initializes it on first write.
Future<bool> isSqliteFile(File file) async {
  if (await file.length() == 0) return true;
  final raf = await file.open();
  try {
    final header = await raf.read(_sqliteHeader.length);
    return String.fromCharCodes(header) == _sqliteHeader;
  } finally {
    await raf.close();
  }
}
