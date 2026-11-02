app [main!] { garden: "./garden.roc" }

# %%
# # A garden plan from a Gist
# This small notebook uses a real Roc package in the same Gist.
# The app header declares `garden: "./garden.roc"`; the package exposes `Garden`.
# Press **Run all**, then change the dimensions or the spacing and run again.

# %%
import garden.Garden
import "planting-notes.txt" as planting_notes : Str

# %%
width = 6
depth = 4
plants_per_square_metre = 3

# %%
out_1 = Garden.plan(width, depth, plants_per_square_metre)

# %%
out_2 = planting_notes

# %%
# The calculation lives in `Garden.roc`, which uses a second module, `Spacing.roc`.
# Open **File → Project files** to inspect the package and its modules.
# Open **File → Attachments** to inspect the planting notes.
# Your changes are saved in this browser. Download a Roclet bundle to keep all files.
