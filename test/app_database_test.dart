// test/app_database_test.dart
// AppDatabase（Drift SQLite）のCRUD操作とスキーマをテストする。
// 関連: lib/src/repositories/app_database.dart, lib/src/models/entities.dart

import 'dart:io';

import 'package:ashita_motsumono/src/models/entities.dart';
import 'package:ashita_motsumono/src/repositories/app_database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = await AppDatabase.createInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  test('schema version is 4', () {
    expect(db.schemaVersion, 4);
  });

  test('saves and loads a child', () async {
    final child = PersonProfile(
      id: 'test1',
      name: '太郎',
      colorValue: 0xFF0000FF,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final snapshot = AppSnapshot(children: [child], todos: [], documents: []);
    await db.saveSnapshot(snapshot);
    final loaded = await db.loadSnapshot();
    expect(loaded.children.length, 1);
    expect(loaded.children.first.name, '太郎');
  });

  test('saves and loads a todo with items', () async {
    final todo = AppTodo(
      id: 'todo1',
      title: '集金500円',
      items: [
        ChecklistItem(id: 'item1', label: '集金袋', isChecked: false),
        ChecklistItem(id: 'item2', label: 'お釣り', isChecked: true),
      ],
      category: TodoCategory.payment,
      status: TodoStatus.active,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final snapshot = AppSnapshot(children: [], todos: [todo], documents: []);
    await db.saveSnapshot(snapshot);
    final loaded = await db.loadSnapshot();
    expect(loaded.todos.length, 1);
    expect(loaded.todos.first.title, '集金500円');
    expect(loaded.todos.first.items.length, 2);
    expect(loaded.todos.first.items.last.isChecked, isTrue);
  });

  test('saves and loads a document', () async {
    final doc = DocumentRecord(
      id: 'doc1',
      sourceType: 'camera',
      localImagePath: '/tmp/test.png',
      ocrText: '7月10日まで',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final snapshot = AppSnapshot(children: [], todos: [], documents: [doc]);
    await db.saveSnapshot(snapshot);
    final loaded = await db.loadSnapshot();
    expect(loaded.documents.length, 1);
    expect(loaded.documents.first.ocrText, '7月10日まで');
  });

  test('orders document pages and enforces v4 indexes', () async {
    final now = DateTime(2026, 1, 1);
    final document = DocumentRecord(
      id: 'doc-pages',
      sourceType: 'pdf',
      sourceFingerprint: 'fingerprint-1',
      createdAt: now,
      updatedAt: now,
      pages: const [
        DocumentPageRecord(
          id: 'page-2',
          documentId: 'doc-pages',
          pageIndex: 2,
          localImagePath: '/tmp/page-2.jpg',
          ocrText: '',
        ),
        DocumentPageRecord(
          id: 'page-0',
          documentId: 'doc-pages',
          pageIndex: 0,
          localImagePath: '/tmp/page-0.jpg',
          ocrText: '先頭',
        ),
        DocumentPageRecord(
          id: 'page-1',
          documentId: 'doc-pages',
          pageIndex: 1,
          localImagePath: '/tmp/page-1.jpg',
          ocrText: '',
        ),
      ],
    );
    await db.saveSnapshot(
      AppSnapshot(children: [], todos: [], documents: [document]),
    );

    final loaded = await db.loadSnapshot();
    expect(loaded.documents.single.pages.map((page) => page.pageIndex), [
      0,
      1,
      2,
    ]);

    await expectLater(
      db
          .into(db.dbDocumentPage)
          .insert(
            DbDocumentPageCompanion.insert(
              id: 'duplicate-page-index',
              documentId: 'doc-pages',
              pageIndex: 0,
              localImagePath: '/tmp/duplicate.jpg',
              ocrText: '',
            ),
          ),
      throwsA(anything),
    );

    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name IN ('idx_db_document_source_fingerprint', "
          "'idx_db_document_page_document_page_index')",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(indexes.toSet(), {
      'idx_db_document_source_fingerprint',
      'idx_db_document_page_document_page_index',
    });
  });

  test('clearAll removes all data', () async {
    final todo = AppTodo(
      id: 'todo1',
      title: 'Test',
      items: [ChecklistItem(id: 'item1', label: 'L', isChecked: false)],
      category: TodoCategory.other,
      status: TodoStatus.active,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    await db.saveSnapshot(
      AppSnapshot(children: [], todos: [todo], documents: []),
    );
    await db.clearAll();
    final loaded = await db.loadSnapshot();
    expect(loaded.todos, isEmpty);
    expect(loaded.children, isEmpty);
    expect(loaded.documents, isEmpty);
  });

  test('backupDatabaseFile returns null for in-memory db', () async {
    expect(await db.backupDatabaseFile(), isNull);
  });

  test('primary database deletion failure preserves SQLite sidecars', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ashita_database_primary_delete_failure_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final path =
        '${tempDir.path}${Platform.pathSeparator}ashita_motsumono.db';
    final files = [
      File(path),
      File('$path-wal'),
      File('$path-shm'),
      File('$path-journal'),
    ];
    for (final file in files) {
      await file.writeAsString(file.path);
    }

    final attempted = <String>[];
    await expectLater(
      AppDatabase.deleteDatabaseFilesAtPath(
        path,
        deleteFile: (file) async {
          attempted.add(file.path);
          if (file.path == path) {
            throw const FileSystemException('injected primary delete failure');
          }
          await file.delete();
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(attempted, [path]);
    for (final file in files) {
      expect(await file.exists(), isTrue, reason: '${file.path} must be preserved');
    }
  });

  test(
    'database file deletion attempts every sidecar before reporting failure',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ashita_database_delete_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final path =
          '${tempDir.path}${Platform.pathSeparator}ashita_motsumono.db';
      final files = [
        File(path),
        File('$path-wal'),
        File('$path-shm'),
        File('$path-journal'),
      ];
      for (final file in files) {
        await file.writeAsString(file.path);
      }

      final attempted = <String>[];
      await expectLater(
        AppDatabase.deleteDatabaseFilesAtPath(
          path,
          deleteFile: (file) async {
            attempted.add(file.path);
            if (file.path == '$path-wal') {
              throw const FileSystemException('injected WAL delete failure');
            }
            await file.delete();
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(attempted, files.map((file) => file.path).toList());
      expect(await File(path).exists(), isFalse);
      expect(await File('$path-wal').exists(), isTrue);
      expect(await File('$path-shm').exists(), isFalse);
      expect(await File('$path-journal').exists(), isFalse);
    },
  );

  group('legacy migration safety', () {
    test('migrates valid legacy snapshot', () async {
      SharedPreferences.setMockInitialValues({
        'ashita_motsumono_snapshot_v1': '''
        {
          "version": 1,
          "children": [],
          "todos": [
            {
              "id": "todo-1",
              "title": "水筒持参",
              "category": "item",
              "status": "active",
              "items": [],
              "notifyPreviousNight": true,
              "notifySameMorning": true,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "documents": []
        }
        ''',
      });
      final prefs = await SharedPreferences.getInstance();
      final ok = await AppDatabase.tryMigration(prefs);
      expect(ok, isTrue);
    });

    test('preserves valid legacy childId through database migration', () async {
      SharedPreferences.setMockInitialValues({
        'ashita_motsumono_snapshot_v1': '''
        {
          "version": 1,
          "children": [
            {
              "id": "child-legacy",
              "name": "長女",
              "colorValue": 4280391411,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "todos": [
            {
              "id": "todo-legacy-child",
              "title": "体操着",
              "childId": "child-legacy",
              "category": "item",
              "status": "active",
              "items": [],
              "notifyPreviousNight": true,
              "notifySameMorning": true,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "documents": []
        }
        ''',
      });
      final prefs = await SharedPreferences.getInstance();
      AppSnapshot? snapshot;
      final ok = await AppDatabase.tryMigration(
        prefs,
        onMigrated: (migrated) => snapshot = migrated,
      );

      expect(ok, isTrue);
      expect(snapshot, isNotNull);
      expect(snapshot!.todos.single.personId, 'child-legacy');
    });

    test('current personId takes precedence over legacy childId', () async {
      SharedPreferences.setMockInitialValues({
        'ashita_motsumono_snapshot_v1': '''
        {
          "version": 1,
          "children": [
            {
              "id": "person-current",
              "name": "長男",
              "colorValue": 4280391411,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            },
            {
              "id": "child-legacy",
              "name": "旧参照",
              "colorValue": 4280391412,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "todos": [
            {
              "id": "todo-current-person",
              "title": "提出物",
              "personId": "person-current",
              "childId": "child-legacy",
              "category": "submission",
              "status": "active",
              "items": [],
              "notifyPreviousNight": true,
              "notifySameMorning": true,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "documents": []
        }
        ''',
      });
      final prefs = await SharedPreferences.getInstance();
      AppSnapshot? snapshot;
      final ok = await AppDatabase.tryMigration(
        prefs,
        onMigrated: (migrated) => snapshot = migrated,
      );

      expect(ok, isTrue);
      expect(snapshot, isNotNull);
      expect(snapshot!.todos.single.personId, 'person-current');
    });

    test(
      'keeps orphan todos when legacy snapshot has dangling references',
      () async {
        SharedPreferences.setMockInitialValues({
          'ashita_motsumono_snapshot_v1': '''
        {
          "version": 1,
          "children": [],
          "todos": [
            {
              "id": "todo-dangling-refs",
              "title": "参照切れのTodo",
              "personId": "missing-child",
              "documentId": "missing-document",
              "category": "item",
              "status": "active",
              "items": [],
              "notifyPreviousNight": true,
              "notifySameMorning": true,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "documents": []
        }
        ''',
        });
        final prefs = await SharedPreferences.getInstance();
        AppSnapshot? snapshot;
        final ok = await AppDatabase.tryMigration(
          prefs,
          onMigrated: (migrated) => snapshot = migrated,
        );

        expect(ok, isTrue);
        expect(snapshot, isNotNull);
        expect(snapshot!.todos.single.id, 'todo-dangling-refs');
        expect(snapshot!.todos.single.personId, isNull);
        expect(snapshot!.todos.single.documentId, isNull);
      },
    );

    test('marks migration done when no legacy data', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final ok = await AppDatabase.tryMigration(prefs);
      expect(ok, isTrue);
    });

    test('does not mark migration done when legacy JSON is corrupt', () async {
      SharedPreferences.setMockInitialValues({
        'ashita_motsumono_snapshot_v1': 'not valid json at all',
      });
      final prefs = await SharedPreferences.getInstance();
      final ok = await AppDatabase.tryMigration(prefs);
      expect(ok, isFalse);
    });

    test('rejects todo with invalid dueDate', () async {
      SharedPreferences.setMockInitialValues({
        'ashita_motsumono_snapshot_v1': '''
        {
          "version": 1,
          "children": [],
          "todos": [
            {
              "id": "todo-1",
              "title": "Bad date",
              "category": "other",
              "status": "active",
              "items": [],
              "dueDate": "not-a-date",
              "notifyPreviousNight": true,
              "notifySameMorning": true,
              "createdAt": "2026-01-01T00:00:00.000",
              "updatedAt": "2026-01-01T00:00:00.000"
            }
          ],
          "documents": []
        }
        ''',
      });
      final prefs = await SharedPreferences.getInstance();
      final ok = await AppDatabase.tryMigration(prefs);
      // 不正な日付を現在日時やnullへ置換せず、移行全体を保留する。
      expect(ok, isFalse);
    });
  });
}
