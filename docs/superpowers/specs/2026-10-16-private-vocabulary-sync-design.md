# Private vocabulary and safe backup — approved design 2026-10-16

Authority: user explicitly requested implementation of the Vietnamese plan “Kho từ cá nhân đồng bộ và sao lưu an toàn”. The decisions below make its interfaces concrete; do not omit approved behavior to reduce scope.

## Outcomes

All three supported platforms (Web/Android/Linux) create/edit/soft-delete/restore personal words, synchronize complete LessonItem metadata privately, resolve concurrent offline edits by user choice, export/import an active-profile backup by merging, and offer explicit guest→account transfer with preview. No hard deletion, automatic guest migration, PWA, new learning modes, public deploy or merge. Keep155publiclessons andFSRSalgorithm unchanged. Preserve all prior accounts/backend/profile isolation and durable-save behavior.

First repair PR3's fresh rustls audit (minimum0.23.46, no newignore) and browser TTS recovery; push those fixes on codex/web-platform. Then branch codex/private-vocabulary-sync from that updated head; new feature gets separate scoped PR. KeepFlutter3.47.6/Dart3.13.5 with tools/flutter. Add official file_selector1.1.0 and promote existing crypto3.0.7 direct; only necessary lockfile updates.

## Shared wire contract (v1, additive)

Existing POST /api/v1/sync review/completion fields remain. New optional arrays:

- custom_lesson_mutations: [{mutation_id:String, base_revision:int>=0, lesson:LessonItemJSON, deleted:bool}]. Lesson category must be custom; language en/ja; ID1..64ASCIIchars, noNUL; only authenticated nondefault_user maysend. Metadata never goes into public lessons/synthetic FK rows. Reject private metadata whose ID is a public curriculum ID, preventing shadow/overwrite of built-in lessons. Boundedrequest/fieldvalidation rejects invalid data without losingclientqueue.
- progress_imports: [{mutation_id:String, cards:[FsrsCardDto], completed_lessons:[SyncCompletedLessonItem]}]. An import chunk is idempotent and scoped to the authenticated account; use own-state snapshot upserts without running FSRS. Keep newer server last_review/completed_at; equal values keepserver. Validate finite/ranged FSRS values and timestamps with existing5minfutureclockpolicy; errors are explicit.

New response fields (always included by new server): capabilities:{private_vocabulary_sync:1,progress_import:1}; custom_lesson_acks:[{mutation_id,state:PrivateLessonWireState}]; progress_import_acks:[mutation_id]; custom_lesson_conflicts:[{mutation_id,server:PrivateLessonWireState|null}]. Existing review ACK fields stay. GET /sync/pull adds private_lessons:[PrivateLessonWireState], scoped to authenticated account and user cursor. Unauthenticated pull returns empty private_lessons. PrivateLessonWireState={lesson:LessonItemJSON,revision:int>=1,deleted:bool,updated_at:RFC3339UTC}.

The server owns revisions/timestamps. Apply custom mutation iff base_revision equals current revision (missing=0); persist idempotent receipt atomically with state/sequence. Repeating the same mutation returns original receipt, not a new revision; reusing its ID with different payload rejects. A stale base with identical payload/deleted state may ACK unchanged; otherwise return conflict preserving current server state. Tombstones retained indefinitely. Public GETlessons/id never reveals metadata. Use peraccount writer/pull barriers already established. Process custom metadata before related review/progress entries; do not advance blocked item's mutations while unrelated items continue.

Client only deletes explicit ACKed custom/import mutations. Oldserver missingcapabilities/ACK keeps thosequeues and displays upgrade-required; legacy review synchronization remainsfunctional. Batch serialized requests <=512KiB under1MiBproxy and max50entries, splitting imports byentity asneeded; one oversizeentry remainsvisibleerror, never silentlydiscarded.

## Domain contracts and concurrency

Add PrivateLessonState (lesson,revision,deleted,updatedAt,localVersion,pending,conflict with local/remote versions). Add typed store methods getPrivateLessons(includeDeleted=false), getPrivateLesson(id), savePrivateLesson(lesson), deletePrivateLesson(id), restorePrivateLesson(id), resolvePrivateLessonConflict(id,keepLocal), applyPrivateLessonSync(acks/conflicts/deltas) plus backup operations describedbelow. Names may be adjusted only jointly across owners; report any contract changes before dependent UI work.

Each local mutation/state/outbox change is one durable transaction. baseRevision represents lastacceptedserver revision; capture localVersion per outgoingmutation. In-flight ACK may remove only its own mutation and mustnot overwrite a newer local edit/delete; descendant mutations use the ACK's revision. Coalesce only unsent local mutations; retries keepidentity. Remote delta never overwrites dirty/conflicted local metadata. Conflict blocks thatword's sync, not theprofile; userkeepLocal createsnewmutationagainst latestknownserver revision; keepServer atomically appliesremote and removes supersededlocal metadata mutations. A newerremote arriving while conflict is visible refreshes preview; never discardlocal candidate. Keepreview/history entities intact duringmetadata resolution.

