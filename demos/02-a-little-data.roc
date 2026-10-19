app [main!] {}
import Display

# %%
# # Three days of weather
# Records keep related values together; lists let us work with them as a group.
# Change a temperature, or add another record to the list.

# %%
days = [
    { name: "Monday", celsius: 18 },
    { name: "Tuesday", celsius: 22 },
    { name: "Wednesday", celsius: 16 },
]

# %%
Display.table(["Day", "Celsius", "Fahrenheit"], List.map(days, |day| [
    day.name,
    day.celsius.to_str(),
    (day.celsius * 1.8 + 32).to_str(),
]))

# %%
# The table takes strings so that numeric values reach the browser without
# JavaScript rounding them. Try changing `1.8` to see every row recompute.
