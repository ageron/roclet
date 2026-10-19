# Pure notebook policy. Host facts are byte spans from Roc and Markdown parsers.
Document := [].{
    Span : { start : U64, end : U64 }
    Token : { start : U64, end : U64, depth : U64, tag : Str }
    Statement : { start : U64, end : U64, kind : Str, name : Str, body_start : U64, body_end : U64 }
    Facts : { tokens : List(Token), statements : List(Statement), errors : List(Span), header_end : U64 }
    Block : { start : U64, end : U64, body_start : U64, body_end : U64, kind : Str, info : Str, facts : Facts }
    Output : { kind : Str, source : Str }
    Diagnostic : { code : Str, message : Str, severity : Str, start : U64, end : U64, cell : U64 }
    SourceMap : { start : U64, end : U64, original_start : U64, original_end : U64 }
    Cell : { kind : Str, source : Str, attributes : Str, id : Str, output : Str, outputs : List(Output), start : U64, end : U64, body_start : U64, facts : Facts, marker_lines : List(U64), first_block : Block, blocks : List(Block), source_map : List(SourceMap) }
    Model : { format : Str, original : Str, preamble : Str, metadata : Str, cells : List(Cell), diagnostics : List(Diagnostic) }
    MetadataField : { key : Str, value : Str }
    DraftCell : { kind : Str, source : Str, attributes : Str, outputs : List(Output) }
    Draft : { supplied : Bool, preamble : Str, metadata : Str, cells : List(DraftCell) }
    ReactiveDefinition : { name : Str, fingerprint : Str, dependencies : List(Str) }
    ReactiveGraph : { context : Str, scope : Str, definitions : List(ReactiveDefinition) }
    ReactiveInput : { known : Bool, previous : ReactiveGraph, current : ReactiveGraph, available : List(Str), roots : List(Str), force : List(Str) }
    Plan : { changed : List(Str), evaluate : List(Str), reused : List(Str), explanations : List({ root : Str, reason : Str, dependencies : List(Str) }) }
    empty_plan : Plan
    empty_plan = { changed: [], evaluate: [], reused: [], explanations: [] }
    plan = |input| {
        current = input.current
        previous = input.previous
        names = List.fold(List.concat(List.map(current.definitions, |d| d.name), List.map(previous.definitions, |d| d.name)), [], |acc, name| if List.contains(acc, name) { acc } else { List.append(acc, name) })
        changed = List.keep_if(names, |name| {
            old = List.keep_if(previous.definitions, |d| d.name == name)
            new = List.keep_if(current.definitions, |d| d.name == name)
            old != new
        })
        global_change = !input.known or previous.context != current.context or previous.scope != current.scope or (current.scope == "module" and !List.is_empty(changed))
        explanations = List.map(input.roots, |root| {
            var $dependencies = [root]
            var $growing = True
            while $growing {
                next = List.fold(current.definitions, $dependencies, |acc, d| if List.contains(acc, d.name) { List.fold(d.dependencies, acc, |items, name| if List.contains(items, name) { items } else { List.append(items, name) }) } else { acc })
                $growing = List.len(next) > List.len($dependencies)
                $dependencies = next
            }
            causes = List.keep_if(changed, |name| List.contains($dependencies, name))
            reason = if global_change { "Document context changed or no checked baseline" } else if !List.is_empty(causes) { "Changed: ${Str.join_with(causes, ", ")}" } else if List.contains(input.force, root) { "Explicit run" } else if !List.contains(input.available, root) { "No successful result" } else { "Unchanged dependencies" }
            { root, reason, dependencies: $dependencies }
        })
        reused = List.map(List.keep_if(explanations, |item| item.reason == "Unchanged dependencies"), |item| item.root)
        { changed, reused, evaluate: List.keep_if(input.roots, |root| !List.contains(reused, root)), explanations }
    }
    Input : { reactivity : ReactiveInput, metadata_fields : List(MetadataField), phase : Str, format : Str, target : Str, source : Str, facts : Facts, blocks : List(Block), model : Model, draft : Draft }
    Result : { plan : Plan, status : Str, model : Model, draft : Draft, source : Str, program : Str, execution : Str, roots : List(Str), mappings : List({ generated_start : U64, generated_end : U64, source_start : U64, source_end : U64, cell : U64 }) }
    empty_facts : Facts
    empty_facts = { tokens: [], statements: [], errors: [], header_end: 0 }
    empty_model : Model
    empty_model = { format: "roc", original: "", preamble: "", metadata: "", cells: [], diagnostics: [] }
    indexed = |items| List.map_with_index(items, |item, index| (item, index))
    replace = |s, old, new| Str.join_with(Str.split_on(s, old), new)
    minimum = |a, b| if a < b { a } else { b }
    count = |s| Str.count_utf8_bytes(s)
    slice = |s, start, end| Str.from_utf8_lossy(List.take_first(List.drop_first(Str.to_utf8(s), start), end - start))
    trim = |s| Str.trim(s)
    strip_eol = |s| if Str.ends_with(s, "\r\n") { Str.drop_suffix(s, "\r\n") } else { Str.drop_suffix(s, "\n") }
    line_list = |s| {
        List.fold(Str.split_on(s, "\n"), { offset: 0.U64, lines: [] }, |state, line| {
            end = state.offset + count(line)
            { offset: end + 1, lines: List.append(state.lines, { start: state.offset, end, text: Str.drop_suffix(line, "\r") }) }
        }).lines
    }
    blank = |s| trim(s) == ""
    diagnostic = |code, message, start, end, cell| { code, message, severity: "error", start, end, cell }
    cell = |kind, source, attributes, start, end, body_start| { kind, source, attributes, id: "", output: "", outputs: [], start, end, body_start, facts: empty_facts, marker_lines: [], first_block: { start: 0, end: 0, body_start: 0, body_end: 0, kind: "", info: "", facts: empty_facts }, blocks: [], source_map: [{ start: 0, end: count(source), original_start: 0, original_end: count(source) }] }
    run : Input -> Result
    run = |input| if input.phase == "plan" {
        { plan: plan(input.reactivity), status: "ok", model: input.model, draft: input.draft, source: "", program: "", execution: "", roots: [], mappings: [] }
    } else if input.phase == "segment" {
        model = if input.draft.supplied { draft_model(input) } else { segment(input) }
        { plan: empty_plan, status: "ok", model, draft: input.draft, source: model.original, program: "", execution: "", roots: [], mappings: [] }
    } else { finish(input) }
    draft_model = |input| {
        cells = List.map(input.draft.cells, |draft| {
            c = cell(draft.kind, draft.source, draft.attributes, 0, count(draft.source), 0)
            { ..c, outputs: draft.outputs, id: id_attribute(draft.attributes) }
        })
        { ..empty_model, format: input.format, original: input.source, preamble: input.draft.preamble, metadata: input.draft.metadata, cells }
    }
    safe_comment = |facts, pos| {
        overlap = List.any(facts.tokens, |t| t.start <= pos and pos < t.end)
        before = List.keep_if(facts.tokens, |t| t.end <= pos)
        depth = match List.last(before) {
            Ok(t) => if List.contains(["OpenCurly", "OpenSquare", "OpenRound", "NoSpaceOpenRound", "StringStart", "MultilineStringStart", "OpenStringInterpolation"], t.tag) { t.depth + 1 } else if List.contains(["CloseCurly", "CloseSquare", "CloseRound", "StringEnd", "CloseStringInterpolation"], t.tag) { if t.depth > 0 { t.depth - 1 } else { 0 } } else { t.depth }
            Err(_) => 0
        }
        !overlap and depth == 0
    }
    words = |s| List.keep_if(Str.split_on(replace(s, "\t", " "), " "), |word| word != "")
    kind_attribute = |attrs| List.first(List.keep_if(words(attrs), |w| List.contains(["code", "markdown", "generated"], w))).ok_or("")
    id_attribute = |attrs| Str.drop_prefix(List.first(List.keep_if(words(attrs), |w| Str.starts_with(w, "id="))).ok_or(""), "id=")
    without_kind = |attrs| Str.join_with(List.keep_if(words(attrs), |w| !List.contains(["code", "markdown", "generated"], w)), " ")
    comment_only = |source| {
        lines = List.keep_if(line_list(source), |line| !blank(line.text))
        !List.is_empty(lines) and List.all(lines, |line| Str.starts_with(trim(line.text), "#"))
    }
    uncomment = |source| Str.join_with(List.map(Str.split_on(source, "\n"), |line| {
        text = Str.trim_start(line)
        if Str.starts_with(text, "# ") { Str.drop_prefix(text, "# ") } else { Str.drop_prefix(text, "#") }
    }), "\n")
    comment = |source| Str.join_with(List.map(Str.split_on(source, "\n"), |line| if line == "" { "#" } else { "# ${line}" }), "\n")
    clip = |source, start, end| {
        lines = List.keep_if(line_list(slice(source, start, end)), |line| !blank(line.text))
        match (List.first(lines), List.last(lines)) {
            (Ok(first), Ok(last)) => { start: start + first.start, end: start + last.start + count(last.text) }
            _ => { start, end: start }
        }
    }
    normalize_lines = |source| Str.join_with(List.map(Str.split_on(trim(source), "\n"), |line| trim(line)), "\n")
    restore_literal_markers = |source, facts, base| {
        var $cursor = 0
        var $result = ""
        var $map = []
        for line in line_list(source) {
            if line.start >= $cursor and safe_comment(facts, base + line.start) and Str.starts_with(line.text, "# roclet:literal-marker ") {
                decoded : Try(Str, _)
                decoded = Json.parse(Str.drop_prefix(line.text, "# roclet:literal-marker "))
                match decoded {
                    Ok(literal) => {
                        if !Str.contains(literal, "\n") and (Str.starts_with(literal, "# %%") or Str.starts_with(literal, "#%%")) {
                            prefix = slice(source, $cursor, line.start)
                            $map = List.append($map, { start: count($result), end: count($result) + count(prefix), original_start: $cursor, original_end: line.start })
                            $result = "${$result}${prefix}${literal}"
                            $cursor = line.end
                        }
                    }
                    Err(_) => {}
                }
            }
        }
        tail = slice(source, $cursor, count(source))
        $map = List.append($map, { start: count($result), end: count($result) + count(tail), original_start: $cursor, original_end: count(source) })
        { source: "${$result}${tail}", source_map: $map }
    }
    segment_roc : Input -> Model
    segment_roc = |input| {
        source = input.source
        boundaries = List.keep_if(line_list(source), |line| {
            marker = Str.starts_with(line.text, "# %%") or Str.starts_with(line.text, "#%%")
            rest = if Str.starts_with(line.text, "# %%") { Str.drop_prefix(line.text, "# %%") } else { Str.drop_prefix(line.text, "#%%") }
            marker and (rest == "" or Str.starts_with(rest, " ") or Str.starts_with(rest, "\t")) and safe_comment(input.facts, line.start) and !List.any(input.facts.statements, |s| s.start < line.start and line.start < s.end)
        })
        preamble_end = List.first(boundaries).map_ok(|line| line.start).ok_or(input.facts.header_end)
        cells = if List.is_empty(boundaries) {
            range = clip(source, preamble_end, count(source))
            if range.start == range.end { [] } else { [cell("code", slice(source, range.start, range.end), "", range.start, range.end, range.start)] }
        } else {
            List.map_with_index(boundaries, |marker, index| {
                next = List.get(boundaries, index + 1).map_ok(|line| line.start).ok_or(count(source))
                attrs = trim(if Str.starts_with(marker.text, "# %%") { Str.drop_prefix(marker.text, "# %%") } else { Str.drop_prefix(marker.text, "#%%") })
                range = clip(source, minimum(marker.end + 1, count(source)), next)
                body = slice(source, range.start, range.end)
                override = kind_attribute(attrs)
                kind = if override != "" { override } else if comment_only(body) { "markdown" } else { "code" }
                restored = restore_literal_markers(body, input.facts, range.start)
                c = cell(kind, if kind == "markdown" { uncomment(body) } else { restored.source }, without_kind(attrs), marker.start, next, range.start)
                { ..c, id: id_attribute(attrs), source_map: restored.source_map }
            })
        }
        raw_preamble = slice(source, 0, preamble_end)
        metadata_lines = List.keep_if(line_list(raw_preamble), |line| Str.starts_with(line.text, "# roclet:document ") and safe_comment(input.facts, line.start))
        metadata = if List.len(metadata_lines) == 1 { List.first(metadata_lines).map_ok(|line| Str.drop_prefix(line.text, "# roclet:document ")).ok_or("") } else { "" }
        preamble = Str.join_with(List.map(List.keep_if(line_list(raw_preamble), |line| !(List.len(metadata_lines) == 1 and List.any(metadata_lines, |m| m.start == line.start))), |line| line.text), "\n")
        versions = List.keep_if(line_list(raw_preamble), |line| Str.starts_with(line.text, "# roclet:format=") and line.text != "# roclet:format=1")
        version_diagnostics = List.map(versions, |line| diagnostic("format-version", "Unsupported format version", line.start, line.end, 0))
        diagnostics = if List.len(metadata_lines) > 1 { List.append(version_diagnostics, diagnostic("metadata", "Duplicate document metadata remains in the preamble", 0, preamble_end, 0)) } else { version_diagnostics }
        { ..empty_model, format: "roc", original: source, preamble, metadata, cells, diagnostics }
    }
    flush_prose = |cells, source, start, end, attrs, force| {
        range = clip(source, start, end)
        if range.start == range.end and !force { cells } else {
            c = cell("markdown", slice(source, range.start, range.end), without_kind(attrs), start, end, range.start)
            List.append(cells, { ..c, id: id_attribute(attrs) })
        }
    }
    marker_inner = |text| trim(Str.drop_suffix(Str.drop_prefix(trim(text), "<!--"), "-->"))
    is_marker = |text| {
        t = trim(text)
        inner = marker_inner(t)
        Str.starts_with(t, "<!--") and Str.ends_with(t, "-->") and (inner == "%%" or Str.starts_with(inner, "%% ")) and !Str.contains(inner, "\n")
    }
    reserved_inner = |inner| inner == "%%" or Str.starts_with(inner, "%% ") or Str.starts_with(inner, "roclet:document ") or Str.starts_with(inner, "roclet:outputs ")
    unescape_markers = |source, marker_lines| Str.join_with(List.map_with_index(Str.split_on(source, "\n"), |line, index| {
        inner = marker_inner(line)
        if List.contains(marker_lines, index) and Str.starts_with(inner, "\\") and reserved_inner(Str.trim_start(replace(inner, "\\", ""))) {
            Str.replace_first(line, "\\", "")
        } else { line }
    }), "\n")
    image_output = |text| {
        t = trim(text)
        Str.starts_with(t, "![") and Str.ends_with(t, ")") and !Str.contains(t, "\n") and List.len(Str.split_on(t, "](")) == 2 and List.len(Str.split_on(t, ")")) == 2
    }
    segment_markdown : Input -> Model
    segment_markdown = |input| {
        s = input.source
        var $cells = []
        var $cursor = 0
        var $attrs = ""
        var $empty = False
        var $outputs = False
        var $preamble = ""
        var $metadata = ""
        var $diagnostics = []
        for b in input.blocks {
            text = slice(s, b.start, b.end)
            if b.kind == "html" and is_marker(text) {
                $cells = flush_prose($cells, s, $cursor, b.start, $attrs, $empty)
                $cursor = b.end
                $attrs = trim(Str.drop_prefix(marker_inner(text), "%%"))
                $empty = kind_attribute($attrs) == "markdown"
                $outputs = False
            } else if b.kind == "html" and Str.starts_with(trim(text), "<!-- roclet:document ") {
                raw = trim(Str.drop_suffix(Str.drop_prefix(trim(text), "<!-- roclet:document "), "-->"))
                decoded : Try({ format : U64, rocPreamble : Str }, _)
                decoded = Json.parse(raw)
                match decoded {
                    Ok(meta) if $metadata == "" => {
                        $cells = flush_prose($cells, s, $cursor, b.start, $attrs, $empty)
                        $preamble = meta.rocPreamble
                        $metadata = raw
                        $cursor = b.end
                        $attrs = ""
                        $empty = False
                        if meta.format != 1 { $diagnostics = List.append($diagnostics, diagnostic("format-version", "Unsupported document format version", b.start, b.end, 0)) }
                    }
                    Ok(_) => { $diagnostics = List.append($diagnostics, diagnostic("metadata", "Duplicate document metadata is preserved as prose", b.start, b.end, 0)) }
                    Err(_) => { $diagnostics = List.append($diagnostics, diagnostic("metadata", "Invalid document metadata; preserved as prose", b.start, b.end, 0)) }
                }
                $outputs = False
            } else if b.kind == "fence" and b.info == "roc" {
                $cells = flush_prose($cells, s, $cursor, b.start, $attrs, $empty)
                attrs = if $empty or !blank(slice(s, $cursor, b.start)) { "" } else { $attrs }
                kind = if kind_attribute(attrs) == "generated" { "generated" } else { "code" }
                restored = restore_literal_markers(strip_eol(slice(s, b.body_start, b.body_end)), b.facts, 0)
                c = cell(kind, restored.source, without_kind(attrs), b.start, b.end, b.body_start)
                $cells = List.append($cells, { ..c, id: id_attribute(attrs), source_map: restored.source_map })
                $cursor = b.end
                $attrs = ""
                $empty = False
                $outputs = True
            } else if $outputs and b.kind == "html" and blank(slice(s, $cursor, b.start)) and Str.starts_with(trim(text), "<!-- roclet:outputs ") {
                raw = trim(Str.drop_suffix(Str.drop_prefix(trim(text), "<!-- roclet:outputs "), "-->"))
                match decode_outputs(raw) {
                    Ok(items) => {
                        last = List.len($cells) - 1
                        $cells = List.map_with_index($cells, |c, i| if i == last { { ..c, outputs: List.concat(c.outputs, items) } } else { c })
                        $cursor = b.end
                    }
                    Err(_) => { $diagnostics = List.append($diagnostics, diagnostic("output-metadata", "Malformed output metadata is preserved as prose", b.start, b.end, 0)) }
                }
            } else if $outputs and blank(slice(s, $cursor, b.start)) and ((b.kind == "fence" and b.info == "text") or b.kind == "table" or b.kind == "image") {
                output = { kind: if b.kind == "fence" { "text" } else if b.kind == "table" { "table" } else { "image" }, source: if b.kind == "fence" { strip_eol(slice(s, b.body_start, b.body_end)) } else { Str.drop_suffix(text, "\n") } }
                last = List.len($cells) - 1
                $cells = List.map_with_index($cells, |c, i| if i == last { { ..c, outputs: List.append(c.outputs, output) } } else { c })
                $cursor = b.end
            } else {
                $outputs = False
            }
        }
        $cells = flush_prose($cells, s, $cursor, count(s), $attrs, $empty)
        { ..empty_model, format: "markdown", original: s, preamble: $preamble, metadata: $metadata, cells: $cells, diagnostics: $diagnostics }
    }
    fresh = |used, prefix, numbered| {
        var $index = 1.U64
        var $name = if numbered { "${prefix}_1" } else { prefix }
        while List.contains(used, $name) {
            $index = $index + 1
            $name = "${prefix}_${Str.inspect($index)}"
        }
        $name
    }
    fence = |language, source| {
        var $ticks = "```"
        while Str.contains(source, $ticks) { $ticks = "${$ticks}`" }
        "${$ticks}${language}\n${source}\n${$ticks}"
    }
    html_json = |json| replace(json, "--", "\\u002d\\u002d")
    escape_markers = |source, marker_lines| Str.join_with(List.map_with_index(Str.split_on(source, "\n"), |line, index| {
        inner = marker_inner(line)
        if List.contains(marker_lines, index) and reserved_inner(Str.trim_start(replace(inner, "\\", ""))) {
            rest = Str.drop_prefix(Str.trim_start(line), "<!--")
            pos = count(line) - count(Str.trim_start(rest))
            "${slice(line, 0, pos)}\\${slice(line, pos, count(line))}"
        } else { line }
    }), "\n")
    decode_outputs : Str -> Try(List(Output), _)
    decode_outputs = |source| Json.parse(source)
    snapshot_comments : Cell -> List(Output)
    snapshot_comments = |c| {
        var $texts = []
        var $rich = []
        for line in line_list(c.source) {
            parts = Str.split_on(line.text, "# =>")
            if List.len(parts) > 1 {
                before = List.first(parts).ok_or("")
                at = line.start + count(before)
                if safe_comment(c.facts, at) {
                    $texts = List.append($texts, Str.drop_prefix(Str.join_with(List.drop_first(parts, 1), "# =>"), " "))
                }
            }
            if Str.starts_with(line.text, "# roclet:outputs ") and safe_comment(c.facts, line.start) {
                decoded : Try(List(Output), _)
                decoded = decode_outputs(Str.drop_prefix(line.text, "# roclet:outputs "))
                match decoded { Ok(items) => { $rich = List.concat($rich, items) }
                    Err(_) => {} }
            }
        }
        if List.is_empty($texts) { $rich } else { List.prepend($rich, { kind: "text", source: Str.join_with($texts, "\n") }) }
    }
    strip_snapshots = |c| Str.join_with(List.map(line_list(c.source), |line| {
        if Str.starts_with(line.text, "# roclet:outputs ") and safe_comment(c.facts, line.start) {
            match decode_outputs(Str.drop_prefix(line.text, "# roclet:outputs ")) { Ok(_) => ""
                Err(_) => line.text }
        } else {
            parts = Str.split_on(line.text, "# =>")
            before = List.first(parts).ok_or("")
            at = line.start + count(before)
            if List.len(parts) > 1 and safe_comment(c.facts, at) { Str.trim_end(before) } else { line.text }
        }
    }), "\n")
    identifier = |name| name != "" and List.all(Str.to_utf8(name), |b| (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or b == 95)
    is_output = |name| Str.starts_with(name, "out_")
    output_id = |name| Str.drop_prefix(name, "out_")
    output_attributes = |c, materialized| {
        attrs = words(c.attributes)
        ids = List.keep_if(attrs, |word| Str.starts_with(word, "id="))
        if materialized and List.len(ids) == 1 and c.id != "" and id_attribute(c.attributes) == c.id and c.id == output_id(c.output) {
            Str.join_with(List.keep_if(attrs, |word| !Str.starts_with(word, "id=")), " ")
        } else { c.attributes }
    }
    display_source = |name| "${name} = |value| echo!(\"\u(24){Str.inspect(value)}\\n\")"
    valid_entry = |source| {
        lines = List.keep_if(List.map(Str.split_on(trim(source), "\n"), |line| trim(line)), |line| line != "")
        first = List.first(lines).ok_or("")
        helper = List.first(Str.split_on(first, " = ")).ok_or("")
        suffix = Str.drop_suffix(Str.drop_prefix(helper, "display_"), "!")
        helper_name = helper == "display!" or (Str.starts_with(helper, "display_") and Str.ends_with(helper, "!") and suffix != "" and List.all(Str.to_utf8(suffix), |b| b >= 48 and b <= 57))
        has_helper = helper_name and first == display_source(helper)
        main_lines = if has_helper { List.drop_first(lines, 1) } else { lines }
        valid_main(main_lines, if has_helper { helper } else { "" })
    }
    valid_main = |lines, helper| {
        if List.len(lines) < 3 { False } else {
            body = List.take_first(List.drop_first(lines, 1), List.len(lines) - 3)
            List.first(lines).ok_or("") == "main! = |_args| {" and List.last(lines).ok_or("") == "}" and List.get(lines, List.len(lines) - 2).ok_or("") == "Ok({})" and List.all(body, |line| {
                if helper != "" and Str.starts_with(line, "${helper}(") and Str.ends_with(line, ")") {
                    name = Str.drop_suffix(Str.drop_prefix(line, "${helper}("), ")")
                    is_output(name) and identifier(name)
                } else { False }
            })
        }
    }
    main_source = |outputs, helper| {
        prefix = if List.is_empty(outputs) { "" } else { "${display_source(helper)}\n\n" }
        "${prefix}main! = |_args| {\n${Str.join_with(List.map(outputs, |name| "    ${helper}(${name})\n"), "")}    Ok({})\n}"
    }
    map_entry = |generated_start, generated_end, source_start, source_end, cell_index| { generated_start, generated_end, source_start, source_end, cell: cell_index }
    finish : Input -> Result
    finish = |input| {
        model = input.model
        var $diagnostics = model.diagnostics
        for f in input.metadata_fields {
            if f.key == "format" and f.value != "1" { $diagnostics = List.append($diagnostics, diagnostic("format-version", "Unsupported document metadata version", 0, 0, 0)) }
        }
        var $used = List.join(List.map(List.keep_if(model.cells, |c| c.kind == "code"), |c| List.map(List.keep_if(c.facts.statements, |s| s.name != ""), |s| s.name)))
        preamble_names = List.map(List.keep_if(input.facts.statements, |stmt| stmt.name != ""), |stmt| stmt.name)
        $used = List.concat($used, preamble_names)
        $used = List.concat($used, List.map($used, |name| Str.drop_suffix(name, "!")))
        # Anonymous results must not claim another cell's explicit ID.
        reserved = List.map(List.keep_if(model.cells, |c| identifier(c.id)), |c| "out_${c.id}")
        var $seen = preamble_names
        var $ids = []
        var $cells = []
        var $lowered = []
        prelude = slice(model.preamble, minimum(input.facts.header_end, count(model.preamble)), count(model.preamble))
        var $execution = if blank(prelude) { "" } else { "${prelude}\n\n" }
        var $roots = []
        var $mappings = []
        var $handwritten_main = False
        for stmt in input.facts.statements {
            if stmt.kind == "dbg" {
                $diagnostics = List.append($diagnostics, diagnostic("top-level-dbg", "dbg must be inside a Roc function or expression block", stmt.start, stmt.end, 0))
            }
            if stmt.name == "main!" {
                $handwritten_main = True
                $diagnostics = List.append($diagnostics, diagnostic("handwritten-main", "The preamble contains a handwritten main!; it is preserved without execution", stmt.start, stmt.end, 0))
            }
        }
        if List.any(input.facts.tokens, |t| t.depth == 0 and List.contains(["KwModule", "KwPackage", "KwPlatform", "KwHosted"], t.tag)) {
            $diagnostics = List.append($diagnostics, diagnostic("unsupported-header", "A runnable Roclet notebook needs an app header; the existing header is preserved", 0, input.facts.header_end, 0))
        }
        for (original, index) in indexed(model.cells) {
            var $c = if original.kind == "markdown" and model.format == "markdown" and !input.draft.supplied { { ..original, source: unescape_markers(original.source, original.marker_lines) } } else { original }
            for word in words($c.attributes) {
                if !Str.contains(word, "=") or word == "id=" {
                    $diagnostics = List.append($diagnostics, diagnostic("malformed-attribute", "Cell attributes must be nonempty key=value pairs", $c.start, $c.body_start, index))
                }
                if !Str.starts_with(word, "id=") {
                    d = diagnostic("unknown-attribute", "Unknown cell metadata is preserved; its behavior is unsupported", $c.start, $c.body_start, index)
                    $diagnostics = List.append($diagnostics, { ..d, severity: "warning" })
                }
            }
            if $c.kind == "code" {
                for line in line_list($c.source) {
                    if Str.starts_with(line.text, "# roclet:literal-marker ") and safe_comment($c.facts, line.start) {
                        $diagnostics = List.append($diagnostics, diagnostic("literal-marker-conflict", "Malformed literal marker metadata is preserved", $c.body_start + line.start, $c.body_start + line.end, index))
                    }
                }
                for line in line_list($c.source) {
                    if Str.starts_with(line.text, "# roclet:outputs ") and safe_comment($c.facts, line.start) {
                        match decode_outputs(Str.drop_prefix(line.text, "# roclet:outputs ")) {
                            Ok(_) => {}
                            Err(_) => { $diagnostics = List.append($diagnostics, diagnostic("output-metadata", "Malformed output metadata is preserved", $c.body_start + line.start, $c.body_start + line.end, index)) }
                        }
                    }
                }
                for err in $c.facts.errors {
                    $diagnostics = List.append($diagnostics, diagnostic("roc-syntax", "Roc syntax error; source is preserved", $c.body_start + err.start, $c.body_start + err.end, index))
                }
                bindings = List.keep_if($c.facts.statements, |s| s.kind == "decl" and is_output(s.name))
                if List.len(bindings) > 1 {
                    $diagnostics = List.append($diagnostics, diagnostic("multiple-outputs", "A cell may define only one top-level out_* output", $c.body_start, $c.end, index))
                }
                for stmt in $c.facts.statements {
                    if stmt.kind == "dbg" {
                        $diagnostics = List.append($diagnostics, diagnostic("top-level-dbg", "dbg must be inside a Roc function or expression block; only a final expression may appear outside a top-level definition", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                    } else if !List.contains(["decl", "expr", "expect", "type_decl", "type_anno", "import", "file_import", "malformed"], stmt.kind) {
                        $diagnostics = List.append($diagnostics, diagnostic("unsupported-statement", "This statement cannot be exported at module scope", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                    }
                    if stmt.kind == "decl" and stmt.name == "" {
                        $diagnostics = List.append($diagnostics, diagnostic("unsupported-pattern", "Notebook output analysis currently requires simple top-level bindings", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                    }
                    if stmt.name != "" {
                        if List.contains($seen, stmt.name) {
                            $diagnostics = List.append($diagnostics, diagnostic("duplicate-definition", "Duplicate top-level definition ${stmt.name}", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                        }
                        $seen = List.append($seen, stmt.name)
                        if stmt.name == "main!" {
                            $handwritten_main = True
                            $diagnostics = List.append($diagnostics, diagnostic("handwritten-main", "An editable cell defines main!; it is preserved and will not be replaced or executed", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                        }
                    }
                }
                chosen = List.first(bindings).map_ok(|s| s.name).ok_or("")
                $c = { ..$c, output: chosen }
                var $cursor = 0
                var $code = ""
                base = count($execution)
                for (stmt, si) in indexed($c.facts.statements) {
                    is_final = si + 1 == List.len($c.facts.statements)
                    if stmt.kind == "expr" {
                        prefix = slice($c.source, $cursor, stmt.start)
                        $mappings = List.append($mappings, map_entry(base + count($code), base + count($code) + count(prefix), $c.body_start + $cursor, $c.body_start + stmt.start, index))
                        $code = "${$code}${prefix}"
                        body = slice($c.source, stmt.start, stmt.end)
                        if !is_final or chosen != "" {
                            $diagnostics = List.append($diagnostics, diagnostic("ambiguous-expression", "Only a final expression in a cell without an explicit output can become its result", $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                            $code = "${$code}${body}"
                        } else {
                            named = identifier($c.id)
                            preferred = if named { "out_${$c.id}" } else { "out" }
                            taken = List.concat($used, List.keep_if(reserved, |name| name != "out_${$c.id}"))
                            name = fresh(taken, preferred, !named)
                            $used = List.append($used, name)
                            $c = { ..$c, output: name }
                            $code = "${$code}${name} = "
                            $mappings = List.append($mappings, map_entry(base + count($code), base + count($code) + count(body), $c.body_start + stmt.start, $c.body_start + stmt.end, index))
                            $code = "${$code}${body}"
                        }
                        $cursor = stmt.end
                    }
                }
                tail = slice($c.source, $cursor, count($c.source))
                $mappings = List.append($mappings, map_entry(base + count($code), base + count($code) + count(tail), $c.body_start + $cursor, $c.body_start + count($c.source), index))
                $code = "${$code}${tail}"
                $execution = "${$execution}${$code}\n\n"
                $lowered = List.append($lowered, escape_roc_markers($code, $c, base, $mappings))
                if $c.output != "" {
                    $roots = List.append($roots, $c.output)
                }
                comments = snapshot_comments($c)
                if !List.is_empty(comments) and !List.is_empty($c.outputs) {
                    $diagnostics = List.append($diagnostics, diagnostic("duplicate-snapshot", "Both Roc comments and Markdown blocks provide saved output; both are preserved", $c.body_start, $c.end, index))
                }
                $c = { ..$c, outputs: List.concat(comments, $c.outputs) }
                if !List.is_empty($c.outputs) and $c.output == "" {
                    $diagnostics = List.append($diagnostics, diagnostic("orphan-snapshot", "Saved output has no selected cell result", $c.body_start, $c.end, index))
                }
                if $c.id == "" {
                    names = List.map(List.keep_if($c.facts.statements, |stmt| stmt.name != ""), |stmt| stmt.name)
                    inferred = if $c.output != "" { output_id($c.output) } else { Str.join_with(names, "_and_") }
                    $c = { ..$c, id: inferred }
                }
            } else { $lowered = List.append($lowered, $c.source) }
            if $c.id != "" {
                if List.contains($ids, $c.id) {
                    $diagnostics = List.append($diagnostics, diagnostic("duplicate-id", "Cell ID ${$c.id} is not unique", $c.start, $c.end, index))
                }
                $ids = List.append($ids, $c.id)
            }
            $cells = List.append($cells, $c)
        }
        main = main_source($roots, "${fresh($used, "display", False)}!")
        var $conflict = False
        if List.len(List.keep_if($cells, |c| c.kind == "generated")) > 1 {
            $conflict = True
            $diagnostics = List.append($diagnostics, diagnostic("generated-conflict", "Multiple generated entry sections are preserved", 0, 0, 0))
        }
        for (c, index) in indexed($cells) {
            if c.kind == "generated" and !valid_entry(c.source) {
                $conflict = True
                $diagnostics = List.append($diagnostics, diagnostic("generated-conflict", "The generated entry differs from the supported structure; preserved without execution", c.body_start, c.end, index))
            }
        }
        completed = { ..model, cells: $cells, diagnostics: $diagnostics }
        editing = List.contains(["view", "compose"], input.phase)
        rendered = if input.target == "roc" { encode_roc(completed, $lowered, main, $conflict or $handwritten_main, input.facts.header_end > 0, !editing, input.metadata_fields) } else { encode_markdown(completed, $conflict, input.metadata_fields, !editing) }
        source = if !input.draft.supplied and !List.contains(["normalize", "export", "view", "compose"], input.phase) and input.target == model.format { model.original } else { rendered }
        draft = { supplied: True, preamble: completed.preamble, metadata: completed.metadata, cells: List.map($cells, |c| {
            { kind: c.kind, source: c.source, attributes: c.attributes, outputs: if c.kind == "code" { List.drop_first(c.outputs, List.len(snapshot_comments(c))) } else { c.outputs } }
        }) }
        { plan: empty_plan, status: if List.any($diagnostics, |d| d.severity == "error") { "diagnostic" } else { "ok" }, model: completed, draft, source, program: $execution, execution: "${$execution}${main}\n", roots: $roots, mappings: $mappings }
    }
    escape_roc_markers = |code, c, base, mappings| Str.join_with(List.map(line_list(code), |line| {
        marker = Str.starts_with(line.text, "# %%") or Str.starts_with(line.text, "#%%")
        position = base + line.start
        mapping = List.first(List.keep_if(mappings, |m| m.generated_start <= position and position < m.generated_end))
        safe = match mapping {
            Ok(m) => safe_comment(c.facts, m.source_start + position - m.generated_start - c.body_start)
            Err(_) => False
        }
        if marker and safe { "# roclet:literal-marker ${Json.to_str(line.text)}" } else { line.text }
    }), "\n")
    prose_source = |c| {
        var $cursor = 0
        var $text = ""
        for b in c.blocks {
            if b.kind == "fence" and b.info == "roc" {
                opening = Str.trim_end(slice(c.source, b.start, b.body_start))
                $text = "${$text}${slice(c.source, $cursor, b.start)}${Str.drop_suffix(opening, "roc")}roc example\n"
                $cursor = b.body_start
            }
        }
        "${$text}${slice(c.source, $cursor, count(c.source))}"
    }
    starts_output = |c| {
        b = c.first_block
        (Str.starts_with(Str.trim_start(c.source), "![") or (blank(slice(c.source, 0, b.start)) and ((b.kind == "fence" and b.info == "text") or b.kind == "table" or b.kind == "image")))
    }
    encode_roc : Model, List(Str), Str, Bool, Bool, Bool, List(MetadataField) -> Str
    encode_roc = |model, lowered, main, conflict, has_header, runnable, metadata_fields| {
        preamble = if blank(model.preamble) { "app [main!] {}" } else if has_header { Str.trim_end(model.preamble) } else { "app [main!] {}\n\n${Str.trim_end(model.preamble)}" }
        fields = List.map(List.keep_if(metadata_fields, |f| f.key != "rocPreamble" and !(f.key == "format" and f.value == "1")), |f| "${Json.to_str(f.key)}:${f.value}")
        metadata = if List.is_empty(fields) { "" } else { "\n# roclet:document {${Str.join_with(fields, ",")}}" }
        var $parts = ["${preamble}${metadata}"]
        for (c, i) in indexed(model.cells) {
            if c.kind != "generated" or conflict {
                attributes = output_attributes(c, runnable and c.kind == "code")
                attrs = if attributes == "" { "" } else { " ${attributes}" }
                if c.kind == "markdown" {
                    explicit = if blank(c.source) { " markdown" } else { "" }
                    $parts = List.append($parts, "# %%${explicit}${attrs}\n${comment(c.source)}")
                } else if c.kind == "generated" {
                    $parts = List.append($parts, "# %% generated${attrs}\n${c.source}")
                } else {
                    code = if runnable { List.get(lowered, i).ok_or(c.source) } else { escape_roc_markers(c.source, c, 0, [map_entry(0, count(c.source), c.body_start, c.body_start + count(c.source), i)]) }
                    explicit = if comment_only(code) { " code" } else { "" }
                    existing = snapshot_comments(c)
                    extra = List.drop_first(c.outputs, List.len(existing))
                    suffix = if List.is_empty(extra) { "" } else if List.len(extra) == 1 and List.first(extra).ok_or({ kind: "", source: "" }).kind == "text" { "\n${Str.join_with(List.map(Str.split_on(List.first(extra).ok_or({ kind: "", source: "" }).source, "\n"), |line| "# => ${line}"), "\n")}" } else { "\n# roclet:outputs ${Json.to_str(extra)}" }
                    $parts = List.append($parts, "# %%${explicit}${attrs}\n${code}${suffix}")
                }
            }
        }
        if runnable and !conflict {
            attrs = List.first(List.keep_if(model.cells, |c| c.kind == "generated")).map_ok(|c| c.attributes).ok_or("")
            suffix = if attrs == "" { "" } else { " ${attrs}" }
            $parts = List.append($parts, "# %% generated${suffix}\n${main}")
        }
        "${Str.join_with($parts, "\n\n")}\n"
    }
    markdown_code = |c| {
        cleaned = strip_snapshots(c)
        last = List.last(c.facts.statements)
        match last {
            Ok(stmt) if stmt.kind == "expr" and c.output != "" and !List.any(c.facts.statements, |s| s.kind == "decl" and is_output(s.name)) => {
                prefix = strip_snapshots({ ..c, source: slice(c.source, 0, stmt.start) })
                "${prefix}${c.output} = ${slice(cleaned, count(prefix), count(cleaned))}"
            }
            _ => cleaned
        }
    }
    encode_markdown : Model, Bool, List(MetadataField), Bool -> Str
    encode_markdown = |model, conflict, metadata_fields, exporting| {
        fields = List.map(List.keep_if(metadata_fields, |f| f.key != "format" and f.key != "rocPreamble"), |f| "${Json.to_str(f.key)}:${f.value}")
        version = List.first(List.keep_if(metadata_fields, |f| f.key == "format")).map_ok(|f| f.value).ok_or("1")
        meta = "{${Str.join_with(List.concat(["\"format\":${version}", "\"rocPreamble\":${Json.to_str(model.preamble)}"], fields), ",")}}"
        default_preamble = blank(model.preamble) or trim(model.preamble) == "app [main!] {}"
        var $parts = if exporting and (!default_preamble or !List.is_empty(fields) or version != "1") { ["<!-- roclet:document ${html_json(meta)} -->"] } else { [] }
        var $previous = ""
        for c in model.cells {
            if c.kind == "markdown" {
                attrs = if c.attributes == "" { "" } else { " ${c.attributes}" }
                # A marker after code also prevents output-shaped author prose attaching to it.
                if c.source == "" { $parts = List.append($parts, "<!-- %% markdown${attrs} -->") } else {
                    if $previous == "markdown" or attrs != "" or ($previous == "code" and starts_output(c)) { $parts = List.append($parts, "<!-- %%${attrs} -->") }
                    $parts = List.append($parts, escape_markers(prose_source(c), c.marker_lines))
                }
                $previous = "markdown"
            } else if c.kind == "code" {
                attrs = output_attributes(c, exporting)
                if attrs != "" { $parts = List.append($parts, "<!-- %% ${attrs} -->") }
                $parts = List.append($parts, fence("roc", Str.trim_end(if exporting { markdown_code(c) } else { strip_snapshots(c) })))
                for output in c.outputs { $parts = List.append($parts, if output.kind == "text" { fence("text", output.source) } else if output.kind == "image" or output.kind == "table" { output.source } else { "<!-- roclet:outputs ${html_json(Json.to_str([output]))} -->" }) }
                $previous = "code"
            } else if conflict or c.attributes != "" {
                $parts = List.append($parts, "<!-- %% generated ${c.attributes} -->\n\n${fence("roc", c.source)}")
                $previous = "generated"
            }
        }
        "${Str.join_with($parts, "\n\n")}\n"
    }
    segment : Input -> Model
    segment = |input| if input.format == "roc" { segment_roc(input) } else { segment_markdown(input) }
}
