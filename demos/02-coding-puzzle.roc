app [main!] {}

# %%
# # Coding puzzle: longest streak
# A habit tracker records each day as `Completed` or `Skipped`.
# Write `longest_streak` to return the largest number of consecutive
# `Completed` days.
#
# For example, `[Completed, Completed, Skipped, Completed]` has a longest streak of **2**.
# An empty list or a list of only `Skipped` values should return **0**.
#
# Replace the stub below and make every `expect` pass. Tests update as you
# edit. Five tests fail initially because the stub is not a solution.

# %%
longest_streak = |_days| 0

# %%
# ## Tests
# Keep these tests while you work, then add one of your own that might catch
# a mistake. Each `expect` describes a result your function must produce.

# %%
## No days
expect longest_streak([]) == 0

## No completed days
expect longest_streak([Skipped, Skipped]) == 0

## One completed day
expect longest_streak([Completed]) == 1

## All completed
expect longest_streak([Completed, Completed, Completed]) == 3

## Longest at the start
expect longest_streak([Completed, Completed, Skipped, Completed]) == 2

## Longest at the end
expect longest_streak([Completed, Skipped, Completed, Completed, Completed]) == 3

## Separated runs
expect longest_streak([Completed, Skipped, Completed, Skipped, Completed]) == 1


# %%
# ## Hints
# - Rename `_days` to `days` when you start using the argument.
# - Think about what you need to remember while visiting each day in order.
# - A skipped day ends the current streak, but should it erase the best one?
# - Check a streak that ends on the very last day, not just one followed by a skip.
#
# Finished? Extend the function to allow one skipped day within a streak.
# Write down the new rules and add checks before changing your code.

# %% generated
main! = |_args| {
    Ok({})
}
