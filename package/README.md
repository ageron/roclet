# Roclet Display package

`Display.text`, `Display.markdown`, `Display.table`, and `Display.image` produce
rich output in Roclet and readable text when printed by ordinary Roc.

```roc
app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.3.0/Gv78dUSQfYRU2yvV9HuS5oHYdMfik84S4sgsej6mbjLd.tar.zst" }

import roclet.Display

main! = |_args| {
    value = Display.markdown("# Hello")
    echo!("${Str.inspect(value)}\n")
    Ok({})
}
```

Roc fetches and caches the package on first use. Roclet embeds the matching
implementation, so browser and native notebook execution work offline.
Version `0.2.0` includes HTML, SVG, sliders, and custom reactive widgets.

## New markup constructors

The source package also provides `Display.html(plain_text, source)`,
`Display.svg(plain_text, source)`, and `Display.widget(plain_text, source)`.
HTML and SVG are inert; widgets allow inline JavaScript inside an isolated frame.
Markup is limited to 16 KiB. Widgets can update their own controls but do not
feed values into Roc definitions. Saved snapshots and reports disable scripts.

## Plotly charts with Plume

The source package provides `Display.plotly(plain_text, figure_json)`. Pass
`chart.to_json()` from [Plume 0.5.0](https://github.com/lukewilliamboswell/plume/releases/tag/0.5.0):

```roc
chart = Chart.new({ traces: [Scatter(curve)] })
out_chart = Display.plotly("A description of the curve", chart.to_json())
```

See the complete [Plume notebook](../demos/04-plume-charts.roc) for imports,
the pinned dependency, and a reactive amplitude slider. This constructor is
available in the source and embedded Roclet package; the published `0.2.0`
archive predates it. Ordinary Roc consumers need the local package until the
next Display release.

Figures must be JSON objects with a `data` array of trace objects and a `layout`
object. JSON is limited to 128 KiB; oversized figures return a text explanation,
and malformed figures keep the plain-text fallback. Roclet supplies Plotly.js
4.2.0 locally, so charts work offline after loading the Plume package. Charts
support hover and zoom inside an isolated frame. Saved previews and HTML reports
show the text summary without running chart scripts; run the cell to draw it.

## Reactive slider inputs

```roc
import roclet.Display
import roclet.Input

width_control = Input.slider({
    key: "width", label: "Width", min: 1, max: 20, step: 1, default: 5,
})
width = width_control.value
out_width = width_control.display

# In another cell:
out_area = width * 3
```

`value` is an `F64`. Give each control a stable, unique key (a letter followed
by letters, digits, underscores or hyphens, at most 64 characters).
Use finite bounds with `min < max`, a positive step and a default within bounds.
Roclet stores the current value in the notebook, without rewriting your code.
Moving the slider updates dependent results when auto-run is on; otherwise,
run the notebook to apply the change. Browser drafts and Roclet bundles retain
input values. Ordinary Roc apps and source-only exports use the declared default.
Saved output previews and reports show disabled controls until run in Roclet.

This first version shares one input-state module, so changing a slider may also
recompute other input-dependent results. Use `Input.custom` for a custom HTML control that sends a numeric value to Roc. Keep `import roclet.Display` alongside `Input`
so Roclet can recognize rich output values.

## Custom numeric inputs

`Input.custom({ key, label, min, max, default, html })` returns the same
`{ value, display }` pair as `Input.slider`. `value` is an F64. Controls using
the same key share one notebook input; otherwise use distinct keys.

The HTML can call `roclet.setValue(number)` and subscribe with
`roclet.onValue(value => { ... })`. Subscribing delivers the current value once
the frame connects, then subsequent evaluated values, including restored values
after undo. `onValue` returns an unsubscribe function. Updating controls inside
an `onValue` callback does not send another change back to Roclet.

```javascript
slider.oninput = () => roclet.setValue(Number(slider.value));
roclet.onValue(value => { slider.value = value; redraw(value); });
```

HTML is limited to 16 KiB. The frame retains its sandbox and receives only its
own numeric input through a private message channel. Non-numeric, non-finite,
and out-of-range updates are ignored. Changing only the input value preserves
the frame; changing its HTML or configuration recreates it. Reports and imported
snapshots disable scripts and the bridge. Browser saves and bundles retain input
values; standalone Roc uses the default. `Display.widget` remains available for
self-contained HTML/JavaScript without a Roc binding.

## Build and test locally

```sh
roc bundle package/main.roc --output-dir artifacts/display-package-test
zig build test-demos
```

The test builds the bundle, extracts it, compares the extracted sources, and runs
the example notebooks against that extracted package with ordinary Roc. The
Plume demo fetches its pinned release on first use, then uses Roc's package cache.
No published Display release is needed. Use `-Droc=/path/to/roc` to
choose the compiler. Generated archives stay in ignored build directories.

## Publish

1. Merge the package changes into `main`.
2. In GitHub Actions, choose **Release package → Run workflow**, select `main`,
   and enter a version such as `0.1.0`.
3. The workflow uses pinned Roc and Zig versions, tests the archive, then creates
   a versioned GitHub Release containing the content-addressed `.tar.zst`.
4. Merge the follow-up PR to update the package URL in Roclet and its demos.
   That push rebuilds the embedded runtime and deploys the website.

Pushes and pull requests only validate; they never publish. Package versions
use plain semver tags, independently of website deployments. Existing releases
are never overwritten. The first release may need no follow-up PR because its
URL is already prepared here.

Enable **Settings → Actions → General → Allow GitHub Actions to create and
approve pull requests** for automatic pin-update PRs. If PR creation fails after
publication, the release remains published: download the `display-release`
workflow artifact and apply `package-pin.patch` on the release commit, or run:

```sh
python3 tools/update-package-pin.py --version VERSION --archive HASH.tar.zst
```

Python is only used for release automation; running Roclet does not require it.
Do not commit generated archives or use a mutable `latest` URL in notebooks.
