# Roclet supplies notebook input values at evaluation time.
# Ordinary Roc apps use the declared defaults.
InputValues := [].{
    get : Str, F64 -> F64
    get = |_key, default| default
}
