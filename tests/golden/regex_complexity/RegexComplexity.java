import java.util.regex.Pattern;

class RegexComplexity {
    Pattern dangerous = Pattern.compile("([a-z]+)+$");
    Pattern safe = Pattern.compile("(?:ab+)+$");
}
