app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.2.0/C8vdeSE1ABoSei4Lepuy9Dy7t7GAJQt42WQkWw9bhcFc.tar.zst" }
import roclet.Display
import roclet.Input

# %%
# # Rich Outputs and Widgets
# Roclet supports several rich outputs and widgets. For example, the following code creates a slider widget. Changing its position will automatically recompute the dependent Roc cells.

# %%
width_slider = Input.slider({
    key: "width", label: "Width", min: 1, max: 20, step: 1, default: 5,
})
out_1 = width_slider.display

# %%
# The slider's value is available in Roc:

# %%
height = 3
width = width_slider.value
wall_area = height * width
out_2 = wall_area

# %%
# Let's display the area using Markdown, including a LaTeX math equation:

# %%
summary =
    \\## Wall area
    \\The area is **${wall_area.to_str()}** square metres.
    \\
    \\$A = W \\times H = ${wall_area.to_str()}$

out_3 = Display.markdown(summary)

# %%
# Now let's display this data as a table:

# %%
out_4 = Display.table(["Measurement", "Value"], [
    ["Width", width.to_str()],
    ["Height", height.to_str()],
    ["Area", (width * height).to_str()],
])

# %%
# ## HTML
# Roclet also supports HTML with styled layouts and native controls such as expandable details:

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
out_5 = Display.html(title, html)

# %%
# ## Images
#
# Roclet can generate SVG images:

# %%
diagram_title = "A ${width.to_str()} by ${height.to_str()} metre wall"
svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 160">
    \\    <rect x="20" y="15"
    \\        width="${(width * 30).to_str()}"
    \\        height="${(height * 30).to_str()}"
    \\        rx="8" fill="#8050be" />
    \\    <text x="20" y="140" fill="#8050be" font-family="sans-serif" font-size="18">
    \\        ${width.to_str()} × ${height.to_str()} metres
    \\    </text>
    \\</svg>
out_6 = Display.svg(diagram_title, svg)

# %%
# You can also output PNG, JPEG, and WebP images:

# %%
green_square = Str.join_with([
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOwrw2h",
    "KWIYtWDUglELRi0YtWDUglELRi0YtWDUglELhooFADqrQD2nQXpjAAAAAElFTkSu",
    "QmCC",
], "")
out_7 = Display.image("Green square", "image/png", green_square)

# %%
# ## Custom widgets
# You can define your own custom widgets using HTML and JavaScript. They run in their own frame and stay alive during updates.
# This widget shares the `"width"` key with the first slider, so either control updates
# the same Roc value. `roclet.setValue` sends changes to Roc, and `roclet.onValue`
# receives changes from the other slider. With auto-run off, use **Run all** to update the results:

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
custom_slider = Input.custom({
    key: "width", label: "Interactive wall", min: 1, max: 20, default: 5,
    html: widget_html,
})
out_8 = custom_slider.display

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    display!(out_2)
    display!(out_3)
    display!(out_4)
    display!(out_5)
    display!(out_6)
    display!(out_7)
    display!(out_8)
    Ok({})
}
