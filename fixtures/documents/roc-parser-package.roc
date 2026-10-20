app [] {
    parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/2.0.0/7CLzCK6qUz7zmj6nvBxMEFu11HPwQTnCovKiyWzDSLTW.tar.zst",
}

# %% id=number
import parser.Utf8
out_number = Utf8.parse_str(Utf8.digits, "12345")

# %% id=names
import parser.CSV

Planet : { name : Str, moons : U64 }
decode : Str -> Try(List(Planet), [InvalidCsv(CSV.Error), MissingRequiredField(Str)])
decode = |input| CSV.parse(input)

planets = decode("name,moons\nEarth,1\nMars,2\n")
out_names = planets.map_ok(|rows| rows.map(|row| row.name))

# %% id=moons
out_moons = planets.map_ok(|rows| rows.map(|row| row.moons).sum())
