class ExpressionLanguage {
    void parse(ExpressionParser parser, String expression) {
        parser.parseExpression(expression);
    }

    void parseFixed(ExpressionParser parser, String expression) {
        parser.parseExpression("account.active");
    }

    void parseSelected(ExpressionParser parser) {
        String expression = "account.active";
        parser.parseExpression(expression);
    }
}
