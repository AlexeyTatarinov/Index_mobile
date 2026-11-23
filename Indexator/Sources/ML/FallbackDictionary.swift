// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small built-in Russian -> English word list for common photo subjects.
// Used when the system Translation framework is not available, so that a
// one-word query like «попугай» still reaches the English-only CLIP model.

import Foundation

enum FallbackDictionary {
    private static let pairs: [(String, String)] = [
        // animals
        ("попугай", "parrot"), ("птица", "bird"), ("сова", "owl"), ("голубь", "pigeon"), ("чайка", "seagull"),
        ("утка", "duck"), ("гусь", "goose"), ("лебедь", "swan"), ("курица", "chicken"), ("петух", "rooster"),
        ("фламинго", "flamingo"), ("пингвин", "penguin"), ("орёл", "eagle"), ("орел", "eagle"), ("воробей", "sparrow"),
        ("собака", "dog"), ("пёс", "dog"), ("пес", "dog"), ("щенок", "puppy"), ("кошка", "cat"), ("кот", "cat"),
        ("котёнок", "kitten"), ("котенок", "kitten"), ("лошадь", "horse"), ("конь", "horse"), ("корова", "cow"),
        ("овца", "sheep"), ("коза", "goat"), ("свинья", "pig"), ("кролик", "rabbit"), ("заяц", "hare"),
        ("белка", "squirrel"), ("ёж", "hedgehog"), ("еж", "hedgehog"), ("лиса", "fox"), ("волк", "wolf"),
        ("медведь", "bear"), ("олень", "deer"), ("лев", "lion"), ("тигр", "tiger"), ("слон", "elephant"),
        ("жираф", "giraffe"), ("зебра", "zebra"), ("обезьяна", "monkey"), ("капибара", "capybara"),
        ("черепаха", "turtle"), ("ящерица", "lizard"), ("змея", "snake"), ("крокодил", "crocodile"),
        ("рыба", "fish"), ("акула", "shark"), ("дельфин", "dolphin"), ("кит", "whale"), ("медуза", "jellyfish"),
        ("краб", "crab"), ("бабочка", "butterfly"), ("пчела", "bee"), ("паук", "spider"), ("лягушка", "frog"),
        ("животное", "animal"), ("зоопарк", "zoo"), ("аквариум", "aquarium"),
        // people
        ("человек", "person"), ("люди", "people"), ("мужчина", "man"), ("женщина", "woman"), ("ребёнок", "child"),
        ("ребенок", "child"), ("дети", "children"), ("малыш", "baby"), ("девочка", "girl"), ("мальчик", "boy"),
        ("друзья", "friends"), ("семья", "family"), ("селфи", "selfie"), ("портрет", "portrait"), ("лицо", "face"),
        ("улыбка", "smile"), ("толпа", "crowd"),
        // nature and places
        ("море", "sea"), ("океан", "ocean"), ("пляж", "beach"), ("песок", "sand"), ("волна", "wave"),
        ("озеро", "lake"), ("река", "river"), ("водопад", "waterfall"), ("гора", "mountain"), ("горы", "mountains"),
        ("лес", "forest"), ("дерево", "tree"), ("деревья", "trees"), ("цветок", "flower"), ("цветы", "flowers"),
        ("трава", "grass"), ("поле", "field"), ("парк", "park"), ("сад", "garden"), ("небо", "sky"),
        ("облако", "cloud"), ("облака", "clouds"), ("закат", "sunset"), ("рассвет", "sunrise"), ("солнце", "sun"),
        ("луна", "moon"), ("звёзды", "stars"), ("звезды", "stars"), ("снег", "snow"), ("дождь", "rain"),
        ("радуга", "rainbow"), ("туман", "fog"), ("пустыня", "desert"), ("остров", "island"), ("скала", "rock"),
        ("пещера", "cave"), ("город", "city"), ("улица", "street"), ("площадь", "square"), ("дом", "house"),
        ("здание", "building"), ("архитектура", "architecture"), ("собор", "cathedral"), ("церковь", "church"),
        ("замок", "castle"), ("мост", "bridge"), ("башня", "tower"), ("музей", "museum"), ("памятник", "monument"),
        ("фонтан", "fountain"), ("порт", "port"), ("гавань", "harbor"), ("рынок", "market"), ("магазин", "shop"),
        ("ресторан", "restaurant"), ("кафе", "cafe"), ("бар", "bar"), ("отель", "hotel"), ("бассейн", "swimming pool"),
        ("аэропорт", "airport"), ("вокзал", "train station"), ("стадион", "stadium"), ("офис", "office"),
        ("комната", "room"), ("кухня", "kitchen"), ("спальня", "bedroom"), ("ванная", "bathroom"), ("балкон", "balcony"),
        ("окно", "window"), ("дверь", "door"), ("стол", "table"), ("стул", "chair"), ("диван", "sofa"),
        ("кровать", "bed"), ("матрас", "mattress"), ("лестница", "stairs"),
        // things
        ("машина", "car"), ("автомобиль", "car"), ("велосипед", "bicycle"), ("мотоцикл", "motorcycle"),
        ("самокат", "scooter"), ("автобус", "bus"), ("поезд", "train"), ("самолёт", "airplane"), ("самолет", "airplane"),
        ("лодка", "boat"), ("корабль", "ship"), ("яхта", "yacht"), ("дрон", "drone"), ("телефон", "phone"),
        ("ноутбук", "laptop"), ("компьютер", "computer"), ("экран", "screen"), ("клавиатура", "keyboard"),
        ("книга", "book"), ("документ", "document"), ("документы", "documents"), ("паспорт", "passport"),
        ("чек", "receipt"), ("билет", "ticket"), ("карта", "map"), ("письмо", "letter"), ("договор", "contract"),
        ("счёт", "invoice"), ("счет", "invoice"), ("скриншот", "screenshot"), ("рисунок", "drawing"),
        ("часы", "watch"), ("очки", "glasses"), ("сумка", "bag"), ("рюкзак", "backpack"), ("чемодан", "suitcase"),
        ("одежда", "clothes"), ("платье", "dress"), ("обувь", "shoes"), ("шляпа", "hat"), ("игрушка", "toy"),
        ("мяч", "ball"), ("подарок", "gift"), ("торт", "cake"), ("шарик", "balloon"), ("свеча", "candle"),
        ("ёлка", "christmas tree"), ("елка", "christmas tree"), ("гитара", "guitar"), ("пианино", "piano"),
        ("инструмент", "tool"), ("ключ", "key"), ("деньги", "money"), ("зонт", "umbrella"), ("флаг", "flag"),
        ("палатка", "tent"), ("костёр", "campfire"), ("костер", "campfire"), ("фейерверк", "fireworks"),
        // food
        ("еда", "food"), ("завтрак", "breakfast"), ("обед", "lunch"), ("ужин", "dinner"), ("пицца", "pizza"),
        ("паэлья", "paella"), ("суп", "soup"), ("салат", "salad"), ("мясо", "meat"), ("рыба", "fish"),
        ("суши", "sushi"), ("бургер", "burger"), ("хлеб", "bread"), ("сыр", "cheese"), ("фрукты", "fruit"),
        ("яблоко", "apple"), ("апельсин", "orange"), ("банан", "banana"), ("клубника", "strawberry"),
        ("арбуз", "watermelon"), ("мороженое", "ice cream"), ("кофе", "coffee"), ("чай", "tea"), ("вино", "wine"),
        ("пиво", "beer"), ("коктейль", "cocktail"), ("десерт", "dessert"),
        // events and activities
        ("свадьба", "wedding"), ("день рождения", "birthday party"), ("праздник", "celebration"),
        ("концерт", "concert"), ("вечеринка", "party"), ("футбол", "football"), ("спорт", "sport"),
        ("плавание", "swimming"), ("бег", "running"), ("танец", "dance"), ("путешествие", "travel"),
        ("поход", "hiking"), ("пикник", "picnic"), ("работа", "work"), ("учёба", "study"),
        // adjectives and colours
        ("красный", "red"), ("синий", "blue"), ("голубой", "light blue"), ("зелёный", "green"), ("зеленый", "green"),
        ("жёлтый", "yellow"), ("желтый", "yellow"), ("белый", "white"), ("чёрный", "black"), ("черный", "black"),
        ("оранжевый", "orange"), ("розовый", "pink"), ("фиолетовый", "purple"), ("серый", "gray"),
        ("большой", "big"), ("маленький", "small"), ("красивый", "beautiful"), ("старый", "old"), ("новый", "new"),
        ("ночь", "night"), ("ночью", "at night"), ("вечер", "evening"), ("утро", "morning"),
        ("разбитый", "broken"), ("разбито", "broken"),
        // little words
        ("и", "and"), ("с", "with"), ("на", "on"), ("в", "in"), ("у", "near"), ("под", "under"), ("над", "above"),
        ("возле", "near"), ("рядом", "near"), ("без", "without"), ("мой", "my"), ("моя", "my"),
    ]

    private static let exact: [String: String] = {
        var map: [String: String] = [:]
        for (ru, en) in pairs where map[ru] == nil { map[ru] = en }
        return map
    }()

    private static let endings = [
        "ами", "ями", "ого", "его", "ому", "ему", "ой", "ей", "ом", "ем", "ах", "ях", "ов", "ев",
        "ые", "ие", "ый", "ий", "ая", "яя", "ую", "юю",
        "а", "я", "ы", "и", "у", "ю", "е", "о",
    ]

    private static func stem(_ word: String) -> String {
        for ending in endings where word.count > ending.count + 2 && word.hasSuffix(ending) {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    private static let byStem: [String: String] = {
        var map: [String: String] = [:]
        for (ru, en) in pairs where !ru.contains(" ") {
            let s = stem(ru)
            if map[s] == nil { map[s] = en }
        }
        return map
    }()

    /// Translates word by word. Returns nil when no word was recognized.
    static func translate(_ text: String) -> String? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var known = 0
        let out: [String] = words.map { word in
            if let en = exact[word] ?? byStem[stem(word)] {
                known += 1
                return en
            }
            return word
        }
        guard known > 0 else { return nil }
        return out.joined(separator: " ")
    }
}
