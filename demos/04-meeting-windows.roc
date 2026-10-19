app [] {
    time: "https://github.com/lukewilliamboswell/roc-time/releases/download/0.2.0/roc-time-7QH5VBiCwDLu3UkizpgB3FESJitahxR82Vgg2bWkJvHL.tar.zst",
}
import Display
import time.ExactInterval
import time.OffsetTimestamp
import time.EnglishGregorian
import time.ClockTime
import time.FixedOffset
import time.PosixBoundary
import time.PosixDelta
import time.PosixSpan
import time.Coverage

# %%
# # Finding room for a design review
# We need **45 uninterrupted minutes** in the shared project calendar on
# **15 June 2026**. The planning window is 09:00–17:00 UTC, but calendar entries
# arrive with different offsets. Some bookings overlap.
#
# I will normalize the timestamps, merge occupied time, subtract it from the
# planning window, and keep gaps long enough for the review. The earliest
# qualifying gap will give us a concrete recommendation.

# %%
meeting_minutes = 45
working_day = "2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"

# %%
# ## 1. Inspect the calendar entries
# This small calendar extract contains four bookings. Keep their supplied
# offsets for now: comparing the written clock times would give the wrong order.
# The planning window above is our availability constraint.

# %%
bookings = [
    {
        meeting: "Roadmap review",
        start: "2026-06-15T12:00:00+02:00",
        end: "2026-06-15T14:00:00+02:00",
    },
    {
        meeting: "Design handoff",
        start: "2026-06-15T12:30:00+01:00",
        end: "2026-06-15T13:30:00+01:00",
    },
    {
        meeting: "Daily check-in",
        start: "2026-06-15T14:00:00Z",
        end: "2026-06-15T14:30:00Z",
    },
    {
        meeting: "Customer interview",
        start: "2026-06-15T11:00:00-04:00",
        end: "2026-06-15T12:00:00-04:00",
    },
]
out_calendar = table_or_error(
    ["Meeting", "Start as supplied", "End as supplied"],
    calendar_rows(bookings),
)

# %%
# ## 2. Put every booking on the same timeline
# Parse each pair of endpoints and project it onto an absolute span. Rendering
# those spans in UTC makes the overlap visible: the roadmap review and design
# handoff share **11:30–12:00 UTC**.
#
# Invalid dates and reversed endpoints are errors, rather than rows to silently
# drop. The small `describe_span` helper below formats a checked span for our tables.
# `EnglishGregorian` provides readable dates and clocks; the column headings
# state UTC explicitly after normalization.

# %%
normalize_bookings = |entries| {
    var $normalized = []
    for booking in entries {
        interval = ExactInterval.parse("${booking.start}/${booking.end}")
            .map_err(|error| "${booking.meeting}: ${Str.inspect(error)}")?
        window = describe_span(ExactInterval.span(interval))?
        $normalized = $normalized.append({ meeting: booking.meeting, window })
    }
    Ok($normalized)
}
normalized_bookings = normalize_bookings(bookings)
out_normalized = table_or_error(
    ["Meeting", "Start (UTC)", "End (UTC)"],
    normalized_bookings.map_ok(|rows| rows.map(|row| [row.meeting, row.window.start_utc, row.window.end_utc])),
)

# %%
# ## 3. Merge occupied time before measuring it
# Adding the booking durations would count the shared half hour twice.
# `Coverage.from_spans` sorts the spans and coalesces overlaps and touching
# endpoints. For the supplied data, four bookings become **three busy blocks**;
# the first covers 10:00–12:30 UTC.

# %%
merge_bookings = |result| {
    rows = result?
    coverage = Coverage.from_spans(rows.map(|row| row.window.span))
    describe_spans(Coverage.to_spans(coverage))
}
busy_windows = merge_bookings(normalized_bookings)
out_busy = show_windows(busy_windows)

# %%
# ## 4. Subtract the busy blocks from the planning window
# Work with half-open intervals: a booking includes its start but excludes its
# end. A review can therefore start exactly when a previous booking ends.
# The complement is clipped to the planning window, so an off-hours booking
# cannot create an off-hours suggestion.

# %%
find_free_windows = |busy_result, day_text| {
    busy = busy_result?
    day = ExactInterval.parse(day_text).map_err(|error| "Planning window: ${Str.inspect(error)}")?
    occupied = Coverage.from_spans(busy.map(|window| window.span))
    free = Coverage.complement_within(occupied, ExactInterval.span(day))
    describe_spans(Coverage.to_spans(free))
}
free_windows = find_free_windows(busy_windows, working_day)
out_free = show_windows(free_windows)

# %%
# ## 5. Keep only gaps long enough for the review
# Being free is not sufficient: **14:30–15:00 UTC is only 30 minutes**.
# Keep a gap only when its full duration meets the requested meeting length.
# The table reports whole minutes; these calendar entries all have minute precision.

# %%
eligible_windows = |result, minimum| {
    if minimum <= 0 { return Err("Meeting length must be positive.") }
    windows = result?
    Ok(windows.keep_if(|window| window.minutes >= minimum))
}
candidate_windows = eligible_windows(free_windows, meeting_minutes)
out_candidates = show_windows(candidate_windows)

