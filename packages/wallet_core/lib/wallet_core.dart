/// Budget Wallet core: local SQLite database, change log, end-to-end
/// encrypted relay sync and the budget engine.
///
/// Compiles for the web (dart2js and dart2wasm): the dart:io parts (`*_io.dart`) are swapped for stubs
/// (`*_web.dart`) that throw [UnsupportedError]; `tool/web_smoke.dart` is the compile check.
///
/// Every export lists what it shows: what the app, the relay and the tests use. A helper another core file needs
/// stays public inside `src/` without being shown; one used in its own file only is private there.
library;

export 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource, NormalizedBill, TxKind;

export 'src/backup.dart' show backupBytes, BackupException, BackupFailure, backupFileName, backupPayload, backupVersion, restoreBackupBytes;
export 'src/bills.dart'
    show
        Bill,
        billCandidates,
        billCoveredBy,
        billLinkTokens,
        billPayeeKey,
        BillStatus,
        BlobRef,
        descriptionHasToken,
        maxBillItemName,
        maxBillItems,
        occurrenceKey,
        planBillLinks,
        plannedCoverage,
        plannedCoveredBy,
        plannedReserves,
        sha256Hex,
        suggestBillCategory;
export 'src/blob_store.dart' show blobCacheBytesNative, blobCacheBytesWeb, BlobStore, isBlobHash, maxBlobPlainBytes;
export 'src/budget.dart'
    show
        Affordability,
        affordability,
        averageByCategory,
        BudgetVsActual,
        budgetVsActual,
        CategoryBudgetLine,
        computePeriod,
        dueBills,
        duePlanned,
        monthsToGoal,
        MonthSummary,
        monthSummary,
        PeriodBudget,
        reviewState,
        samePaydayDays,
        suggestBudgets,
        Verdict;
export 'src/categories.dart'
    show BudgetKind, builtInMerchantRules, categories, Categorizer, flexCategories, kindOf, merchantKey, merchantName, spendingCategories;
export 'src/dates.dart'
    show addDays, dayOf, daysBetween, daysInMonth, isIsoDate, isoDate, monthOf, monthsEnding, nextPayday, parseIso, requireIsoDate;
export 'src/export.dart' show centsToDecimal, csvField, monthlySummaryCsv, monthlySummaryCsvHeader, transactionsCsv, transactionsCsvHeader;
export 'src/hlc.dart' show Hlc, HlcClock;
export 'src/ics.dart' show CalendarEvent, calendarEventRef, calendarRef, IcsParseResult, parseIcs, plannedIcs;
export 'src/local_db.dart' show localDbKey, localDbKeyInfo, openKeyed, WalletDbKeyException;
export 'src/logs.dart'
    show
        describeError,
        describeErrorHook,
        formatLogRecord,
        Level,
        Logger,
        LogRecord,
        FrameStats,
        logError,
        LogEvent,
        logEvent,
        LogSink,
        MemoryLogSink,
        PerfTimer,
        timed,
        timedAsync;
export 'src/logs_io.dart' if (dart.library.js_interop) 'src/logs_web.dart' show RotatingFileSink;
export 'src/matching.dart' show MatchPlan, openEntries, planMatches, SeenBank;
export 'src/models.dart'
    show
        CategorizedTx,
        Goal,
        GoalContribution,
        goalTotal,
        PlannedCost,
        PlannedSource,
        PlannedStatus,
        RecurringBill,
        resetInvalidSettingLog,
        ReviewState,
        ReviewStep,
        Tx,
        WalletSettings,
        WishItem;
export 'src/periods.dart' show detectPaydays, periodSummaries, PeriodSummary, salaryPaydays, SavingsOverview, savingsOverview, trendNet;
export 'src/planned.dart'
    show
        amountFromText,
        HeadsUp,
        headsUps,
        maxAmountCents,
        normalizeTitle,
        paidCandidates,
        parseMoneyCents,
        upcoming,
        UpcomingItem,
        UpcomingKind;
export 'src/recurring.dart' show detectRecurring, medianCents, planRecurringPayments, RecurringPayments;
export 'src/repo.dart'
    show ImportSummary, merchantPatternId, Op, WalletRepo, WalletRepoBills, WalletRepoBlobs, WalletRepoPlanned, WalletRepoSettings;
export 'src/search.dart' show foldText, parseAmountQuery, searchableColumns, searchAll, SearchResult, searchRows, searchTxLimit;
export 'src/sync.dart' show SyncDevice, SyncException, SyncProblem, SyncProblemReason, syncReaderVersion, SyncReport, SyncWaiting;
export 'src/sync_engine.dart'
    show
        MemoryTransport,
        parseHttpDate,
        RelayDevice,
        RelaySnapshot,
        RelayState,
        RelayTransport,
        SyncEngine,
        SyncTransport,
        TransportException,
        TransportFailure;
export 'src/transfers.dart' show openTransfers, planTransfers, transferDays, TransferPlan;
export 'src/vault.dart' show deriveKey, seal, unseal, UnsealFailure, VaultException, VaultKey;
