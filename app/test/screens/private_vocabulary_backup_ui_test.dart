import 'dart:convert';
import 'dart:typed_data';

import 'package:app/models/lesson_item.dart';
import 'package:app/screens/curriculum_screen.dart';
import 'package:app/screens/settings_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/backup_file_transport.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _UiApi extends ApiService {
  final List<PrivateLessonState> private = [];
  final List<LessonItem> builtins = [
    LessonItem(
      id: 'ja_hira_a',
      language: 'ja',
      category: 'alphabet',
      targetText: 'あ',
      phoneticOrKana: 'a',
      meaningVi: 'A',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: const [],
      difficultyLevel: 1,
    ),
  ];
  int nextId = 0;
  String? resolved;
  int merges = 0;
  bool staleOnce = false;
  bool upgradeRequired = false;
  ProfileMergePreview? preview;
  ProfileBackup? exported;
  ProfileBackup? guestExported;

  @override
  Future<bool> checkBackendHealth() async => true;

  @override
  Future<List<LessonItem>> getLessons({String? language}) async => [
    ...builtins,
    ...private.where((s) => !s.deleted).map((s) => s.lesson),
  ];

  @override
  Future<List<FSRSCard>> getAllCards() async => [];

  @override
  Future<Map<String, dynamic>> getFSRSStats() async => {
    'pending_review_mutations': 0,
    'pending_private_lesson_mutations': 0,
    'pending_progress_imports': 0,
    'private_lesson_conflicts': 0,
    'retry_sync_mutations': 0,
    'private_sync_upgrade_required': upgradeRequired,
  };

  @override
  Future<List<PrivateLessonState>> getPrivateLessons({
    bool includeDeleted = false,
  }) async => private.where((s) => includeDeleted || !s.deleted).toList();

  @override
  Future<LessonItem> createPrivateLesson({
    required String word,
    required String language,
    required String meaningVi,
    String phoneticOrKana = '',
    String workplaceContext = '',
    String workplaceContextVi = '',
    List<String> strokeOrderHints = const [],
    int difficultyLevel = 2,
  }) async {
    final lesson = LessonItem(
      id: 'custom_en_${++nextId}',
      language: language,
      category: 'custom',
      targetText: word,
      phoneticOrKana: phoneticOrKana,
      meaningVi: meaningVi,
      workplaceContext: workplaceContext,
      workplaceContextVi: workplaceContextVi,
      strokeOrderHints: strokeOrderHints,
      difficultyLevel: difficultyLevel,
    );
    private.add(
      PrivateLessonState(
        lesson: lesson,
        revision: 0,
        deleted: false,
        updatedAt: DateTime.now().toUtc(),
        localVersion: 1,
        pending: true,
      ),
    );
    return lesson;
  }

  @override
  Future<PrivateLessonState> savePrivateLesson(LessonItem lesson) async {
    private.removeWhere((s) => s.lesson.id == lesson.id);
    final state = PrivateLessonState(
      lesson: lesson,
      revision: 0,
      deleted: false,
      updatedAt: DateTime.now().toUtc(),
      localVersion: 2,
      pending: true,
    );
    private.add(state);
    return state;
  }

  @override
  Future<void> deletePrivateLesson(String id) async {
    final index = private.indexWhere((s) => s.lesson.id == id);
    if (index < 0) return;
    final old = private[index];
    private[index] = PrivateLessonState(
      lesson: old.lesson,
      revision: old.revision,
      deleted: true,
      updatedAt: DateTime.now().toUtc(),
      localVersion: old.localVersion + 1,
      pending: true,
    );
  }

  @override
  Future<void> restorePrivateLesson(String id) async {
    final index = private.indexWhere((s) => s.lesson.id == id);
    if (index < 0) return;
    final old = private[index];
    private[index] = PrivateLessonState(
      lesson: old.lesson,
      revision: old.revision,
      deleted: false,
      updatedAt: DateTime.now().toUtc(),
      localVersion: old.localVersion + 1,
      pending: true,
    );
  }

  @override
  Future<void> resolvePrivateLessonConflict(
    String id, {
    required bool keepLocal,
  }) async {
    resolved = keepLocal ? 'local' : 'server';
  }

  ProfileBackup get _emptyBackup => ProfileBackup.fromBytes(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'lingua_canvas_backup',
          'version': 1,
          'backup_id': 'backup-ui',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'private_lessons': [],
          'cards': [],
          'review_logs': [],
          'completed_lessons': [],
          'daily_activity': {},
        }),
      ),
    ),
  );

  @override
  Future<ProfileBackup> exportProfileBackup() async => exported ?? _emptyBackup;

  @override
  Future<ProfileBackup> exportGuestBackup({Set<String>? lessonIds}) async {
    final backup = guestExported ?? _emptyBackup;
    if (lessonIds == null) return backup;
    return ProfileBackup(
      backupId: backup.backupId,
      createdAt: backup.createdAt,
      privateLessons: backup.privateLessons
          .where((state) => lessonIds.contains(state.lesson.id))
          .toList(),
      cards: backup.cards,
      reviewLogs: backup.reviewLogs,
      completedLessons: backup.completedLessons,
      dailyActivity: backup.dailyActivity,
    );
  }

  @override
  Future<ProfileMergePreview> previewProfileBackup(
    ProfileBackup backup,
  ) async =>
      preview ??
      ProfileMergePreview(
        backup: backup,
        binding: 'profile-1',
        contentRevision: '1',
        backupRevision: '1',
        additions: 2,
        updates: 1,
        skips: 3,
        conflicts: 1,
      );

  @override
  Future<void> mergeProfileBackup(ProfileMergePreview preview) async {
    if (staleOnce) {
      staleOnce = false;
      throw const StaleProfileMergeException();
    }
    merges++;
  }
}

