class FormatString {
    String unsafe(String format, Object value) {
        return String.format(format, value);
    }

    String safe(String format, Object value) {
        return String.format("%s: %s", format, value);
    }
}
