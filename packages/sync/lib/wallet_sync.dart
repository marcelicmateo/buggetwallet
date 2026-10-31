/// Budget Wallet sync: the end-to-end encrypted relay sync engine ([SyncEngine]), its transports (relay over HTTP,
/// in memory for tests and the demo) and bill files on the relay ([BlobStore]). Builds on `package:wallet_core`
/// (database, change log, vault).
///
/// Compiles for the web (dart2js and dart2wasm): nothing here imports dart:io; `tool/web_smoke.dart` is the compile
/// check.
///
/// Every export lists what it shows: what the app, the relay and the tests use.
library;

export 'src/blob_store.dart' show blobCacheBytesNative, blobCacheBytesWeb, BlobStore, maxBlobPlainBytes;
export 'src/sync.dart'
    show relayFingerprint, SyncDevice, SyncException, SyncProblem, SyncProblemReason, syncReaderVersion, SyncReport, SyncWaiting;
export 'src/sync_blocked.dart' show BlockedFile, blockedFiles, skipBlockedFile;
export 'src/sync_engine.dart'
    show
        DeviceKeyTransport,
        deviceFingerprint,
        EnrolResult,
        MemoryDeviceTransport,
        MemoryTransport,
        newDeviceKey,
        parseHttpDate,
        RelayDevice,
        RelayKey,
        RelayPendingKey,
        RelaySnapshot,
        RelayState,
        RelayTransport,
        SyncEngine,
        SyncTransport,
        TransportException,
        TransportFailure;
