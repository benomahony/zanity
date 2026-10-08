def select(element, expression):
    return element.xpath(expression)


def select_fixed(element, expression):
    return element.xpath("/users/user")
