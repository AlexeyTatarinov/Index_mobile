// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apple's built-in scene classifier (Vision, ~1300 labels such as food, plant,
// building, beach). A second opinion next to CLIP: CLIP is good at specific
// things («попугай»), the classifier is steadier on broad ones («еда», «природа»).

import CoreGraphics
import Foundation
import Vision

enum ImageLabeler {
    /// Labels with confidence, strongest first. Empty when Vision is unavailable.
    static func labels(for image: CGImage, minimumConfidence: Float = 0.15, limit: Int = 15) -> [(String, Float)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { ($0.identifier, $0.confidence) }
    }

    /// Every label the classifier can produce on this OS.
    static let supported: Set<String> = {
        (try? VNClassifyImageRequest().supportedIdentifiers()).map(Set.init) ?? []
    }()
}

/// Maps query words to classifier labels. Russian concept words come from a short
/// hand-made list; English words are matched against label names directly.
enum LabelQuery {
    private static let concepts: [(stems: [String], labels: [String])] = [
        (["еда", "еду", "еды", "блюд", "обед", "ужин", "завтрак", "застоль", "food", "meal", "dish"],
         ["food", "meal", "dish", "dining_table", "fast_food", "dessert", "fruit", "vegetable", "salad",
          "bread", "pizza", "sushi", "seafood", "meat", "cake", "soup", "pasta", "sandwich", "snack"]),
        (["десерт", "сладк", "торт", "пирож", "dessert", "cake"], ["dessert", "cake", "pastry", "cookie", "ice_cream", "chocolate"]),
        (["фрукт", "fruit"], ["fruit", "apple", "banana", "citrus_fruit", "orange", "berry", "grape", "watermelon"]),
        (["природ", "nature"], ["outdoor", "land", "forest", "tree", "plant", "foliage", "mountain", "grass", "hill",
                                  "lake", "river", "waterfall", "meadow", "field", "sky", "flower", "shrub", "jungle"]),
        (["лес", "forest"], ["forest", "tree", "woodland", "jungle", "foliage"]),
        (["цвет", "flower"], ["flower", "blossom", "rose", "tulip", "sunflower", "bouquet"]),
        (["растен", "plant"], ["plant", "houseplant", "foliage", "tree", "shrub", "succulent", "cactus"]),
        (["горы", "гора", "горах", "горн", "гору", "mountain"], ["mountain", "hill", "cliff", "canyon", "volcano"]),
        (["пляж", "beach"], ["beach", "shore", "coast", "sand"]),
        (["море", "моря", "морск", "мором", "океан", "sea", "ocean"], ["sea", "ocean", "water_body", "shore", "coast", "beach", "waves"]),
        (["озер", "река", "реки", "реке", "реку", "речк", "lake", "river"], ["lake", "river", "waterways", "water_body", "pond"]),
        (["закат", "рассвет", "sunset", "sunrise"], ["sunset_sunrise", "sunset", "sunrise", "sky", "dusk"]),
        (["снег", "зим", "snow"], ["snow", "winter", "ice", "frost"]),
        (["архитект", "здани", "дом", "architecture", "building"],
         ["architecture", "building", "structure", "cathedral", "church", "castle", "palace", "tower",
          "skyscraper", "monument", "bridge", "cityscape", "house", "facade", "arch", "dome", "temple", "mosque"]),
        (["собор", "церков", "церкв", "храм", "church", "cathedral"], ["cathedral", "church", "temple", "chapel", "mosque", "dome"]),
        (["город", "улиц", "city", "street"], ["cityscape", "street", "road", "building", "skyscraper", "downtown"]),
        (["корабл", "лодк", "яхт", "ship", "boat"], ["boat", "ship", "watercraft", "sailboat", "yacht", "cruise_ship"]),
        (["машин", "автомоб", "car"], ["car", "vehicle", "automobile", "suv", "sports_car"]),
        (["птиц", "bird"], ["bird", "parrot", "pigeon", "seagull", "duck", "owl"]),
        (["попуга", "parrot"], ["parrot", "macaw", "cockatoo", "bird"]),
        (["собак", "пес", "пёс", "щенок", "щенк", "dog", "puppy"], ["dog", "canine", "puppy"]),
        (["кот", "кота", "коты", "котик", "котён", "котен", "кошк", "cat", "kitten"], ["cat", "feline", "kitten"]),
        (["животн", "animal"], ["animal", "mammal", "bird", "dog", "cat", "reptile", "fish"]),
        (["документ", "бумаг", "чек", "квитанц", "document", "receipt"], ["document", "paper", "receipt", "text", "printed_page"]),
        (["скриншот", "screenshot"], ["screenshot"]),
        (["люди", "людей", "человек", "people", "person"], ["people", "adult", "child", "crowd", "person"]),
        (["дети", "детей", "детск", "ребен", "малыш", "child", "baby", "kid"], ["child", "baby", "toddler", "kid"]),
        (["праздн", "вечерин", "party", "celebration"], ["celebration", "party", "birthday", "balloon", "fireworks"]),
        (["спорт", "sport"], ["sport", "ball", "stadium", "athlete"]),
        (["ночь", "ночью", "ночн", "night"], ["night", "nightlife", "night_sky"]),
    ]

    /// Labels the query asks for, with the query words that produced them.
    static func labels(for text: String) -> (labels: Set<String>, words: Set<String>) {
        let supported = ImageLabeler.supported
        let words = PlaceIndex.normalize(text).split(separator: " ").map(String.init)
        var wanted: Set<String> = []
        var used: Set<String> = []
        for word in words {
            for concept in concepts where concept.stems.contains(where: { word == $0 || (word.hasPrefix($0) && $0.count >= 4 && word.count <= $0.count + 4) }) {
                wanted.formUnion(concept.labels)
                used.insert(word)
            }
            // English query words that are label names themselves ("tree", "pizza").
            if word.count >= 3, supported.contains(word) {
                wanted.insert(word)
                used.insert(word)
            }
        }
        // Keep only labels this OS knows; when the list is unknown (rare), keep all.
        let known = supported.isEmpty ? wanted : wanted.intersection(supported)
        return (known, used)
    }
}
