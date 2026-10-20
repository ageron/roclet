app [main!] {}

# %%
# # A result before its ingredients
# The result cell comes first on purpose. Change `guests` below from 4 to 6.
# Roclet follows definitions, so the total updates wherever you place the cells.

# %%
out_1 = slices_needed

# %%
guests = 4
slices_per_guest = 3

# %%
slices_needed = guests * slices_per_guest

# %%
# Try turning Auto-run off, changing `guests`, and running that cell with
# Cmd/Ctrl+Enter. Its dependent result updates too. Move the cells around:
# the calculation still means the same thing.

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    Ok({})
}
