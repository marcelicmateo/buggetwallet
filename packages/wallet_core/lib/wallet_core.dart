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

export 'src/accounts.dart' show AccountBalance, accountBalances, balanceTotals;
export 'src/backup.dart'
    show
        backupBlobBytesDefault,
        backupBytes,
        backupBytesWithInfo,
        BackupException,
        BackupFailure,
        backupFileName,
        backupPayload,
        BackupResult,
        backupVersion,
        mergeBackupBytes,
        MergeResult,
        restoreBackupBytes;
export 'src/bill_history.dart' show BillMonth, BillMonthState, billHistory;
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
        BudgetProposal,
        budgetProposals,
        budgetVsActual,
        CategoryBudgetLine,
        computePeriod,
        dueBills,
        DueCycle,
        dueCycles,
        duePlanned,
        expectedIncomeCycles,
        IncomeCycle,
        monthsToGoal,
        MonthSummary,
        monthSummary,
        PeriodBudget,
        reviewState,
        samePaydayDays,
        suggestBudgets,
        Verdict;
export 'src/categories.dart'
    show
        BudgetKind,
        builtInMerchantRules,
        categories,
        Categorizer,
        CategoryRow,
        CategoryTable,
        flexCategories,
        kindOf,
        merchantKey,
        merchantName,
        rollUp,
        spendingCategories;
export 'src/dates.dart'
    show
        addDays,
        currentPeriodStart,
        dayOf,
        daysBetween,
        daysInMonth,
        isIsoDate,
        isoDate,
        monthOf,
        monthsEnding,
        nextPayday,
        parseIso,
        requireIsoDate;
export 'src/export.dart'
    show
        centsToDecimal,
        csvField,
        monthlySummaryCsv,
        monthlySummaryCsvHeader,
        monthlySummaryCsvHeaderFor,
        transactionsCsv,
        transactionsCsvHeader,
        transactionsCsvTagsHeader;
export 'src/hlc.dart' show ClockBehindException, Hlc, HlcClock, maxClockDrift;
export 'src/ics.dart' show CalendarEvent, calendarEventRef, calendarRef, IcsParseResult, parseIcs, plannedIcs;
export 'src/insights.dart'
    show
        BudgetMonth,
        budgetVsActualSeries,
        biggestRows,
        CategoryCompare,
        CategoryShare,
        categoryShare,
        CategorySlice,
        compareCategory,
        IncomeVsSpending,
        incomeVsSpending,
        MerchantTotal,
        merchantsIn,
        merchantTrend,
        MonthBar,
        rowsFor,
        rowsForTag,
        spendingByMonth,
        TagShare,
        tagShare,
        TagSlice,
        tagTrend;
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
        Account,
        CategorizedTx,
        comparePart,
        Goal,
        GoalContribution,
        goalTotal,
        instalmentsLeft,
        PlannedCost,
        PlannedSource,
        PlannedStatus,
        RecurringBill,
        RecurringPeriod,
        resetInvalidSettingLog,
        ReviewState,
        ReviewStep,
        Tx,
        WalletSettings,
        wholePayments,
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
export 'src/ranges.dart' show DateRange, RangeKind, rangeFor, rangeLabel, shiftRange;
export 'src/recurring.dart' show detectRecurring, medianCents, partsDays, partsThreshold, planRecurringPayments, RecurringPayments;
export 'src/repo.dart'
    show
        ImportSummary,
        Op,
        WalletRepo,
        WalletRepoAccounts,
        WalletRepoCategories,
        WalletRepoBills,
        WalletRepoBlobs,
        WalletRepoPlanned,
        WalletRepoRecurring,
        WalletRepoSettings,
        WalletRepoSplits,
        WalletRepoTags;
export 'src/reports.dart'
    show CategoryPeriod, categoryByPeriod, PeriodReport, periodReports, SavedByWaiting, savedByWaiting, savedByWaitingAll;
export 'src/rules.dart' show merchantPatternId, MerchantPattern, MerchantRule, MoveDirection, RuleKind, ruleHits, rulesView, RuleView;
export 'src/search.dart' show foldText, parseAmountQuery, searchableColumns, searchAll, SearchResult, searchRows, searchTxLimit;
export 'src/splits.dart' show decodeSplitParts, encodeSplitParts, SplitPart, splitFits;
export 'src/suggest.dart' show PlanSuggestion, planProposals, SettingProposal, Suggested, suggestPlan;
export 'src/sync.dart'
    show relayFingerprint, SyncDevice, SyncException, SyncProblem, SyncProblemReason, syncReaderVersion, SyncReport, SyncWaiting;
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
export 'src/tags.dart' show recommendedMainTags, recommendedTags, suggestTags, TagContext, tagPayee, TagRow, tagsOf, TagTable;
export 'src/transfers.dart' show openTransfers, planTransfers, transferDays, TransferPlan;
export 'src/vault.dart'
    show
        aadBackup,
        aadBlob,
        aadSnapshot,
        aadSyncFile,
        aadWebKey,
        deriveKey,
        maxUnsealBytes,
        seal,
        unseal,
        UnsealFailure,
        VaultException,
        VaultKey;
