import Foundation

public struct ListingsResponse: Codable {
    public let listings: [String: Listing]
}

public class Listing: Codable, Hashable, Identifiable {
    public init(
        id: String,
        name: String, 
        homepage: String, 
        order: Int? = nil, 
        imageId: String, 
        app: Listing.App, 
        mobile: Listing.Links,
        desktop: Listing.Links,
        lastTimeUsed: Date? = nil,
        installed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.homepage = homepage
        self.order = order
        self.imageId = imageId
        self.app = app
        self.mobile = mobile
        self.desktop = desktop
        self.lastTimeUsed = lastTimeUsed
        self.installed = installed
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }
    
    public static func == (lhs: Listing, rhs: Listing) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
    
    public let id: String
    public let name: String
    public let homepage: String
    public let order: Int?
    public let imageId: String
    public let app: App
    public let mobile: Links
    public let desktop: Links
    
    public var lastTimeUsed: Date?
    public var installed: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case homepage
        case order
        case imageId = "image_id"
        case app
        case mobile
        case desktop
        case lastTimeUsed
    }

    public struct App: Codable, Hashable {
        public let ios: String?
        public let browser: String?
    }
    
    public struct Links: Codable, Hashable {
        public let native: String?
        public let universal: String?
    }
}
