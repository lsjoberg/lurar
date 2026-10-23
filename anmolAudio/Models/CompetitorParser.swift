import Foundation

struct CompetitorParser {
    static func parse(json: Any, defaultName: String) -> EQPreset? {
        guard let dict = json as? [String: Any] else { return nil }
        
        // Extract basic metadata or fallbacks
        let name = dict["name"] as? String ?? defaultName
        let preamp = (dict["preamp"] as? NSNumber)?.floatValue ?? 0.0
        let headphone = dict["headphone"] as? String ?? "Imported"
        let source = dict["source"] as? String ?? "Competitor App"
        
        // Look for bands array
        guard let bandsArray = dict["bands"] as? [[String: Any]] else {
            return nil
        }
        
        var parsedBands: [EQBand] = []
        for b in bandsArray {
            let freq = (b["frequency"] as? NSNumber ?? b["freq"] as? NSNumber)?.floatValue ?? 0.0
            let gain = (b["gain"] as? NSNumber)?.floatValue ?? 0.0
            let q = (b["q"] as? NSNumber ?? b["Q"] as? NSNumber)?.floatValue ?? 0.71
            let typeString = (b["type"] as? String)?.lowercased() ?? "peak"
            
            var filterType: EQBand.FilterType = .peak
            if typeString.contains("lowshelf") || typeString.contains("low_shelf") || typeString.contains("low shelf") || typeString == "lsc" || typeString == "ls" || (typeString.contains("low") && !typeString.contains("pass")) {
                filterType = .lowShelf
            } else if typeString.contains("highshelf") || typeString.contains("high_shelf") || typeString.contains("high shelf") || typeString == "hsc" || typeString == "hs" || (typeString.contains("high") && !typeString.contains("pass")) {
                filterType = .highShelf
            } else {
                filterType = .peak
            }
            
            if freq > 0 {
                parsedBands.append(EQBand(type: filterType, frequency: freq, gain: gain, q: q))
            }
        }
        
        guard !parsedBands.isEmpty else { return nil }
        return EQPreset(name: name, headphone: headphone, source: source, preamp: preamp, bands: parsedBands)
    }
}
