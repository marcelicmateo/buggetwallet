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

export 'src/accounts.dart' show AccountBalance, accountBalances, accountSourceLabel, balanceInHome, balanceTotals;
export 'src/accounts.dart' show BalanceCheck, BankCheck, balanceTrusted, bankCheckTrustDays, checkBankBalance;
export 'src/accounts.dart'
    show
        accountMatchKey,
        accountMatchKeyInfo,
        ImportAccountQuestion,
        isAccountMatchKey,
        normalizeExportAccount,
        RowAccounts,
        withAccountKeys;
export 'src/backup.dart'
    show
        backupBlobBytesDefault,
        backupBytes,
        backupBytesWithInfo,
        BackupException,
        BackupFailure,
        backupFileName,
        backupPayload,
        backupPayloadOps,
        BackupResult,
        backupVersion,
        mergeBackupBytes,
        MergeResult,
        restoreBackupBytes;
export 'src/bill_history.dart' show BillMonth, BillMonthState, billHistory;
export 'src/bills.dart'
    show
        attachmentTypes,
        Bill,
        BillCols,
        PayeeAliasCols,
        billItemsProblem,
        billCandidates,
        billCoveredBy,
        billLinkTokens,
        billPayeeKey,
        BillStatus,
        BlobRef,
        blobTypes,
        descriptionHasToken,
        effectiveReturnReminderDays,
        effectiveWarrantyReminderDays,
        isBlobHash,
        maxAttachmentsPerTx,
        maxBillItemName,
        maxBillItems,
        occurrenceKey,
        payeeAliasId,
        planBillLinks,
        plannedCoverage,
        plannedCoveredBy,
        plannedReserves,
        resolvePayeeAlias,
        sha256Hex,
        suggestBillCategory;
export 'src/budget.dart'
    show
        Affordability,
        affordability,
        averageByCategory,
        countsAsSpending,
        averageOut,
        changePermille,
        BudgetPreset,
        BudgetPresetKind,
        budgetPreset,
        BudgetVsActual,
        BudgetProposal,
        budgetProposals,
        budgetVsActual,
        CategoryBudgetLine,
        computePeriod,
        DayMark,
        DaySpend,
        monthlyFlex,
        dueBills,
        DueCycle,
        dueCycles,
        duePlanned,
        expectedIncomeCycles,
        GoalTotals,
        goalTotals,
        IncomeCycle,
        monthsToGoal,
        MonthSummary,
        monthSummary,
        PeriodBudget,
        PeriodDay,
        PeriodReserves,
        periodDays,
        periodDaySpend,
        PlanSplit,
        projectedReserves,
        reviewState,
        reviewStreak,
        samePaydayDays,
        suggestBudgets,
        Verdict;
export 'src/categories.dart'
    show
        BudgetKind,
        CategoryCols,
        builtInMerchantRules,
        BuiltInRule,
        builtInRuleById,
        builtInRulePrefix,
        builtInRules,
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
export 'src/changes.dart' show ChangeEntry;
export 'src/cols.dart' show clearValue, Col, DateCol, EnumCol, FlagCol, IntCol, JsonCol, MoneyCol, RefCol, RowModel, TextCol;
export 'src/currencies.dart'
    show
        allCurrencies,
        CurrencyInfo,
        currencyInfo,
        displayDigitsOf,
        minorDigitsOf,
        prevalentCurrency,
        prevalentMinRows,
        prevalentPercent,
        storageDigitsOf;
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
export 'src/ecb.dart'
    show
        EcbCacheInfo,
        ecbConvert,
        ecbDamagedMessage,
        EcbFile,
        ecbFirstDay,
        EcbHistory,
        ecbHistoryUrl,
        EcbImport,
        ecbMaxGapDays,
        ecbNotRatesMessage,
        EcbPair,
        ecbPrecisionMessage,
        EcbRates,
        ecbRecentUrl,
        ecbScale,
        FxDay,
        FxDayCols,
        fxDayId,
        FxNeed,
        fxNeeds,
        parseEcbRates;
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
export 'src/findings.dart' show Finding, FindingKind, findings;
export 'src/forecast.dart'
    show BalanceWarning, BalanceWarningKind, balanceWarnings, ForecastPoint, forecastAfterAllowance, forecastToPayday;
export 'src/fx.dart' show convertMinor, FxUsed, fxUsed, homeAmount, inHomeCurrency;
export 'src/goal_plan.dart' show addMonths, annuityPayment, GoalLever, GoalLeverKind, goalLevers, GoalPlan, goalPlan, goalTarget;
export 'src/hlc.dart' show ClockBehindException, Hlc, HlcClock, maxClockDrift;
export 'src/hours.dart' show hoursTenths;
export 'src/ics.dart' show CalendarEvent, calendarEventRef, calendarRef, IcsParseResult, legacyCalendarEventRef, parseIcs, plannedIcs;
export 'src/import_preview.dart' show ImportPreview, PreviewRow, PreviewStatus;
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
        compareTag,
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
export 'src/loan.dart' show LoanLeft, loanLeft;
export 'src/loans.dart'
    show
        Loan,
        LoanCheck,
        LoanCheckCols,
        LoanCheckView,
        loanCheckView,
        loanBalanceOn,
        LoanEnded,
        loanEndedProposals,
        loanReferenceMinLength,
        loanReferenceUsable,
        loanRegularPayment,
        LoanYear,
        loanYears,
        LoanCols,
        LoanDecisions,
        loanPaymentDecisions,
        LoanMonth,
        LoanPayCols,
        LoanPaymentMatch,
        loanPaymentOn,
        loanPayments,
        LoanRate,
        LoanRateCols,
        loanSchedule,
        LoanState,
        loanState,
        loanWhatIf,
        LoanWhatIf;
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
        LogSafeError,
        logError,
        LogEvent,
        logEvent,
        LogSink,
        MemoryLogSink,
        PerfTimer,
        timed,
        timedAsync;
