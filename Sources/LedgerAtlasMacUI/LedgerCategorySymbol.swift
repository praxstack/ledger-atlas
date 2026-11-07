import LedgerCore

/// An SF Symbol for a category, so an icon tile says what the money was for (a fork and
/// knife for food, a car for transport) instead of repeating the same arrow on every expense.
/// Categories are named by the person, so the match is by common words in the name; anything
/// unrecognised falls back to the transaction kind's symbol.
enum LedgerCategorySymbol {
  /// Words that pick a symbol; the first rule with a matching word wins, so money-owed words
  /// (loan, credit) come before what they pay for (bill). A word matches a key exactly, or starts with it when the key
  /// has four letters or more ("groceries" matches "grocer", "card" does not match "car").
  static let rules: [(symbol: String, keys: [String])] = [
    ("fork.knife", ["food", "dining", "dine", "restaurant", "eat", "eating", "meal", "meals", "lunch", "dinner", "breakfast", "cafe", "coffee", "snack", "snacks", "swiggy", "zomato"]),
    ("cart.fill", ["grocer", "supermarket", "vegetable", "fruits", "kirana", "provision"]),
    ("car.fill", ["transport", "taxi", "cab", "cabs", "uber", "ola", "metro", "bus", "train", "fuel", "petrol", "diesel", "car", "auto", "parking", "commute", "toll"]),
    ("airplane", ["travel", "flight", "flights", "trip", "holiday", "vacation", "hotel"]),
    ("film", ["entertain", "movie", "movies", "film", "cinema", "netflix", "music", "game", "games", "fun", "concert"]),
    ("house.fill", ["rent", "house", "home", "household", "housing", "maintenance", "furnish"]),
    ("bag.fill", ["shop", "shopping", "cloth", "clothes", "apparel", "fashion", "amazon"]),
    ("cross.case.fill", ["health", "medical", "doctor", "pharma", "medicine", "hospital", "clinic", "dental"]),
    ("figure.run", ["fitness", "gym", "sport", "sports", "yoga"]),
    ("creditcard.fill", ["emi", "loan", "loans", "credit", "fees", "charges"]),
    ("bolt.fill", ["utilit", "electric", "electricity", "power", "water", "gas", "bill", "bills"]),
    ("wifi", ["internet", "wifi", "broadband"]),
    ("phone.fill", ["phone", "mobile", "recharge"]),
    ("book.fill", ["educat", "school", "college", "course", "courses", "book", "books", "tuition", "learning"]),
    ("gift.fill", ["gift", "gifts", "donat", "charity"]),
    ("banknote.fill", ["salary", "wage", "wages", "pay", "payroll", "income", "bonus", "stipend", "freelance"]),
    ("chart.line.uptrend.xyaxis", ["interest", "dividend", "invest", "investment", "mutual", "stock", "stocks", "sip", "returns"]),
    ("checkmark.shield.fill", ["insurance", "insure"]),
    ("building.columns.fill", ["tax", "taxes", "govt", "government"]),
    ("repeat", ["subscript", "membership"]),
    ("pawprint.fill", ["pet", "pets"]),
    ("scissors", ["beauty", "salon", "grooming", "haircut"]),
    ("figure.2.and.child.holdinghands", ["kid", "kids", "child", "children", "baby", "family"]),
  ]

  /// The symbol for a category name, or for the kind when there is no category or no match.
  static func name(for category: String?, kind: LedgerTransactionKind) -> String {
    if let category, let symbol = match(category) { return symbol }
    return kindSymbol(kind)
  }

  static func match(_ category: String) -> String? {
    let words = category.lowercased()
      .split(whereSeparator: { !$0.isLetter })
      .map(String.init)
    func matches(_ key: String) -> Bool {
      words.contains { $0 == key || (key.count >= 4 && $0.hasPrefix(key)) }
    }
    return rules.first { $0.keys.contains(where: matches) }?.symbol
  }

  static func kindSymbol(_ kind: LedgerTransactionKind) -> String {
    switch kind {
    case .income: "arrow.down.left"
    case .expense: "arrow.up.right"
    case .transfer: "arrow.left.arrow.right"
    case .adjustment: "slider.horizontal.3"
    }
  }
}
