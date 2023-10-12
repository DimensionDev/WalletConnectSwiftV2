import Foundation

public struct ListingsResponse: Codable {
    public let listings: [String: Listing]
}

public struct Listing: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let homepage: String
    public let order: Int?
    public let imageId: String
    public let app: App
    public let mobile: Mobile
    public var lastTimeUsed: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case homepage
        case order
        case imageId = "image_id"
        case app
        case mobile
        case lastTimeUsed
    }

    public struct App: Codable, Hashable {
        public let ios: String?
        public let mac: String?
        public let safari: String?
    }
    
    public struct Mobile: Codable, Hashable {
        public let native: String?
        public let universal: String?
    }
}
