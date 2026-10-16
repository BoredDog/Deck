import SwiftUI
import CoreLocation

/// Opt-in weather. Off by default. When on, the Mac's location (rounded to ~1 km) goes to Open-Meteo
/// (free, no account, no key) every 30 minutes. This is the one automatic network call in Deck.
@MainActor final class Weather: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Weather()

    struct Day: Identifiable { let id: Date; let high: Double; let low: Double; let code: Int; let rainChance: Int }
    struct Now { let temp: Double; let code: Int; let isDay: Bool }

    @AppStorage("weatherOn") var enabled = false { didSet { enabled ? start() : stop() } }
    @Published var now: Now?
    @Published var days: [Day] = []
    @Published var message = ""

    private let location = CLLocationManager()
    private var timer: Timer?
    private var coords: (Double, Double)?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func startIfOn() { if enabled { start() } }

    private func start() {
        message = "Finding your area…"
        Task {
            guard await Permission.explain(.location) else { enabled = false; return }
            location.requestWhenInUseAuthorization()
            location.requestLocation()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in Weather.shared.location.requestLocation() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        now = nil
        days = []
        message = ""
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        // Two decimals ≈ 1 km: enough for a forecast, not a street address.
        let lat = (c.latitude * 100).rounded() / 100, lon = (c.longitude * 100).rounded() / 100
        Task { @MainActor in
            self.coords = (lat, lon)
            await self.fetch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.coords != nil { await self.fetch() }
            else { self.message = "Deck needs Location access for the weather. Turn it on in System Settings → Privacy & Security → Location Services." }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.enabled { self.location.requestLocation() } }
    }

    private static let session = URLSession(configuration: .ephemeral)   // no cookies, no cache on disk

    func fetch() async {
        guard enabled, let (lat, lon) = coords else { return }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3"),
        ]
        do {
            let (data, _) = try await Self.session.data(from: url.url!)
            let r = try JSONDecoder().decode(Response.self, from: data)
            now = Now(temp: r.current.temperature_2m, code: r.current.weather_code, isDay: r.current.is_day == 1)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            days = r.daily.time.indices.compactMap { i in
                f.date(from: r.daily.time[i]).map {
                    Day(id: $0, high: r.daily.temperature_2m_max[i], low: r.daily.temperature_2m_min[i],
                        code: r.daily.weather_code[i], rainChance: r.daily.precipitation_probability_max[i] ?? 0)
                }
            }
            message = ""
        } catch {
            message = now == nil ? "Couldn't get the weather right now." : ""
        }
    }

    private struct Response: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let weather_code: [Int]
            let precipitation_probability_max: [Int?]
        }
        let current: Current
        let daily: Daily
    }

    /// WMO weather codes in plain words, with an SF Symbol.
    static func describe(_ code: Int, isDay: Bool = true) -> (String, String) {
        switch code {
        case 0: ("Clear", isDay ? "sun.max" : "moon.stars")
        case 1, 2: ("Partly cloudy", isDay ? "cloud.sun" : "cloud.moon")
        case 3: ("Cloudy", "cloud")
        case 45, 48: ("Foggy", "cloud.fog")
        case 51...57: ("Drizzle", "cloud.drizzle")
        case 61...67, 80...82: ("Rain", "cloud.rain")
        case 71...77, 85, 86: ("Snow", "cloud.snow")
        case 95...99: ("Thunderstorms", "cloud.bolt.rain")
        default: ("—", "cloud")
        }
    }
}

struct WeatherTile: View {
    @ObservedObject private var weather = Weather.shared
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            TileLabel(text: "Weather")
            if !weather.enabled {
                Spacer()
                Text("Off. Turn it on in Settings.").font(F.label).foregroundStyle(C.text2)
            } else if let now = weather.now {
                let (words, icon) = Weather.describe(now.code, isDay: now.isDay)
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(text: "\(Int(now.temp.rounded()))°")
                    Image(systemName: icon).foregroundStyle(accent.accent)
                }
                Text(words).font(F.body).foregroundStyle(C.text2)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    ForEach(weather.days.dropFirst()) { d in
                        HStack(spacing: 4) {
                            Text(d.id.formatted(.dateTime.weekday(.abbreviated))).font(F.label).foregroundStyle(C.text2)
                            Text("\(Int(d.high.rounded()))°/\(Int(d.low.rounded()))°").font(F.mono(11))
                        }
                    }
                }
            } else {
                Spacer()
                Text(weather.message.isEmpty ? "Loading…" : weather.message).font(F.label).foregroundStyle(C.text2)
            }
        }
    }
}

struct WeatherSettings: View {
    @ObservedObject private var weather = Weather.shared
    var body: some View {
        Tile {
            Toggle(isOn: $weather.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the weather").font(F.body)
                    Text("Uses your Mac's location, rounded to about 1 km, and asks Open-Meteo for a forecast every 30 minutes. No account, nothing else is sent.")
                        .font(F.label).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.trailingSwitch)
        }
    }
}