export 'src/logs_io.dart' if (dart.library.js_interop) 'src/logs_web.dart' show RotatingFileSink;
export 'src/matching.dart' show encodeMatchOff, MatchPlan, matchOffIds, maxMatchOff, openEntries, planMatches, SeenBank;
export 'src/models.dart'
    show
        Account,
        AccountCols,
        AccountKind,
        BuiltInRuleOverride,
        CategorizedTx,
        comparePart,
        FxRate,
        Goal,
        GoalCols,
        GoalContribCols,
        GoalContribution,
        goalTotal,
        instalmentsLeft,
        Iou,
        IouCols,
        IouDirection,
        IouPart,
        IouPartCols,
        IouView,
        PlannedCols,
        PlannedCost,
        PlannedSource,
        PlannedStatus,
        RecurringBill,
        RecurringCols,
        RecurringPeriod,
        resetInvalidSettingLog,
        ReviewCols,
        ReviewState,
        RuleCols,
        ReviewStep,
        Tx,
        TxCols,
        WalletSettings,
        wholePayments,
        WishCols,
        WishItem;
export 'src/periods.dart' show detectPaydays, periodSummaries, PeriodSummary, salaryPaydays, SavingsOverview, savingsOverview, trendNet;
export 'src/planned.dart'
    show
        amountFromText,
        billOccurrences,
        HeadsUp,
        headsUps,
        maxAmountCents,
        normalizeTitle,
        paidCandidates,
        parseMoneyCents,
        upcoming,
        UpcomingItem,
        UpcomingKind;
export 'src/planned.dart' show isSafeCents, legacyRowCapCents;
export 'src/planned.dart' show AutoPaid, planAutoPaid;
export 'src/projects.dart' show ProjectStats, projectEndedDays, projectStats;
export 'src/ranges.dart' show DateRange, RangeKind, rangeFor, rangeLabel, shiftRange;
export 'src/recurring.dart' show recurringCost;
export 'src/recurring.dart' show detectRecurring, medianCents, partsDays, partsThreshold, planRecurringPayments, RecurringPayments;
export 'src/repo.dart'
    show
        ImportSummary,
        Op,
        WalletRepo,
        WalletRepoAccounts,
        WalletRepoCategories,
        WalletRepoChanges,
        WalletRepoBills,
        WalletRepoBlobs,
        WalletRepoFx,
        WalletRepoImport,
        WalletRepoIou,
        WalletRepoLoans,
        WalletRepoMatch,
        WalletRepoMeta,
        WalletRepoPatch,
        WalletRepoPlanned,
        WalletRepoRecurring,
        WalletRepoSettings,
        WalletRepoSplits,
        WalletRepoSyncApply,
        WalletRepoTags,
        WalletRepoTx,
        WalletRepoViews;
export 'src/reports.dart'
    show CategoryPeriod, categoryByPeriod, PeriodReport, periodReports, reviewsIn, SavedByWaiting, savedByWaiting, savedByWaitingAll;
export 'src/rules.dart' show PayeeCount, RuleSuggestion, ruleSuggestionFor, ruleSuggestions, uncategorisedPayees;
export 'src/rules.dart' show merchantPatternId, MerchantPattern, MerchantRule, MoveDirection, RuleKind, ruleHits, rulesView, RuleView;
export 'src/search.dart' show matchSpans, SearchFilter;
export 'src/search.dart'
    show foldText, parseAmountQuery, searchableColumns, searchAll, SearchResult, searchRows, searchRuleLimit, searchTxLimit;
export 'src/series.dart'
    show
        Bucket,
        bucketFor,
        bucketLabel,
        bucketsOf,
        BudgetBar,
        budgetSeries,
        DayIndex,
        HeatCell,
        heatmap,
        incomeSeries,
        IncomeSpendingBar,
        Measure,
        MoveTogether,
        moveTogether,
        QueryRow,
        runQuery,
        SavedView,
        SeriesBar,
        SeriesKey,
        SeriesKind,
        SeriesQuery,
        seriesQueryProblem,
        spendingSeries,
        ViewCols;
export 'src/splits.dart' show decodeSplitParts, encodeSplitParts, SplitCols, SplitPart, splitFits;
export 'src/suggest.dart' show PlanSuggestion, planProposals, SettingProposal, Suggested, suggestPlan;
export 'src/sync_conflicts.dart' show SyncConflict;
export 'src/tags.dart' show recentPayees, suggestCategoriesForText;
export 'src/tags.dart'
    show recommendedMainTags, recommendedTags, RuleTagCols, suggestTags, TagCols, TagContext, tagPayee, TagRow, tagsOf, TagTable, TxTagCols;
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
