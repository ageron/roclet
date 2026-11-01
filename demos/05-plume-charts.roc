app [main!] {
    roclet: "https://github.com/ageron/roclet/releases/download/0.2.0/C8vdeSE1ABoSei4Lepuy9Dy7t7GAJQt42WQkWw9bhcFc.tar.zst",
    plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
}

import roclet.Display
import roclet.Input
import plume.Chart
import plume.Scatter
import plume.Coordinate
import plume.Layout
import plume.Title

# %%
# # Plot a wave with Plume
# Move the amplitude slider to redraw the curve, or edit the equation below.
# Hover for coordinates, drag to zoom, and double-click to reset the axes.
#
# This notebook uses Plume 0.5.0. Load its release bundle when prompted on first
# use. Roclet keeps the package for offline use and includes the Plotly renderer.

# %%
amplitude_control = Input.slider({
    key: "amplitude", label: "Amplitude", min: 0.5, max: 4, step: 0.5, default: 1,
})
amplitude = amplitude_control.value
out_amplitude = amplitude_control.display

# %%
draw_wave = |magnitude| {
    points = List.from_iter((0.U64..<81).iter()).map_try(|step| {
        number = step.to_f64() / 10
        x = Coordinate.from_number(number)?
        y = Coordinate.from_number(magnitude * F64.sin(number))?
        Ok({ x, y })
    })?
    curve = Scatter.new({ data: points, mode: Lines, name: "Sine wave" })
    chart = Chart.new({
        traces: [Scatter(curve)],
        layout: Layout.new({ title: Title.new({ text: "A sine wave with Plume" }) }),
    })
    Ok(Display.plotly("Sine wave: amplitude ${magnitude.to_str()}, 81 samples from x = 0 to 8.", chart.to_json()))
}

# %%
out_wave = draw_wave(amplitude) ?? Display.text("The curve needs finite coordinates.")

# %%
# `Display.plotly(plain_text, chart.to_json())` accepts the JSON from a Plume
# chart. Bars, scatter plots, pies and Sankey diagrams use the same constructor.
# Ordinary Roc prints the text summary; Roclet draws the interactive figure.

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_amplitude)
    display!(out_wave)
    Ok({})
}
