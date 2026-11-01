import Display
import InputValues

Input := [].{
    # Keys are stable within a notebook. Use a different key for each control.
    slider : { key : Str, label : Str, min : F64, max : F64, step : F64, default : F64 } -> { value : F64, display : Display }
    slider = |config| {
        value = InputValues.get(config.key, config.default)
        bounded = if value < config.min { config.min } else if value > config.max { config.max } else { value }
        { value: bounded, display: Display.slider({ key: config.key, label: config.label, min: config.min, max: config.max, step: config.step, default: config.default, value: bounded }) }
    }
    # A custom numeric control uses the same persisted input state as a slider.
    custom : { key : Str, label : Str, min : F64, max : F64, default : F64, html : Str } -> { value : F64, display : Display }
    custom = |config| {
        value = InputValues.get(config.key, config.default)
        bounded = if value < config.min { config.min } else if value > config.max { config.max } else { value }
        { value: bounded, display: Display.custom_input({ key: config.key, label: config.label, min: config.min, max: config.max, default: config.default, html: config.html, value: bounded }) }
    }
}