class _Transport implements BackupFileTransport {
  Uint8List? bytes;
  bool saveResult = true;
  int saves = 0;
  @override
  Future<Uint8List?> pickBackup() async => bytes;
  @override
  Future<bool> saveBackup(
    Uint8List bytes, {
    required String suggestedName,
  }) async {
    saves++;
    return saveResult;
  }
}

class _GuestAccountService extends AccountService {
  _GuestAccountService(ApiService api) : super(apiService: api);
  @override
  Future<Map<String, dynamic>?> currentAccount() async => null;
}

class _LinkedAccountService extends AccountService {
  _LinkedAccountService(ApiService api) : super(apiService: api);
  @override
  Future<Map<String, dynamic>?> currentAccount() async => {
    'user_id': 'usr_linked',
    'username': 'linked',
    'display_name': 'Linked',
    'sync_token': 'token_linked',
    'server_url': apiService.baseUrl,
    'devices': <Map<String, dynamic>>[],
  };
}

void main() {
  testWidgets(
    'private words keep identity when edited and can be restored from trash',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _UiApi();
      await tester.pumpWidget(
        MaterialApp(home: CurriculumScreen(apiService: api)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm từ mới'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('custom-word')), 'deploy');
      await tester.enterText(
        find.byKey(const Key('custom-meaning')),
        'Triển khai',
      );
      await tester.tap(find.text('Lưu & Luyện viết'));
      await tester.pumpAndSettle();
      final id = api.private.single.lesson.id;
      await tester.tap(find.byTooltip('Sửa từ'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tiếng Nhật (ja)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('custom-meaning')),
        'Đưa lên máy chủ',
      );
      await tester.tap(find.text('Lưu thay đổi'));
      await tester.pumpAndSettle();
      expect(api.private.single.lesson.id, id);
      expect(api.private.single.lesson.language, 'ja');
      expect(api.private.single.lesson.meaningVi, 'Đưa lên máy chủ');
      await tester.tap(find.byTooltip('Chuyển vào thùng rác'));
      await tester.pumpAndSettle();
      expect(find.text('deploy'), findsNothing);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Thùng rác'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Thùng rác'));
      await tester.pumpAndSettle();
      expect(find.text('deploy'), findsOneWidget);
      await tester.tap(find.text('Khôi phục'));
      await tester.pumpAndSettle();
      expect(api.private.single.deleted, isFalse);
    },
  );

  testWidgets('backup import shows merge counts and requires confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _UiApi();
    var profileRefreshes = 0;
    final transport = _Transport()
      ..bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'lingua_canvas_backup',
            'version': 1,
            'backup_id': 'import-ui',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'private_lessons': [],
            'cards': [],
            'review_logs': [],
            'completed_lessons': [],
            'daily_activity': {},
          }),
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          apiService: api,
          accountService: _GuestAccountService(api),
          backupTransport: transport,
          onProfileDataChanged: () => profileRefreshes++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Nhập sao lưu'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nhập sao lưu'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Thêm: 2'), findsOneWidget);
    expect(find.textContaining('Xung đột: 1'), findsOneWidget);
    await tester.tap(find.text('Gộp dữ liệu đã xem trước'));
    await tester.pumpAndSettle();
    expect(api.merges, 0);
    await tester.tap(find.text('Xác nhận gộp'));
    await tester.pumpAndSettle();
    expect(api.merges, 1);
    expect(profileRefreshes, 1);
  });

  testWidgets('cancelled backup picker leaves the screen unchanged', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _Transport();
    final api = _UiApi();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          apiService: api,
          accountService: _GuestAccountService(api),
          backupTransport: transport,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Nhập sao lưu'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Nhập sao lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Chưa chọn tệp sao lưu.'), findsNothing);
  });

  testWidgets('invalid backup is rejected before preview or merge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _UiApi();
    final transport = _Transport()
      ..bytes = Uint8List.fromList(utf8.encode('not-json'));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          apiService: api,
          accountService: _GuestAccountService(api),
          backupTransport: transport,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Nhập sao lưu'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nhập sao lưu'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup-message')), findsOneWidget);
    expect(api.merges, 0);
    expect(find.text('Gộp dữ liệu đã xem trước'), findsNothing);
  });

  testWidgets(
    'unsupported server status explains that queued data is retained',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _UiApi()..upgradeRequired = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            apiService: api,
            accountService: _GuestAccountService(api),
            backupTransport: _Transport(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Máy chủ cần được nâng cấp'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Dữ liệu đang chờ vẫn được giữ'),
        findsOneWidget,
      );
    },
  );

  testWidgets('backup export writes the validated snapshot through transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _UiApi();
    final transport = _Transport();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          apiService: api,
          accountService: _GuestAccountService(api),
          backupTransport: transport,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Xuất bản sao lưu'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Xuất bản sao lưu'));
    await tester.pumpAndSettle();
    expect(transport.saves, 1);
    expect(find.text('Đã lưu bản sao lưu.'), findsOneWidget);
  });

  testWidgets('conflicting versions are compared before choosing one', (
    tester,
  ) async {
    final api = _UiApi();
    final localLesson = LessonItem(
      id: 'custom_en_conflict',
      language: 'en',
      category: 'custom',
      targetText: 'merge',
      phoneticOrKana: '',
      meaningVi: 'Gộp',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: const [],
      difficultyLevel: 2,
    );
    api.private.add(
      PrivateLessonState(
        lesson: localLesson,
        revision: 1,
        deleted: false,
        updatedAt: DateTime.now().toUtc(),
        localVersion: 2,
        pending: true,
        conflict: PrivateLessonConflict(
          local: PrivateLessonWireState(
            lesson: localLesson,
            revision: 1,
            deleted: false,
            updatedAt: DateTime.now().toUtc(),
          ),
          remote: PrivateLessonWireState(
            lesson: LessonItem(
              id: localLesson.id,
              language: 'en',
              category: 'custom',
              targetText: 'merge',
              phoneticOrKana: '',
              meaningVi: 'Hợp nhất',
              workplaceContext: '',
              workplaceContextVi: '',
              strokeOrderHints: const [],
              difficultyLevel: 2,
            ),
            revision: 2,
            deleted: false,
            updatedAt: DateTime.now().toUtc(),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: CurriculumScreen(apiService: api)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('So sánh'));
    await tester.pumpAndSettle();
    expect(find.text('Gộp'), findsWidgets);
    expect(find.text('Hợp nhất'), findsOneWidget);
    await tester.tap(find.text('Giữ bản máy chủ'));
    await tester.pumpAndSettle();
    expect(api.resolved, 'server');
  });

  testWidgets(
    'conflict without a server candidate does not offer keep-server',
    (tester) async {
      final api = _UiApi();
      final localLesson = LessonItem(
        id: 'custom_en_local_only',
        language: 'en',
        category: 'custom',
        targetText: 'local',
        phoneticOrKana: '',
        meaningVi: 'Chỉ trên máy',
        workplaceContext: '',
        workplaceContextVi: '',
        strokeOrderHints: const [],
        difficultyLevel: 2,
      );
      api.private.add(
        PrivateLessonState(
          lesson: localLesson,
          revision: 0,
          deleted: false,
          updatedAt: DateTime.now().toUtc(),
          localVersion: 1,
          pending: true,
          conflict: PrivateLessonConflict(
            local: PrivateLessonWireState(
              lesson: localLesson,
              revision: 0,
              deleted: false,
              updatedAt: DateTime.now().toUtc(),
            ),
            remote: null,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: CurriculumScreen(apiService: api)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('So sánh'));
      await tester.pumpAndSettle();
      expect(find.text('Máy chủ chưa có bản lưu cho từ này.'), findsOneWidget);
      expect(find.text('Giữ bản máy chủ'), findsNothing);
      await tester.tap(find.text('Giữ bản trên thiết bị'));
      await tester.pumpAndSettle();
      expect(api.resolved, 'local');
    },
  );

  testWidgets(
    'stale import preview refreshes and requires confirmation again',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _UiApi()..staleOnce = true;
      final transport = _Transport()
        ..bytes = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'format': 'lingua_canvas_backup',
              'version': 1,
              'backup_id': 'stale-ui',
              'created_at': DateTime.now().toUtc().toIso8601String(),
              'private_lessons': [],
              'cards': [],
              'review_logs': [],
              'completed_lessons': [],
              'daily_activity': {},
            }),
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            apiService: api,
            accountService: _GuestAccountService(api),
            backupTransport: transport,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Nhập sao lưu'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Nhập sao lưu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gộp dữ liệu đã xem trước'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận gộp'));
      await tester.pumpAndSettle();
      expect(api.merges, 0);
      expect(find.textContaining('xem trước mới'), findsOneWidget);
      await tester.tap(find.text('Gộp dữ liệu đã xem trước'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận gộp'));
      await tester.pumpAndSettle();
      expect(api.merges, 1);
    },
  );

  testWidgets('guest words are offered only after linking and need opt-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _UiApi();
    var profileRefreshes = 0;
    api.guestExported = ProfileBackup(
      backupId: 'guest-backup',
      createdAt: DateTime.now().toUtc(),
      privateLessons: [
        PrivateLessonState(
          lesson: LessonItem(
            id: 'custom_en_guest',
            language: 'en',
            category: 'custom',
            targetText: 'guest',
            phoneticOrKana: '',
            meaningVi: 'Khách',
            workplaceContext: '',
            workplaceContextVi: '',
            strokeOrderHints: const [],
            difficultyLevel: 2,
          ),
          revision: 0,
          deleted: false,
          updatedAt: DateTime.now().toUtc(),
          localVersion: 1,
          pending: true,
        ),
      ],
      cards: const [],
      reviewLogs: const [],
      completedLessons: const [],
      dailyActivity: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          apiService: api,
          accountService: _LinkedAccountService(api),
          backupTransport: _Transport(),
          onProfileDataChanged: () => profileRefreshes++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.merges, 0);
    await tester.ensureVisible(find.text('Xem và chọn dữ liệu để gộp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xem và chọn dữ liệu để gộp'));
    await tester.pumpAndSettle();
    expect(find.text('guest'), findsOneWidget);
    await tester.tap(find.text('Xem trước'));
    await tester.pumpAndSettle();
    expect(api.merges, 0);
    await tester.tap(find.text('Xác nhận gộp'));
    await tester.pumpAndSettle();
    expect(api.merges, 1);
    expect(profileRefreshes, 1);
  });

  testWidgets('curriculum and settings stay laid out at four screen sizes', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in const [
      Size(390, 844),
      Size(768, 1024),
      Size(1440, 900),
      Size(1440, 600),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final api = _UiApi();
      await tester.pumpWidget(
        MaterialApp(home: CurriculumScreen(apiService: api)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Curriculum at $size');
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            apiService: api,
            accountService: _GuestAccountService(api),
            backupTransport: _Transport(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Settings at $size');
    }
  });
}
