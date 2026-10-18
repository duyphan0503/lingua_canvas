# Private vocabulary synchronization and safe backup implementation

Spec: docs/superpowers/specs/2026-10-16-private-vocabulary-sync-design.md (approved user plan expanded into shared contracts).
Execution: Superpowers subagent-driven-development; shared currentcheckout perexistinguserpreference; explicit fileownership, no worker-spawnedreviewers. Controller commits documentation and orchestratesreviews. Workers mustnotrevert/stageothers. Root GitNexus calls serialized duringindexwrites; readimpacts beforeedits, warnHIGH/CRITICAL, confirmUNKNOWN, fullchangeanalysisbeforecommit.

## Task0 Foundation (parent PR3)
Ownerfoundationworker: minimalrustls>=0.23.46 relatedlockpatch,freshauditnoignore; webTTSrecovery forbothspeakerwidgets retainingnative. REDactualChrome2widgetcases; GREENfocusedVM/Chrome/analyzer/Rustgates. Commitownedfiles, taskreview, pushPR3. Onlythen rootcreatescodex/private-vocabulary-sync frompatchedparentandcommitspec/plan.

## Task1 Backend private metadata/progress protocol
Ownerbackendworker server/** except foundationlockalreadydone. Implement specwire DTOs/migration/accountprivateCASidempotentreceipts/tombstone/delta+safeprogressimports, memorymodeparity, oldfieldscompat/publicprivacy, testsrealPG. Backend additive deploymentorder first; nodeps/algorithmmodification. REDtargetedtests thenGREENallRust. Commitonlyserverfiles aftercompletegraph; taskreviewbeforeintegrationclosed. Noactualdeployment.

## Task2 Flutter storage/domain/synchronization/backup
Ownerdomainworker app/lib/services/**, app/lib/models/**, app/pubspec* and generatedplatformpluginregistrants frompubget ONLY; excludesfiletransportfiles ownedTask3. ImplementPrivateLessonState/LocalStore APIs,migrations4→5/1→2,allinactiveprofiles/longIDaliasing,atomicCRUD/conflicts/ACK/deltas,ApiService/SyncCoordinatorwire,ProfileBackup/Preview/merge/guestsource. Addfile_selector1.1.0,cryptodirectcurrentlylocked3.0.7,informtransportowneroncepubgetready. TypedDTOs sharedspec. TDDstrongpurelogic/native/actualIDBtests, oldserverandrace regressions. NoUIedits. Commitownedfiles aftergraph; taskreview.

## Task3 File transport
Ownertransportworker newapp/lib/services/backup_file_transport*.dart +AndroidMainActivitybackupbridge +newtransporttests. PublicBackupFileTransport spec exact. Implementwebblobdownload,file_selectoropen/Linuxsave,AndroidSAFcreate; bounded/cancel/dispose; no broadpermissions,noauthdata. DependencyTask2pubget; canimplementindependentlyandtestoncepubgetready. Commitownedfiles/graph; taskreview.

## Task4 UI and guest transfer
OwnerUIworker app/lib/screens/**,app/lib/widgets/** exceptfoundationTTSalreadydone +newUItests. DependsTask2APIsreadyandTask3transport. CurriculumCRUDtrashconflicts,Settingsbackupflow,currentprofilepreviewbinding,Account guesttransferoptin/sourcepreserved,Analyticsstatus. TDDfourviewport/readonlybuiltins/cancel/error/staleprofile/guestselectiontests; browserreviewroot. Commitownedfiles/graph; taskreview.

## Task5 Real integration + verification and delivery
Ownerintegrationworker tests/private_vocabulary/**,app/test/integration/**,server/tests/private_vocabulary_live.rs (coordinatebackendnewtests) +CIonlyneededrootreview. ProveSQLite/IDBHTTPPGtwoaccount/twodevice metadataCRUDCAS/tombstone/importidempotencysourcedeviceflushbothorders. ExplicitdisposableDB/ownedprocesscleanup andrealtransactions. Rootfullgates freshaudit/Flutter/Rust/E2E/adversarial/bothnative+webbuild, fourviewports Browser, updateddocsreport. Taskreview, finalwholebranchreviewmostcapableavailablemodel, fixesviaownerseachRED/GREENthenonescopedreview. PushnewscopedPR/attach, verifyremoteSHA+cleantree+allCIgreen; removeonlythisplanscratch. Do notmerge/deploy.

## Review focus
1Privateauthscope neverleaks via publiccatalog/default_user/backups.
2Durableatomicity/pendingmutations acrossquota/abort/account/backend/reset/guesttransfer.
3CASbase/retries/outoforderACK/editwhileinflight/stalepreview/nofalsequeueACKoldserver.
4BackupFSRSbaseline nohistoricalreplay/doubleadvance; sourceoldqueuebothorders.
5Inactiveprofilemigration/legacy64charFKlimit/allreferences/unknownformats.
6Filepicker cancellation/lifecycles/no nativeimportsweb/no credentials.
