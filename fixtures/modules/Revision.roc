Revision := [].{
    State : { document : U64, input : U64, generation : U64, ready : Bool }
    Token : { document : U64, input : U64, generation : U64 }

    initial : State
    initial = { document: 0, input: 0, generation: 0, ready: False }

    edit : State -> State
    edit = |state| { ..state, document: state.document + 1, ready: False }

    change_input : State -> State
    change_input = |state| { ..state, input: state.input + 1, ready: False }

    restart : State -> State
    restart = |state| { ..state, generation: state.generation + 1, ready: False }

    accepts : State, Token -> Bool
    accepts = |state, token|
        state.document == token.document and state.input == token.input and state.generation == token.generation

    finish : State, Token -> State
    finish = |state, token| if accepts(state, token) { { ..state, ready: True } } else { state }
}
