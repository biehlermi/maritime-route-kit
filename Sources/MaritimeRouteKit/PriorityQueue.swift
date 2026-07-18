struct PriorityQueue<Element: Comparable> {
  private var elements: [Element] = []

  var isEmpty: Bool { elements.isEmpty }

  mutating func push(_ element: Element) {
    elements.append(element)
    var child = elements.count - 1
    while child > 0 {
      let parent = (child - 1) / 2
      guard elements[child] < elements[parent] else { break }
      elements.swapAt(child, parent)
      child = parent
    }
  }

  mutating func pop() -> Element? {
    guard !elements.isEmpty else { return nil }
    if elements.count == 1 { return elements.removeLast() }
    let result = elements[0]
    elements[0] = elements.removeLast()
    var parent = 0
    while true {
      let left = parent * 2 + 1
      let right = left + 1
      var candidate = parent
      if left < elements.count, elements[left] < elements[candidate] { candidate = left }
      if right < elements.count, elements[right] < elements[candidate] { candidate = right }
      guard candidate != parent else { break }
      elements.swapAt(parent, candidate)
      parent = candidate
    }
    return result
  }
}
