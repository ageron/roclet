app [] {
    time: "https://github.com/lukewilliamboswell/roc-time/releases/download/0.2.0/roc-time-7QH5VBiCwDLu3UkizpgB3FESJitahxR82Vgg2bWkJvHL.tar.zst",
}
import Display
import time.ExactInterval
import time.Coverage

# %%
# # Find a free meeting slot
# Two bookings, different UTC offsets, one shared calendar.
# Edit the opening window or either booking. The table recomputes in UTC.

# %%
opening = "2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"

# %%
bookings = [
    "2026-06-15T12:00:00+02:00/2026-06-15T14:00:00+02:00",
    "2026-06-15T15:00:00Z/2026-06-15T16:00:00Z",
]

# %%
availability = available(opening, bookings)
out_windows = match availability {
    Ok(rows) => Display.table(["Available interval (UTC)"], rows)
    Err(error) => Display.text("Check your dates: ${Str.inspect(error)}")
}

# %%
out_count = availability.map_ok(|rows| rows.len())

# %%
# The first booking is 10:00–12:00 UTC, because its written offset is +02:00.
# Bookings include their start and exclude their end, so a meeting can start
# exactly when another finishes. Change 12:00+02:00 to 11:00+02:00 to remove
# the first free slot. An invalid or reversed interval gives an explicit error.

# %%
available = |opening_text, booking_texts| {
    window = parse_interval(opening_text)?
    var $occupied = []
    for text in booking_texts {
        $occupied = $occupied.append(ExactInterval.span(parse_interval(text)?))
    }
    free = Coverage.complement_within(Coverage.from_spans($occupied), ExactInterval.span(window))
    var $rows = []
    for span in free {
        interval = match ExactInterval.from_span(span, UnassertedUtc, 0) {
            Ok(value) => value
            Err(error) => return Err(Output(error))
        }
        $rows = $rows.append([ExactInterval.to_text(interval)])
    }
    Ok($rows)
}

parse_interval = |text| match ExactInterval.parse(text) {
    Ok(value) => Ok(value)
    Err(error) => Err(Input(error))
}
