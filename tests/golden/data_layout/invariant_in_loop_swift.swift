func count(lines: [String], word: String) -> Int {
    var found = 0
    for line in lines {
        if line.contains(word.lowercased()) {
            found += 1
        }
    }
    return found
}

func each(lines: [String]) -> Int {
    var found = 0
    for line in lines {
        found += line.lowercased().count
    }
    return found
}
