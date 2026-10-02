import xml.etree.ElementTree


def ship(order):
    city = order.customer.address.city
    name = order.customer.name
    tree = xml.etree.ElementTree.parse("x.xml")
    return city, name, tree


class Invoice:
    def total(self):
        self.order.customer.address.notify()
        return self.order.lines.count