Existingcatalog cache mustnot replaceprivate records. Deletedwords hidden fromcurriculum/practice/due; historicalstats retained, restore resumesexistingcard. NewwordID custom_<lang>_<128bithex>; renames retainID. Do notautomatically merge distinctIDs with identicalspelling. RetainvalidlegacyIDs; for oldIDs>64chars canonical ID custom_<lang>_<first32hexSHA256(UTF8(oldID))>. Persist alias map and atomically remap cards/review itemIDs/completions/queue payloads/lessonlinks in every activeandinactiveprofile; reviewIDsunchanged. Detectaliascollision ratherthanoverwrite.

SQLite schema4→5 and browser snapshot1→2 migrate withoutloss ormemoryfallback, including inactive snapshots. Initialize states/outbox once from legacycustomlessons; accountprofiles becomeeligibleforsync, guestsremainlocal. A server's synthetic custom placeholder never wins over a proper personal record. Upgrade savefailure leaves olddurable data untouched/retryable.

## Backup and guest transfer

ProfileBackup JSONv1: format='lingua_canvas_backup',version=1,backup_id(stable for that exported snapshot),created_at,private_lessons(includingtombstones),cards,review_logs,completed_lessons,daily_activity. Export excludes PIN/token/accountconfig/backendsettings/clientidentity/cursors and rawqueue restoration. It includes currentlocal unsyncedstate, not credentials. Unknownversions/corrupt/oversize>10MiB reject wholefile beforewrite. Validate referenced IDs/immutable reviewID collisions and complete payload; do not silently drop unknown/bad entries.

ProfileMergePreview binds backup+target profile identity/backend+generation/contentrevision and lists additions/updates/skips/conflicts. merge requires thatbinding stillcurrent, or asks topreviewagain. Entiremerge commitsatomically; no quota/abort partialwrite. Preserve destinationpendingqueue and anycard with pendingreview. Merge byID; keep newer progress, unionimmutable reviewIDs, do not doublecountactivity/reimport. Source account server revisions are NOT copied into destination; generate destination-scoped mutation IDs and base from destination state. Ambiguous different wordmetadata uses same manual conflict UI. Reimportsamebackup is idempotent (receipts keyedbackupID,targetprofile,entity) and never incrementsFSRS.

Importedhistory remainslocal history, not replayed as reviews. Newerimportedcard/completion snapshots enqueue progress_imports forlinkedaccount; guestimport stayslocal. Existing pendingreviewswin. Test sourceoriginaldevice laterflushes queuedreviews in eitherorder: server's strict review_time>last_review plus baseline imports mustnot doubleadvanceFSRS. Source snapshot dates exceedingexistingclockpolicy failvisibly ratherthancreatingpermanentfuturestate.

Export holds profilelock only to obtainsnapshot, neveracrossfiledialog. Openingimport/preview doesnotmutatestorage. Merge afterprofile/backendchange rejected. On register/login UIoffers selectable guestwords+associatedprogress preview, calls same merge engine, leavesoriginalguestprofile andqueue intact, nevercopiesauthentication or silentlytransfers. Guest export must explicitly read guestprofile scoped to currentbackend; no token/profileflippingvisibletoUI.

## File transport and UI

BackupFileTransport: pickBackup()->Future<Uint8List?>; saveBackup(Uint8List bytes,{required String suggestedName})->Future<bool> (false=usercancel). Boundedreads before decode. file_selector open allplatforms; Linux getSaveLocation/XFile.saveTo; WebBlobdownload/revokeURL; Android ACTION_CREATE_DOCUMENT MethodChannel com.linguacanvas.app/backup with one pendingoperation, cancellation/lifecyclecleanup, no broadstoragepermission. All native imports behindconditionalexports; inject transport in tests.

Curriculum ownwordedit, trashfilter/restore, conflictcomparison actions; built-in155lessonsreadonly. Settings BackupPanel export/import/preview/merge with explicit confirmation for crossprofilecopies, accountcard guesttransferoffer. Analytics queue counts include new mutationtypes and differentiateunsupported/conflict/retry. Retainlayout/nav/profilegeneration/TTS-speechcancellation fromwebplatform.

## Evidence required

TDD targeted RED/GREEN for each domain, migrationincludinginactive/longIDs, CAS edit/edit-edit/delete-restore/delete, outoforderACK/delta/retry, authisolation/publiccatalogprivacy, oldserverqueuepreservation, backupidempotency/pendingreview/guesttransfer/profilepreviewstaleness, quota/IDBactualabort. ActualSQLite +IndexedDB→HTTPPostgreSQL→secondclient fullmetadata/tombstones/progress. UI fourviewports390x844,768x1024,1440x900,1440x600, realBrowserreview. FullFlutter/Rust/E2E/adversarial/auditfresh/format/analyzer/clippy/buildWebLinuxAndroid, completegraphbeforecommits. Each task reviewed, final wholebranch review. CIallgreen beforefinalcompletion; pushscopedPR, no merge/deploy. Report remaining physical filepicker/audio QA honestly.