# %%
# ## 6. Turn the first candidate into a booking
# The gaps are in chronological order. Reserve only the requested duration at
# the start of the first one, leaving the rest of that gap available.

# %%
recommend_meeting = |result, minutes| {
    windows = result?
    match windows.first() {
        Err(_) => Ok("**No suitable opening.** Shorten the review or widen the planning window.")
        Ok(window) => {
            start = PosixSpan.start(window.span)
            end = PosixBoundary.shift(start, PosixDelta.from_microseconds(minutes * 60000000))
                .map_err(|error| Str.inspect(error))?
            meeting = PosixSpan.new(start, end).map_err(|error| Str.inspect(error))?
            chosen = describe_span(meeting)?
            Ok("**Book ${chosen.label}.**\n\nThis gives us ${minutes.to_str()} uninterrupted minutes. Qualifying gaps: **${windows.len().to_str()}**.")
        }
    }
}
out_recommendation = markdown_or_error(recommend_meeting(candidate_windows, meeting_minutes))

# %%
# ## What changes the answer?
# - Change `meeting_minutes` from **45 to 90**. Only the 12:30–14:00 gap remains.
# - Move the roadmap review's start from **12:00+02:00 to 11:00+02:00**.
#   It now starts at 09:00 UTC, removing the first candidate.
# - Move the customer interview outside the planning window. Its occupied time
#   should stop reducing the available part of the day.
#
# This is a calculation from one calendar extract, rather than a live booking.
# Recheck the calendar before sending an invitation.

# %%
# ## Appendix: duration and display helpers
# These helpers keep the intermediate tables readable. Durations come from the
# checked span's microsecond width; each minute is 60,000,000 microseconds.
# All parsing or range errors travel to the relevant output as readable text.
# roc-time's `EnglishGregorian.date` and `.clock` handle presentation. Whole-minute
# clocks use `Minute`; clocks with seconds or fractions retain their exact value.

# %%
describe_span = |span| {
    interval = ExactInterval.from_span(span, UnassertedUtc, 6).map_err(|error| Str.inspect(error))?
    endpoints = ExactInterval.endpoints(interval)
    width = PosixSpan.coordinate_width(span).map_err(|error| Str.inspect(error))?
    start = OffsetTimestamp.parts(endpoints.start)
    end = OffsetTimestamp.parts(endpoints.end)
    start_utc = readable_timestamp(endpoints.start)
    end_utc = readable_timestamp(endpoints.end)
    label = if start.date == end.date {
        "${EnglishGregorian.date(start.date)}, ${readable_clock(start.clock)}–${readable_clock(end.clock)} UTC"
    } else {
        "${start_utc} – ${end_utc} UTC"
    }
    Ok({
        span,
        start_utc,
        end_utc,
        label,
        minutes: I64.div_trunc_by(PosixDelta.to_microseconds(width), 60000000),
    })
}
describe_spans = |spans| {
    var $windows = []
    for span in spans { $windows = $windows.append(describe_span(span)?) }
    Ok($windows)
}

# %%
readable_clock = |clock| match EnglishGregorian.clock(clock, Minute) {
    Ok(text) => text
    Err(_) => ClockTime.to_text(clock)
}
readable_timestamp = |timestamp| {
    parts = OffsetTimestamp.parts(timestamp)
    "${EnglishGregorian.date(parts.date)}, ${readable_clock(parts.clock)}"
}
readable_offset = |offset| match offset {
    UnassertedUtc => Ok("UTC")
    Asserted(fixed) => {
        seconds = FixedOffset.to_seconds(fixed).to_i64()
        sign = if seconds < 0 { "-" } else { "+" }
        magnitude = if seconds < 0 { -seconds } else { seconds }
        clock = ClockTime.from_microseconds_since_midnight(magnitude * 1000000)
            .map_err(|error| Str.inspect(error))?
        Ok("UTC${sign}${readable_clock(clock)}")
    }
}
readable_supplied = |text| {
    timestamp = OffsetTimestamp.parse(text).map_err(|error| Str.inspect(error))?
    offset = readable_offset(OffsetTimestamp.parts(timestamp).offset)?
    Ok("${readable_timestamp(timestamp)} ${offset}")
}
calendar_rows = |entries| {
    var $rows = []
    for booking in entries {
        start = readable_supplied(booking.start).map_err(|error| "${booking.meeting}: ${error}")?
        end = readable_supplied(booking.end).map_err(|error| "${booking.meeting}: ${error}")?
        $rows = $rows.append([booking.meeting, start, end])
    }
    Ok($rows)
}

# %%
table_or_error = |columns, result| match result {
    Ok(rows) => Display.table(columns, rows)
    Err(message) => Display.text("Check the calendar: ${message}")
}
show_windows = |result| table_or_error(
    ["Start (UTC)", "End (UTC)", "Minutes"],
    result.map_ok(|windows| windows.map(|window| [window.start_utc, window.end_utc, window.minutes.to_str()])),
)
markdown_or_error = |result| match result {
    Ok(text) => Display.markdown(text)
    Err(message) => Display.text("Check the calendar: ${message}")
}
