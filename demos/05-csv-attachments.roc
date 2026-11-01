app [main!] {
    roclet: "https://github.com/ageron/roclet/releases/download/0.2.0/C8vdeSE1ABoSei4Lepuy9Dy7t7GAJQt42WQkWw9bhcFc.tar.zst",
    parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/2.0.0/7CLzCK6qUz7zmj6nvBxMEFu11HPwQTnCovKiyWzDSLTW.tar.zst",
}

import roclet.Display
import parser.CSV

# %%
# # A café sales report from a CSV attachment
#
# This notebook reads a small sample sales file, decodes its rows with **roc-parser**,
# and calculates revenue using exact integer cents. The comma in "Tea, Earl Grey"
# and the accent in "Café mocha" are part of the data.
#
# Open **File → Attachments** to preview `data/cafe-sales.csv` or download its original
# bytes. Choose **Replace file…** to try your own CSV with the same columns. The
# path stays the same, and dependent results update when Auto-run is enabled.
#
# On first use, Roclet may ask you to download and load the parser package and its
# Unicode dependency. Verified packages are cached for subsequent offline runs.

# %%
# ## Read the attached UTF-8 text
#
# The file is a saved copy belonging to this notebook. Changing the original on
# your computer does not change this copy.

# %%
import "data/cafe-sales.csv" as csv_text : Str
out_source = Display.text(csv_text)

# %%
# ## Decode rows by their column names
#
# The type annotation tells roc-parser which columns and value types to expect.
# Invalid data produces an error value that we can show alongside the report.

# %%
Sale : { item : Str, units : U64, unit_price_cents : U64 }
decode_sales : Str -> Try(List(Sale), [InvalidCsv(CSV.Error), MissingRequiredField(Str)])
decode_sales = |input| CSV.parse(input)
sales = decode_sales(csv_text)
out_rows = match sales {
    Ok(rows) => Display.table(["Item", "Units", "Price (cents)"], rows.map(|row| [row.item, row.units.to_str(), row.unit_price_cents.to_str()]))
    Err(error) => Display.text("Could not decode the CSV: ${Str.inspect(error)}")
}

# %%
# ## Calculate the total
#
# Try replacing the attachment with a file that changes the quantity of one item.
# Then try a non-numeric quantity to see the decoding error. Use **Undo** to restore
# the previous attachment and its results.

# %%
revenue = sales.map_ok(|rows| rows.map(|row| row.units * row.unit_price_cents).sum())
out_revenue = match revenue {
    Ok(cents) => Display.markdown("Total sales revenue: **${cents.to_str()} cents**.")
    Err(error) => Display.text("Revenue is unavailable: ${Str.inspect(error)}")
}

# %%
# ## The same attachment as raw bytes
#
# Binary file imports also work for images and other formats. No text conversion
# is applied to a `List(U8)` import.

# %%
import "data/cafe-sales.csv" as csv_bytes : List(U8)
out_byte_count = List.len(csv_bytes)

# %%
# ## Keep the notebook and its data together
#
# Choose **File → Export & share → Roclet bundle**. Open that bundle in a compatible
# Roclet installation to recover the same file paths and exact bytes. A source-only
# `.roc` or `.md` download does not include attachments.

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_source)
    display!(out_rows)
    display!(out_revenue)
    display!(out_byte_count)
    Ok({})
}
