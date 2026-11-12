import 'dart:io';

import 'package:ashita_motsumono/src/repositories/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A failed WAL checkpoint must not reduce the recoverable backup set.
  test('corrupt database backup includes SQLite sidecars', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ashita_database_backup_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final source = '${directory.path}/ashita_motsumono.db';
    final backup = '${directory.path}/ashita_motsumono_corrupt.db';
    await File(source).writeAsString('db');
    await File('$source-wal').writeAsString('wal');
    await File('$source-shm').writeAsString('shm');
    await File('$source-journal').writeAsString('journal');

    final copied = await AppDatabase.backupDatabaseFilesAtPath(source, backup);

    expect(
      copied,
      containsAll([backup, '$backup-wal', '$backup-shm', '$backup-journal']),
    );
    expect(await File(backup).readAsString(), 'db');
    expect(await File('$backup-wal').readAsString(), 'wal');
    expect(await File('$backup-shm').readAsString(), 'shm');
    expect(await File('$backup-journal').readAsString(), 'journal');
  });

  // Recovery should expose every successful copy even when one sidecar fails.
  test('a failed sidecar copy preserves other backup files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ashita_database_partial_backup_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final source = '${directory.path}/ashita_motsumono.db';
    final backup = '${directory.path}/ashita_motsumono_corrupt.db';
    await File(source).writeAsString('db');
    await File('$source-wal').writeAsString('wal');
    await File('$source-shm').writeAsString('shm');
    await Directory('$backup-wal').create();

    final copied = await AppDatabase.backupDatabaseFilesAtPath(source, backup);

    expect(copied, contains(backup));
    expect(copied, contains('$backup-shm'));
    expect(copied, isNot(contains('$backup-wal')));
    expect(await File(backup).readAsString(), 'db');
    expect(await File('$backup-shm').readAsString(), 'shm');
  });
  // Sidecar evidence must be retained, but must not be reported as a usable
  // database backup when the primary database copy fails.
  test('a failed primary database copy does not report a recoverable backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ashita_database_primary_backup_failure_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final source = '${directory.path}/ashita_motsumono.db';
    final backup = '${directory.path}/ashita_motsumono_corrupt.db';
    await File(source).writeAsString('db');
    await File('$source-wal').writeAsString('wal');

    // A directory at the primary destination forces File.copy() to fail while
    // the sibling WAL destination remains writable.
    await Directory(backup).create();

    await expectLater(
      AppDatabase.backupDatabaseFilesAtPath(source, backup),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          'message',
          contains('primary database file'),
        ),
      ),
    );

    // Keep partial forensic evidence, but do not return a successful backup.
    expect(await File('$backup-wal').readAsString(), 'wal');
  });

}
