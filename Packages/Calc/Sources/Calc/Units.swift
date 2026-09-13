import Foundation

struct UnitDimension: Hashable, Sendable {
    var length: Int = 0
    var mass: Int = 0
    var time: Int = 0
    var temperature: Int = 0
    var data: Int = 0
    var angle: Int = 0

    static let none = UnitDimension()

    static func + (lhs: UnitDimension, rhs: UnitDimension) -> UnitDimension {
        UnitDimension(
            length: lhs.length + rhs.length,
            mass: lhs.mass + rhs.mass,
            time: lhs.time + rhs.time,
            temperature: lhs.temperature + rhs.temperature,
            data: lhs.data + rhs.data,
            angle: lhs.angle + rhs.angle
        )
    }

    static func - (lhs: UnitDimension, rhs: UnitDimension) -> UnitDimension {
        UnitDimension(
            length: lhs.length - rhs.length,
            mass: lhs.mass - rhs.mass,
            time: lhs.time - rhs.time,
            temperature: lhs.temperature - rhs.temperature,
            data: lhs.data - rhs.data,
            angle: lhs.angle - rhs.angle
        )
    }

    func multiplied(by exponent: Int) -> UnitDimension {
        UnitDimension(
            length: length * exponent,
            mass: mass * exponent,
            time: time * exponent,
            temperature: temperature * exponent,
            data: data * exponent,
            angle: angle * exponent
        )
    }

    var isNone: Bool { self == .none }

    var name: String {
        switch self {
        case UnitDimension(length: 1): return "length"
        case UnitDimension(mass: 1): return "mass"
        case UnitDimension(time: 1): return "time"
        case UnitDimension(temperature: 1): return "temperature"
        case UnitDimension(data: 1): return "data"
        case UnitDimension(angle: 1): return "angle"
        case UnitDimension(length: 2): return "area"
        case UnitDimension(length: 3): return "volume"
        case UnitDimension(length: 1, time: -1): return "speed"
        case UnitDimension(length: 2, mass: 1, time: -2): return "energy"
        case UnitDimension(length: 2, mass: 1, time: -3): return "power"
        case UnitDimension(length: -1, mass: 1, time: -2): return "pressure"
        case UnitDimension(time: -1): return "frequency"
        default: return "incompatible dimensions"
        }
    }
}

struct CalcUnit: Equatable, Sendable {
    var dimension: UnitDimension
    /// Canonical value = displayed value * scale + offset.
    var scale: Double
    var offset: Double = 0
    var symbol: String
    var isTemperature: Bool = false
    var ambiguousCurrencyCode: String?

    var isAffine: Bool { isTemperature && offset != 0 }

    static func linear(
        dimension: UnitDimension,
        scale: Double,
        symbol: String,
        ambiguousCurrencyCode: String? = nil
    ) -> CalcUnit {
        return CalcUnit(
            dimension: dimension,
            scale: scale,
            offset: 0,
            symbol: symbol,
            isTemperature: false,
            ambiguousCurrencyCode: ambiguousCurrencyCode
        )
    }

    func multiplied(by rhs: CalcUnit) -> CalcUnit {
        CalcUnit(
            dimension: dimension + rhs.dimension,
            scale: scale * rhs.scale,
            offset: 0,
            symbol: "\(symbol)*\(rhs.symbol)",
            isTemperature: false
        )
    }

    func divided(by rhs: CalcUnit) -> CalcUnit {
        CalcUnit(
            dimension: dimension - rhs.dimension,
            scale: scale / rhs.scale,
            offset: 0,
            symbol: "\(symbol)/\(rhs.symbol)",
            isTemperature: false
        )
    }

    func raised(to exponent: Int) -> CalcUnit {
        let exponentSymbol: String
        switch exponent {
        case 2: exponentSymbol = "²"
        case 3: exponentSymbol = "³"
        default: exponentSymbol = "^\(exponent)"
        }
        return CalcUnit(
            dimension: dimension.multiplied(by: exponent),
            scale: pow(scale, Double(exponent)),
            offset: 0,
            symbol: exponent == 1 ? symbol : "\(symbol)\(exponentSymbol)",
            isTemperature: false
        )
    }
}

