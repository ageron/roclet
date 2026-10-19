# Roclet rich output values. Strings preserve exact numeric text at the host boundary.
Display :: { version : U64, kind : Str, text : Str, content : Str, mime : Str, columns : List(Str), rows : List(List(Str)), row_count : U64, column_count : U64 }.{
    clip = |source, limit| if List.len(Str.to_utf8(source)) > limit {
        "${Str.from_utf8_lossy(List.take_first(Str.to_utf8(source), limit))}…"
    } else { source }

    text = |source| Display.({ version: 1, kind: "text", text: clip(source, 16384), content: "", mime: "", columns: [], rows: [], row_count: 0, column_count: 0 })
    markdown = |source| Display.({ version: 1, kind: "markdown", text: clip(source, 16384), content: clip(source, 16384), mime: "", columns: [], rows: [], row_count: 0, column_count: 0 })
    image = |alt, mime, base64| if List.len(Str.to_utf8(base64)) > 131072 {
        text("${clip(alt, 16000)}\nImage preview omitted: encoded images are limited to 128 KiB.")
    } else {
        Display.({ version: 1, kind: "image", text: clip(alt, 16384), content: base64, mime, columns: [], rows: [], row_count: 0, column_count: 0 })
    }

    # Up to 200 rows and 16 columns; each preview cell is bounded to 128 UTF-8 bytes.
    # Convert numbers with Str.inspect: JavaScript never rounds them through Number.
    table = |columns, rows| {
        preview_columns = List.map(List.take_first(columns, 16), |v| clip(v, 128))
        var $preview_rows = []
        var $bytes = 0
        var $full = False
        for row in List.take_first(rows, 200) {
            if !$full {
                candidate = List.map(List.take_first(row, 16), |v| clip(v, 128))
                size = List.len(Str.to_utf8(Str.join_with(candidate, "")))
                if $bytes + size <= 8192 {
                    $preview_rows = List.append($preview_rows, candidate)
                    $bytes = $bytes + size
                } else {
                    $full = True
                }
            }
        }
        preview_rows = $preview_rows
        heading = Str.join_with(preview_columns, " | ")
        lines = List.map(preview_rows, |row| Str.join_with(row, " | "))
        summary = "${List.len(rows).to_str()} rows × ${List.len(columns).to_str()} columns"
        Display.({ version: 1, kind: "table", text: clip("${summary}\n${heading}\n${Str.join_with(lines, "\n")}", 16384), content: "", mime: "", columns: preview_columns, rows: preview_rows, row_count: List.len(rows), column_count: List.len(columns) })
    }
    to_inspect : Display -> Str
    to_inspect = |Display.(value)| value.text
    to_wire = |Display.(value)| Json.to_str({ ..value, text: "" })
}
