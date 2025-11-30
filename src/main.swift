import Cocoa
import ApplicationServices
import Carbon
import SQLite3

typealias CGKeyCode = UInt16

/// Represents the key count for a specific hour of day.
struct HourlyActivityRecord {
    /// Hour of day in 24-hour format (0–23).
    let hour: Int

    /// Total keypresses recorded during the hour.
    let count: Int
}

/// Represents the key count for a specific date.
struct DailyActivityRecord {
    /// Calendar day the activity was logged for.
    let date: Date

    /// Number of keypresses recorded during the day.
    let count: Int
}

/// Represents consecutive-day usage streak information.
struct KeypressStreak {
    /// Total number of consecutive days where at least one keypress occurred.
    let lengthInDays: Int

    /// Date of the last day included in the streak.
    let endDate: Date
}

/// Represents the frequency for a single key.
struct KeyFrequency {
    /// Printable character or symbolic name of the key.
    let key: String

    /// Number of times the key was pressed over the aggregation period.
    let count: Int
}

private enum KeyNameResolver {
    private static let keyCodeNames: [UInt16: String] = [
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Backspace",
        UInt16(kVK_Escape): "Escape",
        UInt16(kVK_Command): "Command",
        UInt16(kVK_Shift): "Shift",
        UInt16(kVK_CapsLock): "CapsLock",
        UInt16(kVK_Option): "Option",
        UInt16(kVK_Control): "Control",
        UInt16(kVK_RightShift): "RightShift",
        UInt16(kVK_RightOption): "RightOption",
        UInt16(kVK_RightControl): "RightControl",
        UInt16(kVK_Function): "Fn",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_VolumeUp): "VolumeUp",
        UInt16(kVK_VolumeDown): "VolumeDown",
        UInt16(kVK_Mute): "Mute",
        UInt16(kVK_ANSI_KeypadEnter): "Enter",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_Help): "Help",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_PageUp): "PageUp",
        UInt16(kVK_ForwardDelete): "DeleteForward",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_End): "End",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_PageDown): "PageDown",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_LeftArrow): "ArrowLeft",
        UInt16(kVK_RightArrow): "ArrowRight",
        UInt16(kVK_DownArrow): "ArrowDown",
        UInt16(kVK_UpArrow): "ArrowUp"
    ]

    static func readableName(for event: NSEvent) -> String? {
        let keyCode = event.keyCode
        return keyCodeNames[keyCode]
    }
}

// Global counters
var totalCount: Int = 0
var keypressStore: KeypressStore?

// Keep strong references so they don't get deallocated
var eventTap: CFMachPort?
var runLoopSource: CFRunLoopSource?

enum KeypressStoreError: LocalizedError {
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            return message
        }
    }
}

final class KeypressStore {
    private struct BucketAccumulator {
        var startDate: Date
        var perKeyCounts: [String: Int]
        var totalKeys: Int
        var backspaceCount: Int
        var sumIntervalMs: Int64
        var intervalSamples: Int
        var lastTimestamp: Date?
    }

    private let queue = DispatchQueue(label: "com.keydometer.keypress-store")
    private var db: OpaquePointer?
    private var keyBucketInsertStatement: OpaquePointer?
    private var bucketStatsInsertStatement: OpaquePointer?
    private var totalStatement: OpaquePointer?
    private var rangeStatement: OpaquePointer?
    private var keyFrequencyStatement: OpaquePointer?
    private let calendar = Calendar.current
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let bucketSizeSeconds: Int = 60
    private let userId: Int64 = 1
    private var currentBucket: BucketAccumulator?
    private var scheduledFlushBucketStart: Date?

    init() throws {
        let databaseURL = try KeypressStore.databaseURL()
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            let error = currentErrorMessage()
            if let db = db {
                sqlite3_close(db)
            }
            throw KeypressStoreError.initializationFailed("Unable to open database: \(error)")
        }