private func unit(_ dimension: UnitDimension, _ scale: Double, _ symbol: String) -> CalcUnit {
    .linear(dimension: dimension, scale: scale, symbol: symbol)
}

private let lengthDimension = UnitDimension(length: 1)
private let massDimension = UnitDimension(mass: 1)
private let timeDimension = UnitDimension(time: 1)
private let dataDimension = UnitDimension(data: 1)
private let angleDimension = UnitDimension(angle: 1)

private let unitDefinitions: [String: CalcUnit] = {
    var u: [String: CalcUnit] = [:]
    func add(_ names: [String], _ value: CalcUnit) {
        for name in names { u[name] = value }
    }

    add(["m"], unit(lengthDimension, 1, "m"))
    add(["km"], unit(lengthDimension, 1_000, "km"))
    add(["cm"], unit(lengthDimension, 0.01, "cm"))
    add(["mm"], unit(lengthDimension, 0.001, "mm"))
    add(["um", "µm"], unit(lengthDimension, 1e-6, "µm"))
    add(["nm"], unit(lengthDimension, 1e-9, "nm"))
    add(["mi", "mile", "miles"], unit(lengthDimension, 1609.344, "mi"))
    add(["yd", "yard", "yards"], unit(lengthDimension, 0.9144, "yd"))
    add(["ft", "foot", "feet"], unit(lengthDimension, 0.3048, "ft"))
    add(["in", "inch", "inches"], unit(lengthDimension, 0.0254, "in"))
    add(["nmi"], unit(lengthDimension, 1852, "nmi"))

    add(["kg"], unit(massDimension, 1, "kg"))
    add(["g"], unit(massDimension, 0.001, "g"))
    add(["mg"], unit(massDimension, 1e-6, "mg"))
    add(["ug", "µg"], unit(massDimension, 1e-9, "µg"))
    add(["t", "tonne", "tonnes"], unit(massDimension, 1_000, "t"))
    add(["lb", "lbs", "pound", "pounds"], unit(massDimension, 0.45359237, "lb"))
    add(["oz", "ounce", "ounces"], unit(massDimension, 0.028349523125, "oz"))
    add(["st", "stone"], unit(massDimension, 6.35029318, "st"))

    add(["s", "sec", "second", "seconds"], unit(timeDimension, 1, "s"))
    add(["ms"], unit(timeDimension, 0.001, "ms"))
    add(["us", "µs"], unit(timeDimension, 1e-6, "µs"))
    add(["ns"], unit(timeDimension, 1e-9, "ns"))
    add(["min", "minute", "minutes"], unit(timeDimension, 60, "min"))
    add(["h", "hr", "hour", "hours"], unit(timeDimension, 3600, "h"))
    add(["d", "day", "days"], unit(timeDimension, 86_400, "d"))
    add(["wk", "week", "weeks"], unit(timeDimension, 604_800, "wk"))
    add(["mo", "month", "months"], unit(timeDimension, 30.436875 * 86_400, "mo"))
    add(["yr", "year", "years"], unit(timeDimension, 365.2425 * 86_400, "yr"))

    let c = CalcUnit(dimension: UnitDimension(temperature: 1), scale: 1, offset: 273.15, symbol: "°C", isTemperature: true)
    let f = CalcUnit(dimension: UnitDimension(temperature: 1), scale: 5.0 / 9.0, offset: 255.3722222222222, symbol: "°F", isTemperature: true)
    let k = CalcUnit(dimension: UnitDimension(temperature: 1), scale: 1, offset: 0, symbol: "K", isTemperature: true)
    add(["C", "°C", "c", "celsius"], c)
    add(["F", "°F", "f", "fahrenheit"], f)
    add(["K", "k", "kelvin"], k)

    add(["m2", "m²", "sqm"], unit(UnitDimension(length: 2), 1, "m²"))
    add(["km2"], unit(UnitDimension(length: 2), 1e6, "km²"))
    add(["cm2"], unit(UnitDimension(length: 2), 1e-4, "cm²"))
    add(["ft2", "sqft"], unit(UnitDimension(length: 2), 0.09290304, "ft²"))
    add(["in2"], unit(UnitDimension(length: 2), 0.00064516, "in²"))
    add(["mi2"], unit(UnitDimension(length: 2), 2_589_988.110336, "mi²"))
    add(["ha", "hectare", "hectares"], unit(UnitDimension(length: 2), 10_000, "ha"))
    add(["acre", "acres"], unit(UnitDimension(length: 2), 4046.8564224, "acre"))

    add(["l", "L", "liter", "liters", "litre", "litres"], unit(UnitDimension(length: 3), 0.001, "L"))
    add(["ml"], unit(UnitDimension(length: 3), 1e-6, "ml"))
    add(["mL"], unit(UnitDimension(length: 3), 1e-6, "mL"))
    add(["cl"], unit(UnitDimension(length: 3), 1e-5, "cl"))
    add(["dl"], unit(UnitDimension(length: 3), 1e-4, "dl"))
    add(["m3", "m³"], unit(UnitDimension(length: 3), 1, "m³"))
    add(["cm3", "cc"], unit(UnitDimension(length: 3), 1e-6, "cm³"))
    add(["gal", "gallon", "gallons"], unit(UnitDimension(length: 3), 0.003785411784, "gal"))
    add(["qt", "quart", "quarts"], unit(UnitDimension(length: 3), 0.000946352946, "qt"))
    add(["pt", "pint", "pints"], unit(UnitDimension(length: 3), 0.000473176473, "pt"))
    add(["cup", "cups"], CalcUnit(dimension: UnitDimension(length: 3), scale: 0.0002365882365, offset: 0, symbol: "cup", isTemperature: false, ambiguousCurrencyCode: "CUP"))
    add(["floz"], unit(UnitDimension(length: 3), 0.0000295735295625, "floz"))
    add(["tbsp"], unit(UnitDimension(length: 3), 0.00001478676478125, "tbsp"))
    add(["tsp"], unit(UnitDimension(length: 3), 0.00000492892159375, "tsp"))

    add(["km/h", "kmh", "kph"], unit(UnitDimension(length: 1, time: -1), 1000.0 / 3600.0, "km/h"))
    add(["mph"], unit(UnitDimension(length: 1, time: -1), 1609.344 / 3600.0, "mph"))
    add(["m/s"], unit(UnitDimension(length: 1, time: -1), 1, "m/s"))
    add(["ft/s"], unit(UnitDimension(length: 1, time: -1), 0.3048, "ft/s"))
    add(["kn", "knot", "knots"], unit(UnitDimension(length: 1, time: -1), 1852.0 / 3600.0, "kn"))

    add(["B", "byte", "bytes"], unit(dataDimension, 8, "B"))
    add(["kB", "KB"], unit(dataDimension, 8_000, "kB"))
    add(["MB"], unit(dataDimension, 8_000_000, "MB"))
    add(["GB"], unit(dataDimension, 8_000_000_000, "GB"))
    add(["TB"], unit(dataDimension, 8_000_000_000_000, "TB"))
    add(["PB"], unit(dataDimension, 8_000_000_000_000_000, "PB"))
    add(["KiB"], unit(dataDimension, 8_192, "KiB"))
    add(["MiB"], unit(dataDimension, 8_388_608, "MiB"))
    add(["GiB"], unit(dataDimension, 8_589_934_592, "GiB"))
    add(["TiB"], unit(dataDimension, 8_796_093_022_208, "TiB"))
    add(["bit", "bits", "b"], unit(dataDimension, 1, "bit"))
    add(["Kb"], unit(dataDimension, 1_000, "Kb"))
    add(["Mb"], unit(dataDimension, 1_000_000, "Mb"))
    add(["Gb"], unit(dataDimension, 1_000_000_000, "Gb"))
    add(["Tb"], unit(dataDimension, 1_000_000_000_000, "Tb"))
    add(["kb"], unit(dataDimension, 8_000, "kB"))
    add(["mb"], unit(dataDimension, 8_000_000, "MB"))
    add(["gb"], unit(dataDimension, 8_000_000_000, "GB"))
    add(["tb"], unit(dataDimension, 8_000_000_000_000, "TB"))
    add(["bps"], unit(UnitDimension(time: -1, data: 1), 1, "bps"))
    add(["kbps"], unit(UnitDimension(time: -1, data: 1), 1_000, "kbps"))
    add(["Mbps"], unit(UnitDimension(time: -1, data: 1), 1_000_000, "Mbps"))
    add(["Gbps"], unit(UnitDimension(time: -1, data: 1), 1_000_000_000, "Gbps"))

    let energy = UnitDimension(length: 2, mass: 1, time: -2)
    add(["J"], unit(energy, 1, "J"))
    add(["kJ"], unit(energy, 1000, "kJ"))
    add(["cal"], unit(energy, 4.184, "cal"))
    add(["kcal"], unit(energy, 4184, "kcal"))
    add(["Wh"], unit(energy, 3600, "Wh"))
    add(["kWh"], unit(energy, 3_600_000, "kWh"))
    add(["BTU"], unit(energy, 1055.05585262, "BTU"))

    let power = UnitDimension(length: 2, mass: 1, time: -3)
    add(["W"], unit(power, 1, "W"))
    add(["kW"], unit(power, 1000, "kW"))
    add(["MW"], unit(power, 1_000_000, "MW"))
    add(["hp"], unit(power, 745.6998715822702, "hp"))

    let pressure = UnitDimension(length: -1, mass: 1, time: -2)
    add(["Pa"], unit(pressure, 1, "Pa"))
    add(["kPa"], unit(pressure, 1000, "kPa"))
    add(["bar"], unit(pressure, 100_000, "bar"))
    add(["psi"], unit(pressure, 6894.757293168, "psi"))
    add(["atm"], unit(pressure, 101_325, "atm"))
    add(["mmHg"], unit(pressure, 133.322387415, "mmHg"))

    add(["rad"], unit(angleDimension, 1, "rad"))
    add(["deg", "°"], unit(angleDimension, Double.pi / 180, "deg"))
    add(["turn"], unit(angleDimension, 2 * Double.pi, "turn"))

    let frequency = UnitDimension(time: -1)
    add(["Hz"], unit(frequency, 1, "Hz"))
    add(["kHz"], unit(frequency, 1000, "kHz"))
    add(["MHz"], unit(frequency, 1_000_000, "MHz"))
    add(["GHz"], unit(frequency, 1_000_000_000, "GHz"))

    return u
}()

func lookupUnit(_ spelling: String) -> CalcUnit? {
    if let direct = unitDefinitions[spelling] { return direct }
    // Unit names are intentionally not globally case-insensitive: B/bit, m/M,
    // and SI prefixes carry meaning. These aliases are the explicitly accepted
    // lowercase spellings from the contract.
    let lower = spelling.lowercased()
    switch lower {
    case "um": return unitDefinitions["um"]
    case "ug": return unitDefinitions["ug"]
    case "us": return unitDefinitions["us"]
    case "c", "f", "k": return unitDefinitions[spelling] ?? unitDefinitions[lower.uppercased()]
    default: return nil
    }
}

func unitFromProduct(_ lhs: CalcUnit, _ rhs: CalcUnit) -> CalcUnit? {
    let result = lhs.multiplied(by: rhs)
    return result.dimension.isNone ? nil : result
}

func unitFromQuotient(_ lhs: CalcUnit, _ rhs: CalcUnit) -> CalcUnit? {
    let result = lhs.divided(by: rhs)
    return result.dimension.isNone ? nil : result
}
