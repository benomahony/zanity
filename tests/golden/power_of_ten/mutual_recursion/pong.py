from ping import ping


def pong(n):
    return ping(n)


class Tree:
    def walk(self):
        return self.walk()

    def visit(self, node):
        return node.visit()