        try createTables()
        try prepareStatements()
    }

    deinit {
        finalizeStatements()
        if let db = db {
            sqlite3_close(db)
        }
    }

    func loadTotalCount() -> Int {
        return queue.sync {
            totalCountLocked()
        }
    }

    func recordKeypress(at date: Date = Date(), key: String) {
        let normalizedKey = key.isEmpty ? "Unknown" : key
        queue.async { [weak self] in
            self?.appendKeypress(date: date, key: normalizedKey)
        }
    }

    func flushPendingData() {
        queue.sync {
            flushCurrentBucketLocked()
        }
    }

    // MARK: - Private helpers

    private func appendKeypress(date: Date, key: String) {
        let bucketStart = bucketStartDate(for: date)

        if let bucket = currentBucket {
            if bucket.startDate != bucketStart {
                flushCurrentBucketLocked()
                startNewBucket(startDate: bucketStart, referenceDate: date)
            }
        } else {
            startNewBucket(startDate: bucketStart, referenceDate: date)
        }

        guard var bucket = currentBucket else { return }
        bucket.totalKeys += 1
        bucket.perKeyCounts[key, default: 0] += 1
        if key.caseInsensitiveCompare("Backspace") == .orderedSame {
            bucket.backspaceCount += 1
        }

        if let previous = bucket.lastTimestamp {
            let intervalSeconds = max(0.0, date.timeIntervalSince(previous))
            bucket.sumIntervalMs += Int64(intervalSeconds * 1000)
            bucket.intervalSamples += 1
        }
        bucket.lastTimestamp = date
        currentBucket = bucket
    }

    private func bucketStartDate(for date: Date) -> Date {
        if let interval = calendar.dateInterval(of: .minute, for: date) {
            return interval.start
        }
        let bucketLength = TimeInterval(bucketSizeSeconds)
        let seconds = floor(date.timeIntervalSince1970 / bucketLength) * bucketLength
        return Date(timeIntervalSince1970: seconds)
    }

    private func startNewBucket(startDate: Date, referenceDate: Date) {
        currentBucket = BucketAccumulator(
            startDate: startDate,
            perKeyCounts: [:],
            totalKeys: 0,
            backspaceCount: 0,
            sumIntervalMs: 0,
            intervalSamples: 0,
            lastTimestamp: nil
        )
        scheduleFlush(for: startDate, referenceDate: referenceDate)
    }

    private func scheduleFlush(for startDate: Date, referenceDate: Date) {
        scheduledFlushBucketStart = startDate
        let bucketEnd = startDate.addingTimeInterval(TimeInterval(bucketSizeSeconds))
        let baseline = max(referenceDate, Date())
        let delay = max(0.1, bucketEnd.timeIntervalSince(baseline) + 0.25)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            if let bucket = self.currentBucket,
               bucket.startDate == startDate {
                self.flushCurrentBucketLocked()
            }
        }
    }

    private func flushCurrentBucketLocked() {
        guard let bucket = currentBucket else { return }
        currentBucket = nil
        if scheduledFlushBucketStart == bucket.startDate {
            scheduledFlushBucketStart = nil
        }
        guard bucket.totalKeys > 0 else { return }
        persist(bucket: bucket)
    }

    private func persist(bucket: BucketAccumulator) {
        guard db != nil else { return }
        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK {
            NSLog("Keydometer: failed to begin transaction: \(currentErrorMessage())")
            return
        }

        var committed = false
        defer {
            if committed {
                _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
            } else {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }

        let startTimestamp = Int64(bucket.startDate.timeIntervalSince1970)
        guard insertBucketStatsRow(bucket: bucket, startTimestamp: startTimestamp) else {
            return
        }

        for (key, count) in bucket.perKeyCounts {
            guard insertKeyBucketRow(key: key, count: count, startTimestamp: startTimestamp) else {
                return
            }
        }

        committed = true
    }

    private func insertBucketStatsRow(bucket: BucketAccumulator, startTimestamp: Int64) -> Bool {
        guard let statement = bucketStatsInsertStatement else { return false }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int(statement, 3, Int32(bucketSizeSeconds))
        sqlite3_bind_int(statement, 4, Int32(bucket.totalKeys))
        sqlite3_bind_int(statement, 5, Int32(bucket.backspaceCount))
        sqlite3_bind_int64(statement, 6, bucket.sumIntervalMs)
        sqlite3_bind_int(statement, 7, Int32(bucket.intervalSamples))

        if sqlite3_step(statement) != SQLITE_DONE {
            NSLog("Keydometer: failed to insert bucket_stats row: \(currentErrorMessage())")
            return false
        }
        return true
    }

    private func insertKeyBucketRow(key: String, count: Int, startTimestamp: Int64) -> Bool {
        guard let statement = keyBucketInsertStatement else { return false }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int(statement, 3, Int32(bucketSizeSeconds))
        _ = key.withCString { cString in
            sqlite3_bind_text(statement, 4, cString, -1, sqliteTransient)
        }
        sqlite3_bind_int(statement, 5, Int32(count))

        if sqlite3_step(statement) != SQLITE_DONE {
            NSLog("Keydometer: failed to insert key_buckets row: \(currentErrorMessage())")
            return false
        }
        return true
    }

    private static func databaseURL() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directory = base.appendingPathComponent("Keydometer", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory.appendingPathComponent("keydometer.sqlite")
    }

    private func createTables() throws {
        let sql = """
        DROP TABLE IF EXISTS key_logs;
        CREATE TABLE IF NOT EXISTS key_buckets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            bucket_start INTEGER NOT NULL,
            bucket_size_sec INTEGER NOT NULL,
            key_code TEXT NOT NULL,
            press_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_key_buckets_user_time
            ON key_buckets(user_id, bucket_start);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_key_buckets_unique
            ON key_buckets(user_id, bucket_start, bucket_size_sec, key_code);

        CREATE TABLE IF NOT EXISTS bucket_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            bucket_start INTEGER NOT NULL,
            bucket_size_sec INTEGER NOT NULL,
            total_keys INTEGER NOT NULL,
            backspace_count INTEGER NOT NULL,
            sum_interval_ms INTEGER NOT NULL,
            interval_samples INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_bucket_stats_user_time
            ON bucket_stats(user_id, bucket_start);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bucket_stats_unique
            ON bucket_stats(user_id, bucket_start, bucket_size_sec);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let error = currentErrorMessage()
            throw KeypressStoreError.initializationFailed("Unable to create tables: \(error)")
        }
    }

    private func prepareStatements() throws {
        let bucketInsertSQL = """
        INSERT INTO key_buckets(user_id, bucket_start, bucket_size_sec, key_code, press_count)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(user_id, bucket_start, bucket_size_sec, key_code)
        DO UPDATE SET press_count = key_buckets.press_count + excluded.press_count;
        """

        let statsInsertSQL = """
        INSERT INTO bucket_stats(user_id, bucket_start, bucket_size_sec, total_keys, backspace_count, sum_interval_ms, interval_samples)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(user_id, bucket_start, bucket_size_sec)
        DO UPDATE SET total_keys = bucket_stats.total_keys + excluded.total_keys,
                      backspace_count = bucket_stats.backspace_count + excluded.backspace_count,
                      sum_interval_ms = bucket_stats.sum_interval_ms + excluded.sum_interval_ms,
                      interval_samples = bucket_stats.interval_samples + excluded.interval_samples;
        """

        let totalSQL = """
        SELECT IFNULL(SUM(total_keys), 0)
        FROM bucket_stats
        WHERE user_id = ?1;
        """

        let rangeSQL = """
        SELECT IFNULL(SUM(total_keys), 0)
        FROM bucket_stats
        WHERE user_id = ?1 AND bucket_start >= ?2 AND bucket_start < ?3;
        """

        let keyFrequencySQL = """
        SELECT key_code, SUM(press_count) AS total
        FROM key_buckets
        WHERE user_id = ?1 AND bucket_start >= ?2 AND bucket_start < ?3
        GROUP BY key_code;
        """

        guard sqlite3_prepare_v2(db, bucketInsertSQL, -1, &keyBucketInsertStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, statsInsertSQL, -1, &bucketStatsInsertStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, totalSQL, -1, &totalStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, rangeSQL, -1, &rangeStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, keyFrequencySQL, -1, &keyFrequencyStatement, nil) == SQLITE_OK else {
            let error = currentErrorMessage()
            throw KeypressStoreError.initializationFailed("Unable to prepare database statements: \(error)")
        }
    }

    private func finalizeStatements() {
        if let statement = keyBucketInsertStatement {
            sqlite3_finalize(statement)
        }
        if let statement = bucketStatsInsertStatement {
            sqlite3_finalize(statement)
        }
        if let statement = totalStatement {
            sqlite3_finalize(statement)
        }
        if let statement = rangeStatement {
            sqlite3_finalize(statement)
        }
        if let statement = keyFrequencyStatement {
            sqlite3_finalize(statement)
        }
    }

    private func totalCountLocked() -> Int {
        guard let statement = totalStatement else { return 0 }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, userId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sumBetween(start: Date, end: Date) -> Int {
        guard let statement = rangeStatement else { return 0 }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 3, Int64(end.timeIntervalSince1970))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    func fetchKeyFrequencies(in interval: DateInterval) -> [KeyFrequency] {
        return queue.sync {
            flushCurrentBucketLocked()
            return queryKeyFrequencies(
                start: Int64(interval.start.timeIntervalSince1970),
                end: Int64(interval.end.timeIntervalSince1970)
            )
        }
    }

    func totalCount(in interval: DateInterval) -> Int {
        return queue.sync {
            flushCurrentBucketLocked()
            return sumBetween(start: interval.start, end: interval.end)
        }
    }

    private func queryKeyFrequencies(start: Int64, end: Int64) -> [KeyFrequency] {
        guard let statement = keyFrequencyStatement else { return [] }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, start)
        sqlite3_bind_int64(statement, 3, end)

        var frequencies: [KeyFrequency] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyPointer)
            let count = Int(sqlite3_column_int64(statement, 1))
            frequencies.append(KeyFrequency(key: key, count: count))
        }
        return sortKeyFrequencies(frequencies)
    }

    private func sortKeyFrequencies(_ frequencies: [KeyFrequency]) -> [KeyFrequency] {
        return frequencies.sorted { lhs, rhs in
            let left = keyOrderingComponents(for: lhs.key)
            let right = keyOrderingComponents(for: rhs.key)
            if left.category != right.category {
                return left.category < right.category
            }
            if left.label != right.label {
                return left.label < right.label
            }
            return lhs.key < rhs.key
        }
    }

    private func keyOrderingComponents(for key: String) -> (category: Int, label: String) {
        let label = normalizedKeyLabel(key)
        if label.count == 1, let scalar = label.unicodeScalars.first,
           (65...90).contains(Int(scalar.value)) {
            return (0, label)
        }
        return (1, label)
    }

    private func normalizedKeyLabel(_ key: String) -> String {
        if key.count == 1,
           let scalar = key.unicodeScalars.first,
           (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) {
            return key.uppercased()
        }
        return key
    }

    private func interval(for component: Calendar.Component, containing date: Date) -> DateInterval {
        if let interval = calendar.dateInterval(of: component, for: date) {
            return interval
        }

        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, duration: 24 * 60 * 60)
    }

    private func previousMonthInterval(relativeTo currentMonthStart: Date) -> DateInterval {
        let lastMonthEnd = currentMonthStart
        guard let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonthStart) else {
            return DateInterval(start: currentMonthStart, end: currentMonthStart)
        }
        return DateInterval(start: lastMonthStart, end: lastMonthEnd)
    }

    private func dayStartKey(for date: Date) -> Int64 {
        let start = calendar.startOfDay(for: date)
        return Int64(start.timeIntervalSince1970)
    }

    private func currentErrorMessage() -> String {
        guard let db = db, let errorPointer = sqlite3_errmsg(db) else {
            return "Unknown error"
        }
        return String(cString: errorPointer)
    }

    // MARK: - Statistics

    func fetchStatistics(maxKeyResults: Int = 10, idleThresholdMinutes: Int = 5) -> KeypressStatistics {
        return queue.sync {
            flushCurrentBucketLocked()
            let now = Date()
            let todayInterval = interval(for: .day, containing: now)
            let todayKey = Int64(todayInterval.start.timeIntervalSince1970)
            let last7Start = calendar.date(byAdding: .day, value: -6, to: todayInterval.start) ?? todayInterval.start
            let last30Start = calendar.date(byAdding: .day, value: -29, to: todayInterval.start) ?? todayInterval.start
            let thisMonthInterval = interval(for: .month, containing: now)
            let lastMonthInterval = previousMonthInterval(relativeTo: thisMonthInterval.start)
            let thisYearInterval = interval(for: .year, containing: now)

            let todayTotal = sumBetween(start: todayInterval.start, end: todayInterval.end)
            let last7Total = sumBetween(start: last7Start, end: todayInterval.end)
            let last30Total = sumBetween(start: last30Start, end: todayInterval.end)
            let thisMonthTotal = sumBetween(start: thisMonthInterval.start, end: thisMonthInterval.end)
            let lastMonthTotal = sumBetween(start: lastMonthInterval.start, end: lastMonthInterval.end)
            let thisYearTotal = sumBetween(start: thisYearInterval.start, end: thisYearInterval.end)
            let lifetimeTotal = totalCountLocked()

            let average7 = Double(last7Total) / 7.0
            let average30 = Double(last30Total) / 30.0

            let maxDaily = fetchDailyRecord(sql: """
                SELECT CAST(strftime('%s', datetime(bucket_start, 'unixepoch', 'start of day')) AS INTEGER) AS day,
                       SUM(total_keys) AS count
                FROM bucket_stats
                WHERE user_id = ?1
                GROUP BY day
                ORDER BY count DESC
                LIMIT 1;
                """)

            let minDaily = fetchDailyRecord(sql: """
                SELECT CAST(strftime('%s', datetime(bucket_start, 'unixepoch', 'start of day')) AS INTEGER) AS day,
                       SUM(total_keys) AS count
                FROM bucket_stats
                WHERE user_id = ?1
                GROUP BY day
                HAVING SUM(total_keys) > 0
                ORDER BY count ASC
                LIMIT 1;
                """)

            let dayEntries = fetchPositiveDayEntries()
            let streaks = computeStreaks(entries: dayEntries, todayKey: todayKey)

            let hourlyTotals = fetchHourlyTotals()
            let hourlyExtremes = resolveHourlyExtremes(from: hourlyTotals)

            let topKeysToday = fetchTopKeysForDay(dayKey: todayKey, limit: maxKeyResults)
            let topKeysAllTime = fetchTopKeysAllTime(limit: maxKeyResults)

            let minutes = fetchMinuteActivity(forDay: todayKey)
            let focusMetrics = computeFocusMetrics(
                minutes: minutes,
                dayInterval: todayInterval,
                now: now,
                idleThreshold: TimeInterval(idleThresholdMinutes * 60)
            )

            return KeypressStatistics(
                todayTotal: todayTotal,
                last7DaysTotal: last7Total,
                last30DaysTotal: last30Total,
                thisMonthTotal: thisMonthTotal,
                lastMonthTotal: lastMonthTotal,
                thisYearTotal: thisYearTotal,
                lifetimeTotal: lifetimeTotal,
                averageLast7Days: average7,
                averageLast30Days: average30,
                maximumDailyRecord: maxDaily,
                minimumDailyRecord: minDaily,
                currentActiveStreak: streaks.current,
                longestActiveStreak: streaks.longest,
                mostActiveHour: hourlyExtremes.most,
                leastActiveHour: hourlyExtremes.least,
                topKeysToday: topKeysToday,
                topKeysAllTime: topKeysAllTime,
                activeMinutesToday: focusMetrics.activeMinutes,
                longestFocusedPeriodMinutes: focusMetrics.longestFocus,
                longestIdlePeriodTodayMinutes: focusMetrics.longestIdle
            )
        }
    }

    private func fetchDailyRecord(sql: String) -> DailyActivityRecord? {
        guard let db = db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, userId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let dayValue = sqlite3_column_int64(statement, 0)
        let countValue = sqlite3_column_int64(statement, 1)
        return DailyActivityRecord(
            date: Date(timeIntervalSince1970: TimeInterval(dayValue)),
            count: Int(countValue)
        )
    }

    private func fetchPositiveDayEntries() -> [(Int64, Int)] {
        guard let db = db else { return [] }
        var statement: OpaquePointer?
        let sql = """
        SELECT CAST(strftime('%s', datetime(bucket_start, 'unixepoch', 'start of day')) AS INTEGER) AS day,
               SUM(total_keys) AS count
        FROM bucket_stats
        WHERE user_id = ?1
        GROUP BY day
        HAVING SUM(total_keys) > 0
        ORDER BY day ASC;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, userId)

        var entries: [(Int64, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dayKey = sqlite3_column_int64(statement, 0)
            let count = Int(sqlite3_column_int64(statement, 1))
            entries.append((dayKey, count))
        }
        return entries
    }

    private func computeStreaks(entries: [(Int64, Int)], todayKey: Int64) -> (current: KeypressStreak?, longest: KeypressStreak?) {
        guard !entries.isEmpty else { return (nil, nil) }
        let dayIntervalSeconds: Int64 = 24 * 60 * 60

        var longestLength = 0
        var longestEndDay: Int64 = 0
        var currentLength = 0
        var previousDay: Int64?

        for (dayKey, _) in entries {
            if let previous = previousDay, dayKey - previous == dayIntervalSeconds {
                currentLength += 1
            } else {
                currentLength = 1
            }

            if currentLength > longestLength {
                longestLength = currentLength
                longestEndDay = dayKey
            }

            previousDay = dayKey
        }

        var currentStreak: KeypressStreak?
        if let lastEntry = entries.last, lastEntry.0 == todayKey {
            var streakLength = 0
            var expectedDay = todayKey
            for (dayKey, _) in entries.reversed() {
                if dayKey == expectedDay {
                    streakLength += 1
                    expectedDay -= dayIntervalSeconds
                } else if dayKey < expectedDay {
                    break
                }
            }
            if streakLength > 0 {
                currentStreak = KeypressStreak(
                    lengthInDays: streakLength,
                    endDate: Date(timeIntervalSince1970: TimeInterval(todayKey))
                )
            }
        }

        var longestStreak: KeypressStreak?
        if longestLength > 0 {
            longestStreak = KeypressStreak(
                lengthInDays: longestLength,
                endDate: Date(timeIntervalSince1970: TimeInterval(longestEndDay))
            )
        }

        return (currentStreak, longestStreak)
    }

    private func fetchHourlyTotals() -> [Int: Int] {
        guard let db = db else { return [:] }
        var statement: OpaquePointer?
        let sql = """
        SELECT CAST(strftime('%H', datetime(bucket_start, 'unixepoch')) AS INTEGER) AS hour,
               SUM(total_keys) as total
        FROM bucket_stats
        WHERE user_id = ?1
        GROUP BY hour;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, userId)

        var totals: [Int: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let hour = Int(sqlite3_column_int(statement, 0))
            let count = Int(sqlite3_column_int64(statement, 1))
            totals[hour] = count
        }
        return totals
    }

    private func resolveHourlyExtremes(from totals: [Int: Int]) -> (most: HourlyActivityRecord?, least: HourlyActivityRecord?) {
        guard !totals.isEmpty else { return (nil, nil) }
        var filledTotals: [Int: Int] = [:]

        for hour in 0..<24 {
            filledTotals[hour] = totals[hour] ?? 0
        }

        let most = filledTotals.max { lhs, rhs in lhs.value < rhs.value }
        let least = filledTotals.min { lhs, rhs in lhs.value < rhs.value }

        let mostRecord = most.map { HourlyActivityRecord(hour: $0.key, count: $0.value) }
        let leastRecord = least.map { HourlyActivityRecord(hour: $0.key, count: $0.value) }

        return (mostRecord, leastRecord)
    }

    private func fetchTopKeysForDay(dayKey: Int64, limit: Int) -> [KeyFrequency] {
        guard let db = db else { return [] }
        var statement: OpaquePointer?
        let sql = """
        SELECT key_code, SUM(press_count) AS count
        FROM key_buckets
        WHERE user_id = ?1 AND bucket_start >= ?2 AND bucket_start < ?3
        GROUP BY key_code
        ORDER BY count DESC
        LIMIT ?4;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let dayEnd = dayKey + Int64(24 * 60 * 60)
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, dayKey)
        sqlite3_bind_int64(statement, 3, dayEnd)
        sqlite3_bind_int(statement, 4, Int32(limit))

        var frequencies: [KeyFrequency] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let keyCString = sqlite3_column_text(statement, 0) {
                let key = String(cString: keyCString)
                let count = Int(sqlite3_column_int64(statement, 1))
                frequencies.append(KeyFrequency(key: key, count: count))
            }
        }
        return frequencies
    }

    private func fetchTopKeysAllTime(limit: Int) -> [KeyFrequency] {
        guard let db = db else { return [] }
        var statement: OpaquePointer?
        let sql = """
        SELECT key_code, SUM(press_count) AS count
        FROM key_buckets
        WHERE user_id = ?1
        GROUP BY key_code
        ORDER BY count DESC
        LIMIT ?2;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frequencies: [KeyFrequency] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let keyCString = sqlite3_column_text(statement, 0) {
                let key = String(cString: keyCString)
                let count = Int(sqlite3_column_int64(statement, 1))
                frequencies.append(KeyFrequency(key: key, count: count))
            }
        }
        return frequencies
    }

    private func fetchMinuteActivity(forDay dayKey: Int64) -> [Int64] {
        guard let db = db else { return [] }
        var statement: OpaquePointer?
        let sql = """
        SELECT DISTINCT bucket_start AS minute
        FROM bucket_stats
        WHERE user_id = ?1 AND bucket_start >= ?2 AND bucket_start < ?3
        ORDER BY minute ASC;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let dayEnd = dayKey + Int64(24 * 60 * 60)
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, dayKey)
        sqlite3_bind_int64(statement, 3, dayEnd)

        var minutes: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let minute = sqlite3_column_int64(statement, 0)
            minutes.append(minute)
        }
        return minutes
    }

    private func computeFocusMetrics(minutes: [Int64], dayInterval: DateInterval, now: Date, idleThreshold: TimeInterval) -> (activeMinutes: Int, longestFocus: Int, longestIdle: Int) {
        guard !minutes.isEmpty else {
            let idleDuration = Int(now.timeIntervalSince(dayInterval.start) / 60)
            return (0, 0, max(idleDuration, 0))
        }

        let activeMinutes = minutes.count

        var longestFocus = 1
        var blockStart = minutes.first!
        var blockEnd = blockStart

        for minute in minutes.dropFirst() {
            let gap = Double(minute - blockEnd)
            if gap <= idleThreshold {
                blockEnd = minute
            } else {
                let duration = Int((blockEnd - blockStart) / 60) + 1
                longestFocus = max(longestFocus, duration)
                blockStart = minute
                blockEnd = minute
            }
        }
        let finalDuration = Int((blockEnd - blockStart) / 60) + 1
        longestFocus = max(longestFocus, finalDuration)

        var longestIdle = max(
            0,
            Int((TimeInterval(minutes.first!) - dayInterval.start.timeIntervalSince1970) / 60)
        )

        var previousMinute = minutes.first!
        for minute in minutes.dropFirst() {
            let idleGapSeconds = TimeInterval(minute - previousMinute) - 60
            if idleGapSeconds > 0 {
                let idleGap = Int(idleGapSeconds / 60)
                longestIdle = max(longestIdle, idleGap)
            }
            previousMinute = minute
        }

        let idleAfterLastSeconds = now.timeIntervalSince1970 - (TimeInterval(previousMinute) + 60)
        if idleAfterLastSeconds > 0 {
            let idleAfterLast = Int(idleAfterLastSeconds / 60)
            longestIdle = max(longestIdle, idleAfterLast)
        }

        return (activeMinutes, longestFocus, longestIdle)
    }
}

