from lxml import etree

unsafe = etree.XMLParser(resolve_entities=True)
safe = etree.XMLParser(resolve_entities=False)
