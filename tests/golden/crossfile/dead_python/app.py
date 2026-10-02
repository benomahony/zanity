from helpers import used_helper


def run():
    return used_helper(2)


def _forgotten():
    return 1


@app.route("/")
def index():
    return "hello"


class Unused:
    def __repr__(self):
        return "Unused()"


if __name__ == "__main__":
    run()
