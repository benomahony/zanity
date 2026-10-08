class XmlEntities {
    void configure(javax.xml.parsers.DocumentBuilderFactory factory) throws Exception {
        factory.setExpandEntityReferences(true);
        factory.setExpandEntityReferences(false);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
    }
}
