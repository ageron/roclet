app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.1.0/DgxFw9gRQuHiBsKhkuG4RxHPAyjMXLK6sujcMfnHijc7.tar.zst" }
import roclet.Display

# %%
# # How much does a bigger circle hold?
# A circle's area grows with the square of its radius:
#
# $$A = \pi r^2$$
#
# Double `radius` below. Does the area double too?

# %%
radius = 3
pi = 3.141592653589793

# %%
area = pi * radius * radius
out_1 = Display.markdown("With radius **${radius.to_str()}**, the area is **${area.to_str()}**.\n\n$A = \\pi r^2$")

# %%
# You can mix explanations, equations, and live calculations in one notebook.
# Try **File → Export & share → HTML report** to share a readable snapshot.

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    Ok({})
}
