class XPathExpression {
    void compile(javax.xml.xpath.XPath xpath, String expression) throws Exception {
        xpath.compile(expression);
    }

    void compileFixed(javax.xml.xpath.XPath xpath, String expression) throws Exception {
        xpath.compile("/users/user");
    }
}
