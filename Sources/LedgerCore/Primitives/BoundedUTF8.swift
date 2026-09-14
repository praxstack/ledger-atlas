enum BoundedUTF8 {
  static func count(_ value: String, through limit: Int) -> Int {
    var count = 0
    var iterator = value.utf8.makeIterator()
    while count <= limit, iterator.next() != nil {
      count += 1
    }
    return count
  }
}
