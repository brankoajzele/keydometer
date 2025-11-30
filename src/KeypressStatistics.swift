import Foundation

/// View model containing computed statistics for presenting keyboard usage.
struct KeypressStatistics {
    /// Number of keypresses recorded so far today.
    let todayTotal: Int

    /// Total keypresses for the trailing 7-day window ending today.
    let last7DaysTotal: Int

    /// Total keypresses for the trailing 30-day window ending today.
    let last30DaysTotal: Int

    /// Total keypresses within the current calendar month.
    let thisMonthTotal: Int

    /// Total keypresses within the previous calendar month.
    let lastMonthTotal: Int

    /// Total keypresses within the current calendar year.
    let thisYearTotal: Int

    /// Total keypresses ever recorded by the application.
    let lifetimeTotal: Int

    /// Average daily keypresses calculated over the trailing 7-day window.
    let averageLast7Days: Double

    /// Average daily keypresses calculated over the trailing 30-day window.
    let averageLast30Days: Double

    /// Day with the highest number of keypresses and its count.
    let maximumDailyRecord: DailyActivityRecord?

    /// Day with the lowest non-zero keypress count and its value, if available.
    let minimumDailyRecord: DailyActivityRecord?

    /// Current streak of consecutive days with at least one keypress.
    let currentActiveStreak: KeypressStreak?

    /// Longest recorded streak of consecutive days with at least one keypress.
    let longestActiveStreak: KeypressStreak?

    /// Historical hour-of-day that saw the most keypresses.
    let mostActiveHour: HourlyActivityRecord?

    /// Historical hour-of-day that saw the fewest (non-zero) keypresses.
    let leastActiveHour: HourlyActivityRecord?

    /// Ranked key frequencies for the current day (e.g., top 10 keys).
    let topKeysToday: [KeyFrequency]

    /// Ranked key frequencies for all recorded time.
    let topKeysAllTime: [KeyFrequency]

    /// Number of distinct minutes today that had at least one keypress.
    let activeMinutesToday: Int

    /// Longest continuous focus period today without breaks longer than the configured idle threshold.
    let longestFocusedPeriodMinutes: Int

    /// Longest idle period today where no keypresses occurred.
    let longestIdlePeriodTodayMinutes: Int
}
