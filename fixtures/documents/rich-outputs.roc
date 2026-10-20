app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.1.0/DgxFw9gRQuHiBsKhkuG4RxHPAyjMXLK6sujcMfnHijc7.tar.zst" }
import roclet.Display

# %%
# # Rich outputs
# Change `width` to update the Markdown summary and table. Expand **Plain text**
# beneath a result to see what the same value prints in a standalone Roc script.
#
# Inline math: $A = w \times h$. Display math:
#
# $$\int_0^1 x^2\,dx = \frac{1}{3}$$

# %%
width = 5
height = 3

# %%
out_1 = Display.markdown("## Wall area\nThe area is **${(width * height).to_str()}** square metres.\n\n$A = ${(width * height).to_str()}$")

# %%
out_2 = Display.table(["Measurement", "Value"], [
    ["Width", width.to_str()],
    ["Height", height.to_str()],
    ["Area", (width * height).to_str()],
    ["Exact large integer", "9007199254740993"],
])

# %%
# Images contain their own data, so this swatch also works offline.
# Raw HTML and SVG are not executed by the result renderer.

# %%
out_3 = Display.image("Green colour swatch", "image/png", "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOwrw2hKWIYtWDUglELRi0YtWDUglELRi0YtWDUglELhooFADqrQD2nQXpjAAAAAElFTkSuQmCC")

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    display!(out_2)
    display!(out_3)
    Ok({})
}
