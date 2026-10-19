app [main!] {}
import Display

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
Display.markdown("## Wall area\nThe area is **${(width * height).to_str()}** square metres.\n\n$A = ${(width * height).to_str()}$")

# %%
Display.table(["Measurement", "Value"], [
    ["Width", width.to_str()],
    ["Height", height.to_str()],
    ["Area", (width * height).to_str()],
    ["Exact large integer", "9007199254740993"],
])

# %%
# Images contain their own data, so this swatch also works offline.
# Raw HTML and SVG are not executed by the result renderer.

# %%
Display.image("Green colour swatch", "image/png", "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOwrw2hKWIYtWDUglELRi0YtWDUglELRi0YtWDUglELhooFADqrQD2nQXpjAAAAAElFTkSuQmCC")