// CGEvent tap callback – increments the global counter
let keyTapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    totalCount += 1
    let timestamp = Date()
    let keyString: String
    if let nsEvent = NSEvent(cgEvent: event) {
        if let readable = KeyNameResolver.readableName(for: nsEvent) {
            keyString = readable
        } else if let characters = nsEvent.charactersIgnoringModifiers,
                  !characters.isEmpty {
            keyString = characters
        } else {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            keyString = "KeyCode \(keyCode)"
        }
    } else {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        keyString = "KeyCode \(keyCode)"
    }

    keypressStore?.recordKeypress(at: timestamp, key: keyString)
    return Unmanaged.passUnretained(event)
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    private var statsWindowController: StatsWindowController?
    private let presetDefaultsKey = "KeydometerSelectedTimeRange"
    private var selectedPreset: TimeRangePreset

    override init() {
        if let stored = UserDefaults.standard.string(forKey: presetDefaultsKey),
           let preset = TimeRangePreset.fromStorageKey(stored) {
            selectedPreset = preset
        } else {
            selectedPreset = TimeRangePreset.defaultPreset
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try setupPersistence()
        } catch {
            presentStartupError(message: error.localizedDescription)
            return
        }

        setupStatusItem()
        setupEventTap()
        setupTimer()
        updateStatus()
    }

    private func setupStatusItem() {
        // Create a variable length status item (menu bar item)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "⌨︎ 0"
            button.toolTip = "Keydometer – total key presses"
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Show Stats",
            action: #selector(showStatsWindowFromMenu),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Quit Keydometer",
            action: #selector(quitFromMenu),
            keyEquivalent: ""
        )
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func showStatsWindowFromMenu() {
        toggleStatsWindow()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func persistSelectedPreset() {
        UserDefaults.standard.set(selectedPreset.storageKey, forKey: presetDefaultsKey)
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyTapCallback,
            userInfo: nil
        ) else {
            let alert = NSAlert()
            alert.messageText = "Keydometer"
            alert.informativeText = "Failed to create event tap. Check Input Monitoring permissions in System Settings."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func setupTimer() {
        // Update UI every 0.5s from the main run loop
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    @objc private func toggleStatsWindow() {
        let controller = ensureStatsWindowController()
        controller.synchronizeSelectedPreset(selectedPreset)
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.refreshData()
    }

    private func ensureStatsWindowController() -> StatsWindowController {
        if let controller = statsWindowController {
            if let store = keypressStore {
                controller.setStore(store)
            }
            controller.delegate = self
            controller.synchronizeSelectedPreset(selectedPreset)
            return controller
        }
        let controller = StatsWindowController(store: keypressStore, initialPreset: selectedPreset, delegate: self)
        statsWindowController = controller
        return controller
    }

    private func updateStatus() {
        let stats = keypressStore?.fetchStatistics()
        let interval = selectedPreset.interval()
        let rangeTotal = keypressStore?.totalCount(in: interval) ?? 0

        if let button = statusItem.button {
            button.title = "⌨︎ \(rangeTotal)"
            if let stats = stats {
                let lines = [
                    "Keydometer",
                    "\(selectedPreset.title): \(rangeTotal)",
                    "Today: \(stats.todayTotal)",
                    "Last 7 Days: \(stats.last7DaysTotal)",
                    "This Year: \(stats.thisYearTotal)",
                    "Lifetime: \(stats.lifetimeTotal)"
                ]
                button.toolTip = lines.joined(separator: "\n")
            } else {
                button.toolTip = "Keydometer – total key presses: \(totalCount)"
            }
        }

        if let menu = statusItem.menu,
           let firstItem = menu.items.first {
            firstItem.title = "Show Stats (\(selectedPreset.title))"
        }

        statsWindowController?.refreshVisibleContent()
    }

    private func setupPersistence() throws {
        let store = try KeypressStore()
        keypressStore = store
        totalCount = store.loadTotalCount()
        statsWindowController?.setStore(store)
    }

    private func presentStartupError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Keydometer"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        keypressStore?.flushPendingData()
    }
}

extension AppDelegate: StatsWindowControllerDelegate {
    func statsWindowController(_ controller: StatsWindowController, didSelect preset: TimeRangePreset) {
        guard preset != selectedPreset else { return }
        selectedPreset = preset
        persistSelectedPreset()
        updateStatus()
    }
}

// MARK: - Main entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu bar-only style: no Dock icon, no app in Cmd+Tab
app.setActivationPolicy(.accessory)

app.run()
