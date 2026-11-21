import java.util.List;

class InvariantInLoop {
    static int count(List<String> lines, String word) {
        int found = 0;
        for (String line : lines) {
            if (line.contains(word.toLowerCase())) {
                found++;
            }
        }
        return found;
    }

    static int each(List<String> lines) {
        int found = 0;
        for (String line : lines) {
            found += line.trim().length();
        }
        return found;
    }
}
