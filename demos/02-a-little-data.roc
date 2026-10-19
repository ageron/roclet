app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.1.0/DgxFw9gRQuHiBsKhkuG4RxHPAyjMXLK6sujcMfnHijc7.tar.zst" }
import roclet.Display

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
out_1 = Display.table(["Day", "Celsius", "Fahrenheit"], List.map(days, |day| [
    day.name,
    day.celsius.to_str(),
    (day.celsius * 1.8 + 32).to_str(),
]))

# %%
# The table takes strings so that numeric values reach the browser without
# JavaScript rounding them. Try changing `1.8` to see every row recompute.

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    Ok({})
}
