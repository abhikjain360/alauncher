# Calculator grammar (contract for `Packages/Calc`)

This is the frozen spec for the launcher calculator. The implementation and its tests must follow it. Anything not listed here is out of scope.

The calculator evaluates on every keystroke, so it must be fast (well under 1 ms for typical input) and must never crash or hang on arbitrary input.

## API

```swift
public enum CalcOutcome: Equatable, Sendable {
    case result(CalcResult)
    case incomplete            // a valid prefix of a calculation: `2 +`, `sqrt(`, `5 km to`
    case error(String)         // clearly a calculation, but invalid: `1/0`, `5 km to kg`
    case notACalculation       // plain words, bare numbers, bare constants, bare quantities
}

Calculator(rates: CurrencyRateProvider?).evaluate(_ input: String) -> CalcOutcome
```

- **Showing a row:**
  - Only `.result` gets a normal row.
  - `.error` gets a dim row with the message, but only when the input contains an operator, a function call or a conversion keyword.
  - Every other outcome shows no row.
- **What doesn't count as a calculation:**
  - A bare number (`42`), constant (`pi`), identifier or quantity (`5 km`) is `.notACalculation`. Nobody wants a row echoing what they typed.
  - Base literals are the exception: `0xff` alone is a calculation (it shows 255).
  - A bare currency amount (`100 usd`) is `.notACalculation`. It has no home currency (the user's choice).
- **Resource limits:** results must stay bounded in time and memory.
  - Cap factorial input at 1000, the integer width of bitwise and base operations at 128 bits, and exponents so that results stay under 10^1000.
  - Anything beyond a cap is `.error("too large")`.

## Tokens

- **Numbers:**
  - Forms: `123`, `1.5`, `.5`, `1e3`, `1.5E-3`, `0x1F`, `0o17`, `0b101`. Prefixes are case-insensitive.
  - `_` is allowed between digits, as in Python: `1_000_000`, `0xFF_FF`.
  - Commas are not digit grouping. They only separate function arguments.
- **Operators:** `+ - * / // % ** ^ ( ) , ! & | ~ << >>`.
- **Keywords** (case-insensitive):
  - `to`, `in`, `as`: conversion.
  - `of`: percent-of.
  - `mod`: modulo.
- **Identifiers:** letters, digits, `_`, `.`, `°`, `µ`, `²`, `³` and `/` inside compound units (see Units).
  - The `math.` prefix is accepted and ignored: `math.sqrt(2)`.
- **Currency symbols:** `$` USD, `€` EUR, `£` GBP, `¥` JPY, `₹` INR, `₩` KRW, as a prefix (`$20`) or as a conversion target.

## Precedence (lowest to highest)

| Level | Syntax | Associativity | Notes |
|---|---|---|---|
| 1 | `expr to/in/as target` | — | At top level or directly inside parentheses, at most once per expression |
| 2 | `\|` | left | Integers only |
| 3 | `&` | left | Integers only |
| 4 | `<<` `>>` | left | Integers only |
| 5 | `+` `-` | left | Percent rule below |
| 6 | `*` `/` `//` `%` `mod`, implicit multiplication | left | `%` is modulo here (see below) |
| 7 | unary `-` `+` `~` | right | |
| 8 | `**` `^` | right | Binds tighter than a unary minus on its left: `-2**2 = -4`, `2**-1 = 0.5` |
| 9 | postfix `!`, postfix `%` | left | |
| 10 | number, quantity, constant, `f(args)`, `(expr)`, currency amount | | |

This is Python's order, with `^` as power instead of XOR.

### Implicit multiplication

- These multiply at level 6:
  - a number followed by an identifier or `(`: `2pi`, `3(4+1)`, `2 sqrt(9)`
  - `)(`: `(1+2)(3+4) = 21`
- **A number followed by a unit** forms a quantity literal, which binds tighter than anything else (level 10). So `10 km / 2 h` is `5 km/h`, and `1/2 km` is `1 / (2 km)`. Write `0.5 km` or `(1/2) km` for half a kilometre.
- **A unit exponent** belongs to the unit: `2 m^2` is two square metres, while `2^2 m` is `4 m`.

## `%`: modulo first, percent where modulo can't apply

Modulo:
- `%` is binary modulo when an operand starts right after it: a number, an identifier, `(`, or a unary sign followed by one of those.
- It follows Python semantics: the result takes the divisor's sign, and floats are allowed.
  - `17 % 5 = 2`
  - `-7 % 3 = 2`
  - `7 % -3 = -2`
  - `5.5 % 2 = 1.5`
  - `17 % -5 = -3`
- `mod` is the same operator.

Percent, used only where modulo is impossible:
- **Postfix percent:** `x%` is `x/100`.
- **`a + b%`** is `a × (1 + b/100)`, and **`a - b%`** is `a × (1 - b/100)`. This applies only when the right operand of `+`/`-` is a bare percent term.
  - `200 + 15% = 230`
  - `200 - 10% = 180`
- **`b% of a`** is `a × b/100`: `15% of 80 = 12`.
- **Everything else** follows from `x% = x/100`:
  - `50 * 10% = 5`
  - `15% + 2 = 2.15`
  - `15% = 0.15`

## Arithmetic semantics

- **Division:** `/` is true division.
- **Floor division:** `//` gives `floor(a / b)`.
  - `-7 // 2 = -4`
  - `7.5 // 2 = 3`
- **Division by zero:** `/`, `//`, `%` and `mod` by zero give `.error("division by zero")`.
- **Power:**
  - `**` and `^` are right-associative: `2 ** 3 ** 2 = 512`.
  - `0 ** 0 = 1`.
  - A negative base with a non-integer exponent is `.error("complex result")`.
- **Factorial:** `n!` and `factorial(n)` take integers from 0 to 1000 only.
- **Bitwise:** `& | ~ << >>` take integers only (otherwise `.error("not an integer")`). They use Python semantics for negatives (`~5 = -6`).
- **Precision:**
  - Values are `Decimal` (38 significant digits) while exact.
  - Transcendental functions and non-integer powers use `Double`.
  - An exact integer too big for `Decimal` falls back to `Double`.

## Functions and constants

**Functions:**
- **Roots and rounding:**
  - `sqrt` `cbrt` `abs`
  - `round(x[, n])`: Python's round-half-even, so `round(2.5) = 2`.
  - `floor` `ceil` `trunc`
  - `int(x)`: truncates toward zero.
- **Logs:**
  - `ln` `log10` `log2` `exp`
  - `log(x[, base])`: natural log by default, as in Python.
- **Trig:** `sin cos tan asin acos atan atan2(y, x) sinh cosh tanh hypot`, all in radians.
  - An angle quantity is converted first: `sin(30 deg) = 0.5`.
- **Other:** `min max` (any number of arguments), `gcd lcm factorial degrees radians pow(x, y)`.
- **Bases:** `hex(x)`, `bin(x)`, `oct(x)` (see Bases).

**Constants:** `pi`, `e`, `tau`.

A function name without `(` is `.incomplete` if it could still become a call; otherwise it's just an identifier.

## Bases

- **Conversion targets:**
  - `hex`/`hexadecimal`: `255 to hex` → `0xff`
  - `bin`/`binary`: `10 to bin` → `0b1010`
  - `oct`/`octal`: `8 to oct` → `0o10`
  - `dec`/`decimal`: `0xff to dec` → `255`
- **Functions:** `hex(x)`, `bin(x)` and `oct(x)` display like the matching conversion.
- **Format:** Python style, lowercase digits, negatives as `-0xff`. `display` and `copyText` are the same.
- **Non-integers:** `.error("not an integer")`.
- **Detail line:** if the input contains a non-decimal literal and the result is an integer, the detail shows the other bases.
  - Example: `0xff + 1` → display `256`, detail `0x100 · 0b100000000 · 0o400`.

## Units

- **Representation:** a quantity is a value times a unit, where the unit carries a dimension vector over:
  - length, mass, time, temperature, data (bits), angle
  - currency (see Currency)
- **Arithmetic:**
  - `+` and `-` need matching dimensions. The result is in the left operand's unit: `5 ft + 3 in = 5.25 ft`.
  - `*` and `/` combine dimensions: `10 km / 2 h = 5 km/h`.
  - Integer powers apply to units.
- **Conversion:**
  - The target is a unit or a compound unit (`km/h`, `m/s`, `ft/s`, `kWh`) of the same dimension.
  - A mismatch is `.error("can't convert length to mass")`.
- **Temperature** is convert-only:
  - `70 F to C` = 21.1111 °C.
  - Any other arithmetic involving a temperature is `.error("temperature arithmetic isn't supported")`.
- **`in`:**
  - It is the inch unit when it directly follows a bare number: `5 in to cm`, `5 in in cm`.
  - Anywhere else it is the conversion keyword: `5 km in mi`.

Unit list:

| Dimension | Units |
|---|---|
| length | `m km cm mm um/µm nm`, `mi/mile(s)`, `yd/yard(s)`, `ft/foot/feet`, `in/inch(es)`, `nmi` |
| mass | `kg g mg ug/µg t/tonne(s)`, `lb/lbs/pound(s)`, `oz/ounce(s)`, `st/stone` |
| time | `s/sec/second(s) ms us/µs ns`, `min/minute(s)`, `h/hr/hour(s)`, `d/day(s)`, `wk/week(s)`, `mo/month(s)` (30.436875 d), `yr/year(s)` (365.2425 d) |
| temperature | `C/°C/celsius`, `F/°F/fahrenheit`, `K/kelvin`; lowercase `c`, `f` and `k` are accepted |
| area | `m2/m²/sqm km2 cm2 ft2/sqft in2 mi2`, `ha/hectare(s)`, `acre(s)` |
| volume | `l/L/liter(s)/litre(s) ml/mL cl dl`, `m3/m³ cm3/cc`, `gal/gallon(s)` (US), `qt/quart(s) pt/pint(s) cup(s) floz tbsp tsp` |
| speed | `km/h kmh kph mph m/s ft/s`, `kn/knot(s)` |
| data | `B/byte(s) kB KB MB GB TB PB` (×1000), `KiB MiB GiB TiB` (×1024), `bit(s) Kb Mb Gb Tb` (bits, ×1000); all-lowercase `kb mb gb tb` mean bytes; rates `bps kbps Mbps Gbps` |
| energy | `J kJ cal kcal Wh kWh BTU` |
| power | `W kW MW hp` |
| pressure | `Pa kPa bar psi atm mmHg` |
| angle | `rad deg/° turn` |
| frequency | `Hz kHz MHz GHz` |

## Currency

- **Syntax:**
  - `<expr> <CODE> (to|in|as) <CODE>`, e.g. `100 usd to inr`.
  - Symbols work in amounts and targets: `$20 to eur`, `20 usd in €`.
  - Codes are case-insensitive ISO 4217, from the loaded rate snapshot.
- **Arithmetic:** mixed currencies convert to the left operand's currency first: `100 usd + 20 eur to inr`. Scalar `*` and `/` work: `100 usd * 3 to eur`.
- **Bare amounts:** an amount without a conversion (`100 usd`) is `.notACalculation`.
- **Ambiguous tokens:** a token that is both a unit and a code (`cup` / CUP) is a unit, unless the other side of the conversion is a currency. A code that is also an English word (`all`, `try`, `top`, `bob`, `mop`, `pen`, `mad`) counts as a currency only inside a conversion to or from another currency.
- **Rates:**
  - A rate from A to B is `rates[B] / rates[A]`, where the rates are relative to the snapshot's base.
  - With no snapshot: `.error("exchange rates not loaded yet")`.
- **Display:**
  - Two decimals and the code: `9,557.92 INR`.
  - Tiny values keep 4 significant digits: `0.0001046 BTC`.
  - Detail line: `1 USD = 95.5792 INR · 2026-09-13 · Rates by Exchange Rate API`, or the fallback's attribution.

### `CurrencyRateStore`

**Sources:**
- Primary: `https://open.er-api.com/v6/latest/USD`. Its `rates` are relative to USD. Respect `time_next_update_unix`, and attribute it.
- Fallback: `https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json`.
  - Its codes are lowercase and include crypto.
  - Normalize them to uppercase and record the source.
- Never mix the two sources in one snapshot.

**Validation:** keep only positive, finite rates, and require at least 30 currencies. Otherwise keep the previous snapshot.

**Caching:**
- The cache file holds the whole snapshot as JSON: base, rates, `publishedAt`, `fetchedAt`, source.
- It is loaded at init.
- `refreshIfStale()` fetches when the snapshot is older than `maxAge` or the feed's next-update time has passed.
- Concurrent calls share one fetch, and it returns true when the rates changed.
- Network work happens off the main thread.

## Display format

- **`display`:**
  - At most 12 significant digits, trailing zeros trimmed.
  - Grouped with `,` from 1,000 up.
  - Scientific notation for |x| ≥ 1e15 (`1.23456789012e15`) or 0 < |x| < 1e-9.
  - Exact `Decimal` integers up to 38 digits print in full.
- **`copyText`:** the same value without grouping. It keeps full `Decimal` precision, or 15 significant digits for `Double`.
- **Quantities:** the target's unit symbol goes after the value: `3.10686 mi`, `21.1111 °C`, `5 km/h`.
- **`detail`:** empty unless the Bases or Currency rules above give it a value.

## Test vectors (minimum set; more are welcome)

| Input | Outcome |
|---|---|
| `2+2` | 4 |
| `2 ** 10` | 1,024 (copy `1024`) |
| `2 ^ 10` | 1,024 |
| `2 ** 3 ** 2` | 512 |
| `-2 ** 2` | -4 |
| `2 ** -1` | 0.5 |
| `7 // 2` | 3 |
| `-7 // 2` | -4 |
| `17 % 5` | 2 |
| `-7 % 3` | 2 |
| `17 % -5` | -3 |
| `17 mod 5` | 2 |
| `200 + 15%` | 230 |
| `200 - 10%` | 180 |
| `15% of 80` | 12 |
| `50 * 10%` | 5 |
| `15% + 2` | 2.15 |
| `0.1 + 0.2` | 0.3 |
| `1/3` | 0.333333333333 |
| `10/4` | 2.5 |
| `1/0` | error "division by zero" |
| `5!` | 120 |
| `2pi` | 6.28318530718 |
| `3(4+1)` | 15 |
| `(1+2)(3+4)` | 21 |
| `sqrt(2)*3` | 4.24264068712 |
| `math.sqrt(16)` | 4 |
| `log(100, 10)` | 2 |
| `log(e)` | 1 |
| `round(2.5)` | 2 |
| `sin(30 deg)` | 0.5 |
| `max(3, 9, 4)` | 9 |
| `2**100` | 1,267,650,600,228,229,401,496,703,205,376 |
| `1_000_000 * 3` | 3,000,000 |
| `0xff` | 255 |
| `0xff + 1` | 256, detail `0x100 · 0b100000000 · 0o400` |
| `255 to hex` | 0xff |
| `0b1010 to hex` | 0xa |
| `0xff to bin` | 0b11111111 |
| `10 to oct` | 0o12 |
| `hex(255)` | 0xff |
| `1.5 to hex` | error "not an integer" |
| `0xf0 \| 0x0f` | 255 |
| `1 << 10` | 1,024 |
| `~5` | -6 |
| `5 km to mi` | 3.10685596119 mi |
| `5 km in mi` | 3.10685596119 mi |
| `70 F to C` | 21.1111111111 °C |
| `0 c to f` | 32 °F |
| `5 ft + 3 in to cm` | 160.02 cm |
| `5 ft + 3 in` | 5.25 ft |
| `5 in to cm` | 12.7 cm |
| `10 km / 2 h` | 5 km/h |
| `100 kmh to mph` | 62.1371192237 mph |
| `3 GB to MiB` | 2,861.02294922 MiB |
| `1 GiB to MB` | 1,073.741824 MB |
| `2 cup to ml` | 473.176473 ml |
| `5 km to kg` | error "can't convert length to mass" |
| `20 C + 5 C` | error "temperature arithmetic isn't supported" |
| `100 usd to inr` | with fixture rates USD=1, INR=95.5 → `9,550.00 INR` |
| `$20 to eur` | fixture EUR=0.86 → `17.20 EUR` |
| `100 usd` | notACalculation |
| `100 usd to inr` with no rates | error "exchange rates not loaded yet" |
| `42` | notACalculation |
| `pi` | notACalculation |
| `5 km` | notACalculation |
| `safari` | notACalculation |
| `2 +` | incomplete |
| `sqrt(` | incomplete |
| `5 km to` | incomplete |
| `1e400 * 1e400` | error "too large" (or Double inf → "too large") |
| `999!` | a result, which must return in < 50 ms |
| `1001!` | error "too large" |
| `2 ** 99999` | error "too large" |
