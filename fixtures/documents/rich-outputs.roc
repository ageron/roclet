app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.1.0/DgxFw9gRQuHiBsKhkuG4RxHPAyjMXLK6sujcMfnHijc7.tar.zst" }
import roclet.Display
import roclet.Input

# %%
# # Rich outputs
# Move the width slider to update the summary, table, HTML card, and SVG diagram. Expand **Plain text**
# beneath a result to see what the same value prints in a standalone Roc script.
#
# Inline math: $A = w \times h$. Display math:
#
# $$\int_0^1 x^2\,dx = \frac{1}{3}$$

# %%
width_control = Input.slider({
    key: "width", label: "Width", min: 1, max: 20, step: 1, default: 5,
})
width = wall_control.value
height = 3
out_width = width_control.display

# %%
summary =
    \\## Wall area
    \\The area is **${(width * height).to_str()}** square metres.
    \\
    \\$A = ${(width * height).to_str()}$
out_1 = Display.markdown(summary)

# %%
out_2 = Display.table(["Measurement", "Value"], [
    ["Width", width.to_str()],
    ["Height", height.to_str()],
    ["Area", (width * height).to_str()],
    ["Exact large integer", "9007199254740993"],
])

# %%
# Images contain their own data, so this swatch also works offline.
# PNG, JPEG, and WebP images are supported.

# %%
swatch = Str.join_with([
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOwrw2h",
    "KWIYtWDUglELRi0YtWDUglELRi0YtWDUglELhooFADqrQD2nQXpjAAAAAElFTkSu",
    "QmCC",
], "")
out_3 = Display.image("Green colour swatch", "image/png", swatch)

# %%
# ## HTML and SVG
# HTML supports styled layouts and native controls such as expandable details.
# SVG diagrams scale without losing sharpness. Change `width` above to redraw both.

# %%
title = "Wall area: ${(width * height).to_str()} square metres"
html =
    \\<article style="border-left:5px solid #8050be;padding:16px;background:#8050be18;border-radius:8px">
    \\    <h2 style="margin-top:0">Wall area</h2>
    \\    <strong style="font-size:2rem">${(width * height).to_str()} m²</strong>
    \\    <details>
    \\        <summary>How is it calculated?</summary>
    \\        <p>Width × height: ${width.to_str()} × ${height.to_str()}</p>
    \\    </details>
    \\</article>
out_4 = Display.html(title, html)

# %%
diagram_title = "A ${width.to_str()} by ${height.to_str()} metre wall"
svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 160">
    \\    <rect x="20" y="15"
    \\        width="${(width * 30).to_str()}"
    \\        height="${(height * 30).to_str()}"
    \\        rx="8" fill="#8050be" />
    \\    <text x="20" y="140" fill="#8050be" font-family="sans-serif" font-size="18">
    \\        ${width.to_str()} × ${height.to_str()} metres
    \\    </text>
    \\</svg>
out_5 = Display.svg(diagram_title, svg)

# %%
# ## An interactive wall
# This custom control shares the width input with the slider above. It sends
# the width to Roc, which computes the area in the other outputs. With auto-run
# off, use Run all to update those results. The frame stays alive during updates.
# Imported snapshots and exported reports do not execute widget scripts.

# %%
widget_html =
    \\<label>
    \\    Width: <output id="widthValue">5</output> m
    \\    <input id="width" type="range" min="1" max="20" value="5">
    \\</label>
    \\<p>
    \\    <label><input id="grid" type="checkbox" checked> Show dimensions</label>
    \\</p>
    \\<div id="wall" style="height:90px;background:#8050be;border-radius:8px"></div>
    \\<p id="area"></p>
    \\<button id="reset" type="button">Reset</button>
    \\<script>
    \\    const width = document.getElementById("width");
    \\    const grid = document.getElementById("grid");
    \\    const wall = document.getElementById("wall");
    \\    const area = document.getElementById("area");
    \\
    \\    function update() {
    \\        document.getElementById("widthValue").value = width.value;
    \\        wall.style.width = (Number(width.value) * 25) + "px";
    \\        area.textContent = grid.checked
    \\            ? "Width: " + width.value + " m (area calculated by Roc above)"
    \\            : "";
    \\    }
    \\
    \\    width.oninput = () => { update(); roclet.setValue(Number(width.value)); };
    \\    grid.onchange = update;
    \\    document.getElementById("reset").onclick = () => {
    \\        width.value = 5;
    \\        roclet.setValue(5);
    \\        grid.checked = true;
    \\        update();
    \\    };
    \\    roclet.onValue(value => { width.value = value; update(); });
    \\</script>
wall_control = Input.custom({
    key: "width", label: "Interactive wall", min: 1, max: 20, default: 5,
    html: widget_html,
})
out_6 = wall_control.display

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_width)
    display!(out_1)
    display!(out_2)
    display!(out_3)
    display!(out_4)
    display!(out_5)
    display!(out_6)
    Ok({})
}
