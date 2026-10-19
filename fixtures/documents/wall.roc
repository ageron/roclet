app [main!] {}

# %%
# # Wall area
# Change the dimensions to update the result.

# %%
out_1 = area

# %%
width = 5
height = 3

# %%
area = width * height

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    Ok({})
}
